use crate::{GesturePhase, PanGestureEvent, PointerInputData};

/// Owns the cumulative native Pan offset for one live surface and gesture.
#[derive(Default)]
pub(crate) struct PanTracker {
    previous: Option<PanGestureEvent>,
}

impl PanTracker {
    pub(crate) fn reset(&mut self) {
        self.previous = None;
    }

    pub(crate) fn update(&mut self, mut event: PanGestureEvent) -> Option<PanGestureEvent> {
        let (x, y) = match event.phase {
            // Accept already includes the movement through the native recognizer's
            // threshold. Deliver it immediately, including on a restarted gesture.
            GesturePhase::Start => (0.0, 0.0),
            GesturePhase::Update | GesturePhase::End => {
                let previous = self.previous?;
                (previous.offset_x, previous.offset_y)
            }
            GesturePhase::Cancel => return self.cancel(Some(event.pointer)),
        };
        event.delta_x = event.offset_x - x;
        event.delta_y = event.offset_y - y;
        self.previous = (event.phase != GesturePhase::End).then_some(event);
        Some(event)
    }

    pub(crate) fn cancel(&mut self, pointer: Option<PointerInputData>) -> Option<PanGestureEvent> {
        // Some system versions deliver Cancel without an input pointer or Pan data.
        let mut event = self.previous.take()?;
        event.pointer = pointer.unwrap_or(event.pointer);
        event.phase = GesturePhase::Cancel;
        event.delta_x = 0.0;
        event.delta_y = 0.0;
        event.velocity = 0.0;
        event.velocity_x = 0.0;
        event.velocity_y = 0.0;
        Some(event)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ohos_arkui_binding::arkui_input_binding::{
        UIInputAction, UIInputEvent, UIInputSourceType, UIInputToolType,
    };

    fn event(phase: GesturePhase, x: f32, y: f32) -> PanGestureEvent {
        PanGestureEvent {
            pointer: PointerInputData {
                event_type: UIInputEvent::Touch,
                action: UIInputAction::Move,
                source_type: UIInputSourceType::TouchScreen,
                tool_type: UIInputToolType::Finger,
                x: 10.0,
                y: 20.0,
                window_x: 10.0,
                window_y: 20.0,
                display_x: 10.0,
                display_y: 20.0,
                timestamp: 42,
                pointer_count: 1,
                pointer_id: Some(0),
                mouse_buttons_pressed: None,
                stylus: None,
            },
            phase,
            delta_x: 0.0,
            delta_y: 0.0,
            offset_x: x,
            offset_y: y,
            velocity: 100.0,
            velocity_x: 0.0,
            velocity_y: -100.0,
        }
    }

    #[test]
    fn native_start_keeps_threshold_movement_and_restarts_missing_terminal() {
        let mut tracker = PanTracker::default();
        let first = tracker
            .update(event(GesturePhase::Start, 3.0, -12.0))
            .unwrap();
        assert_eq!((first.delta_x, first.delta_y), (3.0, -12.0));
        let moved = tracker
            .update(event(GesturePhase::Update, 7.0, -240.0))
            .unwrap();
        assert_eq!((moved.delta_x, moved.delta_y), (4.0, -228.0));
        let restarted = tracker
            .update(event(GesturePhase::Start, 0.0, -12.0))
            .unwrap();
        assert_eq!((restarted.delta_x, restarted.delta_y), (0.0, -12.0));
        let end = tracker
            .update(event(GesturePhase::End, 0.0, -20.0))
            .unwrap();
        assert_eq!(end.delta_y, -8.0);
        assert!(tracker
            .update(event(GesturePhase::Update, 0.0, -40.0))
            .is_none());
    }

    #[test]
    fn cancel_without_raw_input_uses_last_pointer_and_clears_velocity() {
        let mut tracker = PanTracker::default();
        let initial = event(GesturePhase::Start, 0.0, -12.0);
        tracker.update(initial);
        let cancelled = tracker.cancel(None).unwrap();
        assert_eq!(cancelled.pointer, initial.pointer);
        assert_eq!(cancelled.phase, GesturePhase::Cancel);
        assert_eq!(
            (cancelled.delta_x, cancelled.delta_y, cancelled.velocity_y),
            (0.0, 0.0, 0.0)
        );
        assert!(tracker.cancel(None).is_none());
        assert!(tracker
            .update(event(GesturePhase::End, 0.0, -50.0))
            .is_none());
    }

    #[test]
    fn surface_reset_discards_old_gesture_offsets() {
        let mut tracker = PanTracker::default();
        tracker.update(event(GesturePhase::Start, 0.0, -240.0));
        tracker.reset();
        assert!(tracker
            .update(event(GesturePhase::Update, 0.0, -260.0))
            .is_none());
        assert!(tracker.cancel(None).is_none());
        assert_eq!(
            tracker
                .update(event(GesturePhase::Start, 0.0, 12.0))
                .unwrap()
                .delta_y,
            12.0
        );
    }
}
