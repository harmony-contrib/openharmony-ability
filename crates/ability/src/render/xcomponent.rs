use std::{cell::RefCell, rc::Rc, sync::Arc};

use super::pan::PanTracker;

use napi_ohos::{Env, Error, Result};
use ohos_arkui_binding::component::attribute::{
    ArkUIAttributeBasic, ArkUICommonAttribute, ArkUIEvent, ArkUIGesture,
};
use ohos_arkui_binding::gesture::{gesture_data::GestureData, inner_gesture::Gesture};
use ohos_arkui_binding::types::{
    gesture_direction::GestureDirection, gesture_event::GestureEventAction,
};
use ohos_arkui_binding::{
    api::node_custom_event::IntOffset, common::node::ArkUINode, types::advanced::LengthMetricUnit,
};
use ohos_arkui_binding::{ArkUIHandle, RootNode, XComponent};
use ohos_xcomponent_binding::{XComponentOffset, XComponentSize};

#[cfg(feature = "keyboard")]
use crate::KeyboardEventData;
use crate::{
    set_main_thread_env, ArkUiInputEvent, AxisEventData, Event, GestureEvent, GesturePhase,
    InputEvent, KeyboardInputDelivery, OpenHarmonyApp, PanGestureEvent, PointerInputData, Rect,
    Size, SwipeGestureEvent, TapGestureEvent, XComponentInputEvent,
};

const PAN_GESTURE_DISTANCE: f64 = 8.0;
const SWIPE_GESTURE_MIN_SPEED: f64 = 100.0;

#[cfg(feature = "keyboard")]
pub(crate) fn request_xcomponent_focus(component: &XComponent) -> Result<()> {
    #[cfg(feature = "keyboard-focus")]
    {
        component
            .raw()
            .request_focus()
            .map_err(|error| Error::from_reason(error.to_string()))
    }
    #[cfg(not(feature = "keyboard-focus"))]
    component
        .set_focus_status(true)
        .map_err(|error| Error::from_reason(error.to_string()))
}

struct RenderOwnerGuard {
    app: OpenHarmonyApp,
    owner: String,
    armed: bool,
}

impl RenderOwnerGuard {
    fn new(app: OpenHarmonyApp, owner: String) -> Self {
        Self {
            app,
            owner,
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for RenderOwnerGuard {
    fn drop(&mut self) {
        if self.armed {
            self.app.release_render(&self.owner);
        }
    }
}

fn gesture_phase(action: &GestureEventAction) -> Option<GesturePhase> {
    if action.contains(GestureEventAction::Accept) {
        Some(GesturePhase::Start)
    } else if action.contains(GestureEventAction::Update) {
        Some(GesturePhase::Update)
    } else if action.contains(GestureEventAction::End) {
        Some(GesturePhase::End)
    } else if action.contains(GestureEventAction::Cancel) {
        Some(GesturePhase::Cancel)
    } else {
        None
    }
}

fn dispatch_input(app: &OpenHarmonyApp, owner: &str, event: InputEvent) {
    let requires_surface = match &event {
        InputEvent::Ime(_) => false,
        InputEvent::XComponent(XComponentInputEvent::Key(_)) => false,
        InputEvent::ArkUi(ArkUiInputEvent::FocusChanged(_)) => false,
        #[cfg(feature = "keyboard")]
        InputEvent::ArkUi(ArkUiInputEvent::Key(_)) => false,
        _ => true,
    };
    if requires_surface && !app.is_render_surface_active(owner) {
        return;
    }
    if let Some(callback) = app.input_callback(owner) {
        callback.send(event);
    }
}

#[cfg(feature = "drag")]
fn negotiate_drag(app: &OpenHarmonyApp, owner: &str, event: crate::DragInputData) {
    if !app.is_render_surface_active(owner) {
        return;
    }
    // Drop acceptance is an immediate native reply, not deferred foreground work.
    let Ok(mut handler) = app.event_loop.try_borrow_mut() else {
        crate::warn!("Cannot negotiate native drop during a nested application callback");
        return;
    };
    if let Some(handler) = handler.as_mut() {
        let event = InputEvent::ArkUi(ArkUiInputEvent::Drag(event));
        match app.render_window_id(owner) {
            Some(0) => handler(Event::Input(event)),
            Some(window_id) => handler(Event::SubWindowInput { window_id, event }),
            None => {}
        }
    }
}

fn dispatch_focus(app: &OpenHarmonyApp, owner: &str, focused: bool) {
    #[cfg(feature = "keyboard")]
    if focused {
        if let Some(window_id) = app.render_window_id(owner) {
            app.record_window_focus(window_id, true);
        }
    }
    let event = InputEvent::ArkUi(ArkUiInputEvent::FocusChanged(focused));
    dispatch_input(app, owner, event);
}

fn pointer_snapshot(
    input: &ohos_arkui_binding::arkui_input_binding::ArkUIInputEvent,
    node: *mut std::ffi::c_void,
) -> PointerInputData {
    let mut pointer = PointerInputData::from_arkui_event(input);
    // SAFETY: `node` is the non-owning `ArkUI_NodeHandle` borrowed for the duration of this native callback.
    if let Some(node) = unsafe { ArkUINode::from_raw_handle(node.cast()) } {
        if let Ok(origin) = node.layout_position_in_screen() {
            pointer.display_x = origin.x as f32 + pointer.x;
            pointer.display_y = origin.y as f32 + pointer.y;
        }
    }
    pointer
}

fn content_offset_in_window(node: *mut std::ffi::c_void) -> Option<IntOffset> {
    // SAFETY: `node` is the non-owning `ArkUI_NodeHandle` of the live XComponent in this callback.
    unsafe { ArkUINode::from_raw_handle(node.cast()) }?
        .layout_position_in_window()
        .ok()
}

fn release_gestures(xcomponent: &XComponent, gestures: &mut Vec<Gesture>) {
    for gesture in gestures.drain(..) {
        let _ = xcomponent.remove_gesture(&gesture);
        let _ = gesture.dispose();
    }
}

fn register_gestures(
    xcomponent: &XComponent,
    render_owner: &str,
    app: &OpenHarmonyApp,
    pan_tracker: Rc<RefCell<PanTracker>>,
) -> Result<Vec<Gesture>> {
    let mut gestures = Vec::with_capacity(3);

    let tap_app = app.clone();
    let tap_owner = render_owner.to_owned();
    let tap = match Gesture::create_tap_gesture_with_distance_threshold(1, 1, PAN_GESTURE_DISTANCE)
    {
        Ok(tap) => tap,
        Err(_) => Gesture::create_tap_gesture(1, 1)
            .map_err(|error| Error::from_reason(error.reason.to_string()))?,
    };
    if let Err(error) = tap.on_gesture(GestureEventAction::Accept, move |event| {
        let Some(pointer) = event.input.map(PointerInputData::from) else {
            return;
        };
        dispatch_input(
            &tap_app,
            &tap_owner,
            InputEvent::ArkUi(ArkUiInputEvent::Gesture(GestureEvent::Tap(
                TapGestureEvent { pointer },
            ))),
        );
    }) {
        tap.dispose()
            .map_err(|dispose_error| Error::from_reason(dispose_error.reason.to_string()))?;
        return Err(Error::from_reason(error.reason.to_string()));
    }
    if let Err(error) = xcomponent.add_gesture_ref(&tap, None, None) {
        tap.dispose()
            .map_err(|dispose_error| Error::from_reason(dispose_error.reason.to_string()))?;
        return Err(Error::from_reason(error.reason.to_string()));
    }
    gestures.push(tap);

    let pan_app = app.clone();
    let pan_owner = render_owner.to_owned();
    let pan = match xcomponent.on_pan_gesture(
        1,
        GestureDirection::All,
        PAN_GESTURE_DISTANCE,
        move |event| {
            if !pan_app.is_render_surface_active(&pan_owner) {
                pan_tracker.borrow_mut().reset();
                return;
            }
            let Some(phase) = gesture_phase(&event.event_action_type) else {
                return;
            };
            let pointer = event.input.map(PointerInputData::from);
            let pan_event = if phase == GesturePhase::Cancel {
                pan_tracker.borrow_mut().cancel(pointer)
            } else {
                let Some(pointer) = pointer else { return };
                let GestureData::Pan(data) = event.event_action_data else {
                    return;
                };
                pan_tracker.borrow_mut().update(PanGestureEvent {
                    pointer,
                    phase,
                    delta_x: 0.0,
                    delta_y: 0.0,
                    offset_x: data.offset_x,
                    offset_y: data.offset_y,
                    velocity: data.velocity,
                    velocity_x: data.velocity_x,
                    velocity_y: data.velocity_y,
                })
            };
            if let Some(event) = pan_event {
                dispatch_input(
                    &pan_app,
                    &pan_owner,
                    InputEvent::ArkUi(ArkUiInputEvent::Gesture(GestureEvent::Pan(event))),
                );
            }
        },
    ) {
        Ok(pan) => pan,
        Err(error) => {
            release_gestures(xcomponent, &mut gestures);
            return Err(Error::from_reason(error.reason.to_string()));
        }
    };
    gestures.push(pan);

    let swipe_app = app.clone();
    let swipe_owner = render_owner.to_owned();
    let swipe = match xcomponent.on_swipe_gesture(
        1,
        GestureDirection::All,
        SWIPE_GESTURE_MIN_SPEED,
        move |event| {
            let Some(phase) = gesture_phase(&event.event_action_type) else {
                return;
            };
            let Some(pointer) = event.input.map(PointerInputData::from) else {
                return;
            };
            let GestureData::Swipe(data) = event.event_action_data else {
                return;
            };
            dispatch_input(
                &swipe_app,
                &swipe_owner,
                InputEvent::ArkUi(ArkUiInputEvent::Gesture(GestureEvent::Swipe(
                    SwipeGestureEvent {
                        pointer,
                        phase,
                        angle: data.angle,
                        velocity: data.velocity,
                    },
                ))),
            );
        },
    ) {
        Ok(swipe) => swipe,
        Err(error) => {
            release_gestures(xcomponent, &mut gestures);
            return Err(Error::from_reason(error.reason.to_string()));
        }
    };
    gestures.push(swipe);

    Ok(gestures)
}

/// create lifecycle object and return to arkts
pub fn render(
    env: &Env,
    slot: ArkUIHandle,
    render_owner: String,
    app: OpenHarmonyApp,
    native_window_id: i32,
) -> Result<RootNode> {
    render_for_window(env, slot, render_owner, app, 0, native_window_id)
}

pub fn render_for_window(
    env: &Env,
    slot: ArkUIHandle,
    render_owner: String,
    app: OpenHarmonyApp,
    window_id: i64,
    native_window_id: i32,
) -> Result<RootNode> {
    if native_window_id < 0 {
        return Err(Error::from_reason(
            "Native render requires a nonnegative platform Window ID (0 = main)",
        ));
    }
    set_main_thread_env(*env);

    // All eager `get_helper()` TSFN inits (statusbar tray, vibrancy, clipboard image,
    // updater, account, autostart, opener) have been removed. They were all dead
    // paths: `set_helper` is never called after the #[ability] derive refactor, so
    // every `get_helper()` returned None and these inits logged "ArkHelper not
    // initialized" on every startup (noise, not functional bugs). Consumers have
    // migrated to typed bridge facades (WindowClient / ClipboardClient /
    // AutostartClient / plugin-statusbar / plugin-menu) or still call legacy
    // top-level fns directly (opener::reveal_in_dir — see decoupling task #6
    // B-group; the updater / account facades live in the dedicated
    // plugin-updater / plugin-account crates). Do NOT re-add eager `get_helper()`
    // TSFN inits here — new capability goes through bridge plugins.

    let mut root = RootNode::new(slot);
    let mut xcomponent_native =
        XComponent::new().map_err(|e| Error::from_reason(e.reason.to_string()))?;
    // GPUI and the native surface use physical pixels. ArkUI node callbacks otherwise
    // inherit VP units, even though UIInputEvent getters are documented as pixels.
    xcomponent_native
        .raw()
        .set_length_metric_unit(LengthMetricUnit::Px)
        .map_err(|e| Error::from_reason(e.to_string()))?;
    xcomponent_native
        .background_color(0x0000_0000)
        .map_err(|e| Error::from_reason(e.reason.to_string()))?;
    xcomponent_native
        .set_focusable(true)
        .map_err(|e| Error::from_reason(e.reason.to_string()))?;
    // Window activation does not focus a newly mounted native node. Keyboard
    // shortcuts must reach this surface before the first pointer interaction.
    xcomponent_native
        .set_default_focus(true)
        .map_err(|e| Error::from_reason(e.reason.to_string()))?;
    xcomponent_native
        .set_focus_on_touch(true)
        .map_err(|e| Error::from_reason(e.reason.to_string()))?;

    let content_node = xcomponent_native.raw().raw_handle();
    let xcomponent = xcomponent_native.native_xcomponent();

    let touch_input_delivery =
        app.begin_render(&render_owner, window_id, xcomponent_native.clone())?;
    let mut render_guard = RenderOwnerGuard::new(app.clone(), render_owner.clone());

    let xc = xcomponent.clone();
    let pan_tracker = Rc::new(RefCell::new(PanTracker::default()));
    let created_pan_tracker = pan_tracker.clone();

    let on_surface_created_app = app.clone();
    let on_surface_created_owner = render_owner.clone();

    xcomponent.on_surface_created(move |xc_raw, win| {
        // NDK callback boundary: a panic here aborts the process (no unwinding
        // across "extern C"). Degrade to 0x0 + warn instead (issue #87 minor-2);
        // a subsequent on_surface_changed carries the real geometry.
        let size = xc_raw.size(win).unwrap_or_else(|e| {
            crate::warn!("on_surface_created: size() failed: {e:?}, degrading to 0x0");
            XComponentSize {
                width: 0,
                height: 0,
            }
        });
        let offset = xc_raw.offset(win).unwrap_or_else(|e| {
            crate::warn!("on_surface_created: offset() failed: {e:?}, degrading to 0,0");
            XComponentOffset { x: 0.0, y: 0.0 }
        });
        let origin = content_offset_in_window(content_node.cast());
        let rect = Rect {
            top: origin.map_or(offset.y as i32, |origin| origin.y),
            left: origin.map_or(offset.x as i32, |origin| origin.x),
            width: size.width as _,
            height: size.height as _,
        };
        if !on_surface_created_app.activate_render_surface(
            &on_surface_created_owner,
            xc.native_window(),
            rect,
        ) {
            return Ok(());
        }

        created_pan_tracker.borrow_mut().reset();
        #[cfg(feature = "keyboard-focus-recovery")]
        if let Err(error) = super::install_keyboard_focus_recovery(
            &on_surface_created_app,
            &on_surface_created_owner,
            window_id,
            native_window_id,
        ) {
            crate::warn!("Cannot install native keyboard focus recovery: {error}");
        }
        on_surface_created_app
            .initialize_render_input(&on_surface_created_owner, native_window_id)?;

        {
            if let Some(ref mut h) = *on_surface_created_app.event_loop.borrow_mut() {
                if window_id == 0 {
                    h(Event::SurfaceCreate)
                } else {
                    h(Event::SubWindowSurfaceCreate(window_id))
                }
            }
        }

        // Surface lifetime is valid independently of frame callback registration.
        // The handler may already have selected on-demand scheduling. Reconcile
        // afterwards; failure remains retryable and must never swallow SurfaceCreate.
        if let Err(error) = on_surface_created_app.set_frame_input_delivery_for(
            window_id,
            on_surface_created_app.frame_input_delivery_for(window_id),
        ) {
            crate::warn!("Cannot configure native surface frames: {error}");
        }

        Ok(())
    });

    let on_surface_destroyed_app = app.clone();
    let on_surface_destroyed_owner = render_owner.clone();
    let destroyed_pan_tracker = pan_tracker.clone();
    xcomponent.on_surface_destroyed(move |_, _| {
        destroyed_pan_tracker.borrow_mut().reset();
        if on_surface_destroyed_app.deactivate_render_surface(&on_surface_destroyed_owner) {
            if window_id == 0 {
                on_surface_destroyed_app.dispatch_surface_destroy();
            } else if let Some(ref mut handler) = *on_surface_destroyed_app.event_loop.borrow_mut()
            {
                handler(Event::SubWindowSurfaceDestroy(window_id));
            }
        }
        Ok(())
    });

    let on_surface_changed_app = app.clone();
    let on_surface_changed_owner = render_owner.clone();
    xcomponent.on_surface_changed(move |xc, win| {
        // NDK callback boundary: never panic (issue #87 minor-2). If the geometry
        // can't be read, skip this change event rather than dispatching a bogus
        // 0x0 WindowResize into tao — the next surface-changed callback carries
        // the real values.
        let size = match xc.size(win) {
            Ok(size) => size,
            Err(e) => {
                crate::warn!("on_surface_changed: size() failed: {e:?}, skipping rect update");
                return Ok(());
            }
        };
        let offset = match xc.offset(win) {
            Ok(offset) => offset,
            Err(e) => {
                crate::warn!("on_surface_changed: offset() failed: {e:?}, skipping rect update");
                return Ok(());
            }
        };
        let origin = content_offset_in_window(content_node.cast());
        if on_surface_changed_app.update_render_surface_rect(
            &on_surface_changed_owner,
            Rect {
                top: origin.map_or(offset.y as i32, |origin| origin.y),
                left: origin.map_or(offset.x as i32, |origin| origin.x),
                width: size.width as _,
                height: size.height as _,
            },
        ) {
            if let Some(ref mut h) = *on_surface_changed_app.event_loop.borrow_mut() {
                // Phase 3 (design.md D6 / task 3.5): XComponent is the main window's
                // surface, so window_id is always 0. Carrying it explicitly lets tao's
                // run_loop route WindowResize uniformly (instead of a special-cased ZST).
                h(Event::WindowResize {
                    window_id,
                    size: Size {
                        width: size.width as _,
                        height: size.height as _,
                    },
                })
            }
        }
        Ok(())
    });

    if touch_input_delivery.delivers_raw_touch() {
        let on_touch_event_app = app.clone();
        let on_touch_event_owner = render_owner.clone();
        xcomponent.on_touch_event(move |_, _, data| {
            dispatch_input(
                &on_touch_event_app,
                &on_touch_event_owner,
                InputEvent::XComponent(XComponentInputEvent::Touch(data)),
            );
            Ok(())
        });
    }

    let focus_app = app.clone();
    let focus_owner = render_owner.clone();
    xcomponent_native.on_focus(move || {
        dispatch_focus(&focus_app, &focus_owner, true);
    });
    let blur_app = app.clone();
    let blur_owner = render_owner.clone();
    xcomponent_native.on_blur(move || {
        dispatch_focus(&blur_app, &blur_owner, false);
    });

    let on_key_event_app = app.clone();
    let on_key_event_owner = render_owner.clone();
    match app.keyboard_input_delivery() {
        #[cfg(feature = "keyboard")]
        KeyboardInputDelivery::ArkUi => {
            let pre_ime_app = app.clone();
            let pre_ime_owner = render_owner.clone();
            xcomponent_native.on_key_pre_ime(move |event| {
                if let Some(data) = KeyboardEventData::from_node_callback(event) {
                    if let Some(callback) = pre_ime_app.input_callback(&pre_ime_owner) {
                        callback.key(data);
                    }
                }
                None
            });
            xcomponent_native.on_key_event(move |event| {
                if event.key_event().is_some() {
                    if let Some(callback) = on_key_event_app.input_callback(&on_key_event_owner) {
                        callback.after_ime();
                    }
                }
            });
        }
        KeyboardInputDelivery::RawXComponent => {
            if let Err(error) = xcomponent.on_key_event(move |_, _, data| {
                dispatch_input(
                    &on_key_event_app,
                    &on_key_event_owner,
                    InputEvent::XComponent(XComponentInputEvent::Key(data)),
                );
                Ok(())
            }) {
                crate::warn!("Failed to register XComponent key events: {error:?}");
            }
        }
    }

    let on_mouse_event_app = app.clone();
    let on_mouse_event_owner = render_owner.clone();
    xcomponent.on_mouse_event(move |_, _, data| {
        dispatch_input(
            &on_mouse_event_app,
            &on_mouse_event_owner,
            InputEvent::XComponent(XComponentInputEvent::Mouse(data)),
        );
        Ok(())
    })?;
    let on_hover_event_app = app.clone();
    let on_hover_event_owner = render_owner.clone();
    xcomponent.on_hover_event(move |_, hovered| {
        dispatch_input(
            &on_hover_event_app,
            &on_hover_event_owner,
            InputEvent::XComponent(XComponentInputEvent::Hover(hovered)),
        );
        Ok(())
    })?;
    xcomponent.register_mouse_event_callback()?;

    let on_axis_event_app = app.clone();
    let on_axis_event_owner = render_owner.clone();
    xcomponent.on_ui_input_event(move |_, data| {
        let event = AxisEventData {
            pointer: PointerInputData::from_arkui_event(&data),
            delta_x: data.get_scroll_delta_x().unwrap_or_default(),
            delta_y: data.get_scroll_delta_y().unwrap_or_default(),
            #[cfg(feature = "mouse")]
            scroll_step: data.axis_scroll_step(),
            #[cfg(not(feature = "mouse"))]
            scroll_step: 0,
        };
        dispatch_input(
            &on_axis_event_app,
            &on_axis_event_owner,
            InputEvent::ArkUi(ArkUiInputEvent::Axis(event)),
        );
        Ok(())
    })?;

    // Capture native pointer identity without duplicating the existing mouse/touch stream.
    let pointer_node = xcomponent_native
        .raw()
        .raw_handle()
        .cast::<std::ffi::c_void>();
    let pointer_app = app.clone();
    let pointer_owner = render_owner.clone();
    xcomponent_native.on_mouse(move |event| {
        if let Some(input) = event.input_event() {
            dispatch_input(
                &pointer_app,
                &pointer_owner,
                InputEvent::ArkUi(ArkUiInputEvent::Pointer(pointer_snapshot(
                    &input,
                    pointer_node,
                ))),
            );
        }
    });
    let pointer_app = app.clone();
    let pointer_owner = render_owner.clone();
    xcomponent_native.on_touch_event(move |event| {
        if let Some(input) = event.input_event() {
            dispatch_input(
                &pointer_app,
                &pointer_owner,
                InputEvent::ArkUi(ArkUiInputEvent::Pointer(pointer_snapshot(
                    &input,
                    pointer_node,
                ))),
            );
        }
    });

    #[cfg(feature = "drag")]
    {
        let drag_app = app.clone();
        let drag_owner = render_owner.clone();
        xcomponent_native.on_drag_enter(move |event| {
            if let Some(drag) = event.drag_event() {
                let snapshot = crate::DragInputData::from_event(&drag, crate::DragPhase::Enter);
                let response = snapshot.response.clone();
                negotiate_drag(&drag_app, &drag_owner, snapshot);
                if let Some(operation) = response.operation() {
                    if let Err(error) = drag.set_suggested_drop_operation(operation.native()) {
                        crate::warn!("Failed to suggest drop operation: {error}");
                    }
                }
            }
        });
        let drag_app = app.clone();
        let drag_owner = render_owner.clone();
        xcomponent_native.on_drag_move(move |event| {
            if let Some(drag) = event.drag_event() {
                let snapshot = crate::DragInputData::from_event(&drag, crate::DragPhase::Move);
                let response = snapshot.response.clone();
                negotiate_drag(&drag_app, &drag_owner, snapshot);
                if let Some(operation) = response.operation() {
                    if let Err(error) = drag.set_suggested_drop_operation(operation.native()) {
                        crate::warn!("Failed to suggest drop operation: {error}");
                    }
                }
            }
        });
        let drag_app = app.clone();
        let drag_owner = render_owner.clone();
        xcomponent_native.on_drag_leave(move |event| {
            if let Some(drag) = event.drag_event() {
                let snapshot = crate::DragInputData::from_event(&drag, crate::DragPhase::Leave);
                negotiate_drag(&drag_app, &drag_owner, snapshot);
            }
        });
        let drag_app = app.clone();
        let drag_owner = render_owner.clone();
        xcomponent_native.on_drop(move |event| {
            if let Some(drag) = event.drag_event() {
                let snapshot = crate::DragInputData::from_event(&drag, crate::DragPhase::Drop);
                let response = snapshot.response.clone();
                negotiate_drag(&drag_app, &drag_owner, snapshot);
                use ohos_arkui_binding::types::drag::DragResult;
                let result = if let Some(operation) = response.operation() {
                    if let Err(error) = drag.set_suggested_drop_operation(operation.native()) {
                        crate::warn!("Failed to set drop operation: {error}");
                        DragResult::Failed
                    } else {
                        DragResult::Successful
                    }
                } else {
                    DragResult::Failed
                };
                if let Err(error) = drag.set_drag_result(result) {
                    crate::warn!("Failed to set drag result: {error}");
                }
            }
        });
    }

    if touch_input_delivery.delivers_arkui_gestures() {
        let gestures = register_gestures(&xcomponent_native, &render_owner, &app, pan_tracker)?;
        app.set_render_gestures(&render_owner, gestures)?;
    }

    xcomponent.register_callback()?;

    // Node callbacks and the window ID are usable before native surface creation.
    // Replacing this editor on the first SurfaceCreate would cancel in-flight composition.
    app.initialize_render_input(&render_owner, native_window_id)?;
    root.mount(xcomponent_native)
        .map_err(|error| Error::from_reason(error.reason.to_string()))?;
    render_guard.disarm();

    Ok(root)
}

/// Continuous callbacks remain the default for existing consumers.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum FrameInputDelivery {
    #[default]
    Continuous,
    OnDemand,
}

impl OpenHarmonyApp {
    pub(crate) fn configure_frame_callback(
        &self,
        native: &ohos_xcomponent_binding::NativeXComponent,
        window_id: i64,
        owner: &str,
        delivery: FrameInputDelivery,
    ) -> Result<()> {
        if delivery == FrameInputDelivery::OnDemand {
            return native.unregister_frame_callback();
        }
        let inner = Arc::downgrade(&self.inner);
        let event_loop = Arc::downgrade(&self.event_loop);
        let owner = owner.to_owned();
        native.on_frame_callback(move |_, time, time_stamp| {
            let Some(inner) = inner.upgrade() else {
                return Ok(());
            };
            if !inner
                .read()
                .map(|inner| inner.frame_owner_is_active(&owner))
                .unwrap_or(false)
            {
                return Ok(());
            }
            let Some(event_loop) = event_loop.upgrade() else {
                return Ok(());
            };
            if let Some(handler) = event_loop.borrow_mut().as_mut() {
                let interval = crate::IntervalInfo {
                    time_stamp: time_stamp as _,
                    target_time_stamp: time as _,
                };
                if window_id == 0 {
                    handler(Event::WindowRedraw(interval));
                } else {
                    handler(Event::SubWindowRedraw {
                        window_id,
                        interval,
                    });
                }
            }
            Ok(())
        })
    }
}
