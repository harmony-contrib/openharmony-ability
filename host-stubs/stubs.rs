// Host link stubs for the OHOS ArkUI/IME/XComponent/native C symbols
// (ohos-host-stubs.lib, shipped also as ohinputmethod.lib so it is linked
// into every host binary). Each unresolved `OH_*` extern is satisfied with
// an empty function; dlopen/dlsym return NULL so dlopen-based resolvers
// degrade to their documented error path (the device runs the real
// libnative_display_manager.so).
// Provenance: symbols_round1.txt + symbols_round2.txt (pre-migration
// iteration), symbols_round3.txt + symbols_round4.txt (first/second full
// `cargo test --all-targets` host builds after wiring .cargo/config.toml).
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityState_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityState_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityState_GetCheckedState() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityState_IsDisabled() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityState_IsSelected() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityState_SetCheckedState() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityState_SetDisabled() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityState_SetSelected() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityValue_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityValue_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityValue_GetCurrent() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityValue_GetMax() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityValue_GetMin() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityValue_GetText() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityValue_SetCurrent() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityValue_SetMax() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityValue_SetMin() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityValue_SetText() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_GetBiasHorizontal() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_GetBiasVertical() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_GetBottomAlignment() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_GetBottomId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_GetCenterAlignmentHorizontal() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_GetCenterAlignmentVertical() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_GetCenterIdHorizontal() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_GetCenterIdVertical() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_GetEndAlignment() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_GetEndId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_GetStartAlignment() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_GetStartId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_GetTopAlignment() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_GetTopId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_SetBiasHorizontal() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_SetBiasVertical() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_SetBottom() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_SetCenterHorizontal() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_SetCenterVertical() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_SetEnd() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_SetStart() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AlignmentRuleOption_SetTop() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_GetCurve() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_GetDelay() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_GetDuration() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_GetExpectedFrameRateRange() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_GetICurve() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_GetIterations() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_GetPlayMode() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_GetTempo() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_SetCurve() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_SetDelay() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_SetDuration() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_SetExpectedFrameRateRange() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_SetICurve() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_SetIterations() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_SetPlayMode() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimateOption_SetTempo() {}
#[no_mangle]
extern "C" fn OH_ArkUI_Animator_Cancel() {}
#[no_mangle]
extern "C" fn OH_ArkUI_Animator_Finish() {}
#[no_mangle]
extern "C" fn OH_ArkUI_Animator_Pause() {}
#[no_mangle]
extern "C" fn OH_ArkUI_Animator_Play() {}
#[no_mangle]
extern "C" fn OH_ArkUI_Animator_ResetAnimatorOption() {}
#[no_mangle]
extern "C" fn OH_ArkUI_Animator_Reverse() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorEvent_GetUserData() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOnFrameEvent_GetUserData() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOnFrameEvent_GetValue() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_GetBegin() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_GetCurve() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_GetDelay() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_GetDirection() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_GetDuration() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_GetEnd() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_GetExpectedFrameRateRange() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_GetFill() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_GetIterations() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_GetKeyframeCurve() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_GetKeyframeTime() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_GetKeyframeValue() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_RegisterOnCancelCallback() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_RegisterOnFinishCallback() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_RegisterOnFrameCallback() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_RegisterOnRepeatCallback() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_SetBegin() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_SetCurve() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_SetDelay() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_SetDirection() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_SetDuration() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_SetEnd() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_SetExpectedFrameRateRange() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_SetFill() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_SetIterations() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_SetKeyframe() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AnimatorOption_SetKeyframeCurve() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AxisEvent_GetHorizontalAxisValue() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AxisEvent_GetPinchAxisScaleValue() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AxisEvent_GetVerticalAxisValue() {}
#[no_mangle]
extern "C" fn OH_ArkUI_BarrierOption_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_BarrierOption_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_BarrierOption_GetDirection() {}
#[no_mangle]
extern "C" fn OH_ArkUI_BarrierOption_GetId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_BarrierOption_GetReferencedId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_BarrierOption_GetReferencedIdSize() {}
#[no_mangle]
extern "C" fn OH_ArkUI_BarrierOption_SetDirection() {}
#[no_mangle]
extern "C" fn OH_ArkUI_BarrierOption_SetId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_BarrierOption_SetReferencedId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CreateAsymmetricTransitionEffect() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CreateMovementTransitionEffect() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CreateOpacityTransitionEffect() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CreateRotationTransitionEffect() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CreateScaleTransitionEffect() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CreateTranslationTransitionEffect() {}
#[no_mangle]
extern "C" fn OH_ArkUI_Curve_CreateCubicBezierCurve() {}
#[no_mangle]
extern "C" fn OH_ArkUI_Curve_CreateCurveByType() {}
#[no_mangle]
extern "C" fn OH_ArkUI_Curve_CreateInterpolatingSpring() {}
#[no_mangle]
extern "C" fn OH_ArkUI_Curve_CreateResponsiveSpringMotion() {}
#[no_mangle]
extern "C" fn OH_ArkUI_Curve_CreateSpringCurve() {}
#[no_mangle]
extern "C" fn OH_ArkUI_Curve_CreateSpringMotion() {}
#[no_mangle]
extern "C" fn OH_ArkUI_Curve_CreateStepsCurve() {}
#[no_mangle]
extern "C" fn OH_ArkUI_Curve_DisposeCurve() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CustomSpanDrawInfo_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CustomSpanDrawInfo_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CustomSpanDrawInfo_GetBaseline() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CustomSpanDrawInfo_GetLineBottom() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CustomSpanDrawInfo_GetLineTop() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CustomSpanDrawInfo_GetXOffset() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CustomSpanMeasureInfo_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CustomSpanMeasureInfo_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CustomSpanMeasureInfo_GetFontSize() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CustomSpanMetrics_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CustomSpanMetrics_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CustomSpanMetrics_SetHeight() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CustomSpanMetrics_SetWidth() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DialogDismissEvent_GetDismissReason() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DialogDismissEvent_GetUserData() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DialogDismissEvent_SetShouldBlockDismiss() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DrawContext_GetCanvas() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DrawContext_GetSize() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GestureEvent_GetActionType() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GestureEvent_GetNode() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GestureEvent_GetRawInputEvent() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GestureEventTargetInfo_IsScrollBegin() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GestureEventTargetInfo_IsScrollEnd() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GestureInterruptInfo_GetGestureEvent() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GestureInterruptInfo_GetRecognizer() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GestureInterruptInfo_GetSystemFlag() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GestureInterruptInfo_GetSystemRecognizerType() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GetContextByNode() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GetContextFromNapiValue() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GetGestureBindNodeId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GetGestureEventTargetInfo() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GetGestureRecognizerEnabled() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GetGestureRecognizerState() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GetGestureTag() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GetNodeContentFromNapiValue() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GetNodeHandleFromNapiValue() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GetPanGestureDirectionMask() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GetResponseRecognizersFromInterruptInfo() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GuidelineOption_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GuidelineOption_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GuidelineOption_GetDirection() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GuidelineOption_GetId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GuidelineOption_GetPositionEnd() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GuidelineOption_GetPositionStart() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GuidelineOption_SetDirection() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GuidelineOption_SetId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GuidelineOption_SetPositionEnd() {}
#[no_mangle]
extern "C" fn OH_ArkUI_GuidelineOption_SetPositionStart() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ImageAnimatorFrameInfo_CreateFromString() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ImageAnimatorFrameInfo_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ImageAnimatorFrameInfo_GetDuration() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ImageAnimatorFrameInfo_GetHeight() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ImageAnimatorFrameInfo_GetLeft() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ImageAnimatorFrameInfo_GetTop() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ImageAnimatorFrameInfo_GetWidth() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ImageAnimatorFrameInfo_SetDuration() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ImageAnimatorFrameInfo_SetHeight() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ImageAnimatorFrameInfo_SetLeft() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ImageAnimatorFrameInfo_SetTop() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ImageAnimatorFrameInfo_SetWidth() {}
#[no_mangle]
extern "C" fn OH_ArkUI_IsBuiltInGesture() {}
#[no_mangle]
extern "C" fn OH_ArkUI_IsGestureRecognizerValid() {}
#[no_mangle]
extern "C" fn OH_ArkUI_KeyframeAnimateOption_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_KeyframeAnimateOption_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_KeyframeAnimateOption_GetCurve() {}
#[no_mangle]
extern "C" fn OH_ArkUI_KeyframeAnimateOption_GetDelay() {}
#[no_mangle]
extern "C" fn OH_ArkUI_KeyframeAnimateOption_GetDuration() {}
#[no_mangle]
extern "C" fn OH_ArkUI_KeyframeAnimateOption_GetIterations() {}
#[no_mangle]
extern "C" fn OH_ArkUI_KeyframeAnimateOption_RegisterOnEventCallback() {}
#[no_mangle]
extern "C" fn OH_ArkUI_KeyframeAnimateOption_RegisterOnFinishCallback() {}
#[no_mangle]
extern "C" fn OH_ArkUI_KeyframeAnimateOption_SetCurve() {}
#[no_mangle]
extern "C" fn OH_ArkUI_KeyframeAnimateOption_SetDelay() {}
#[no_mangle]
extern "C" fn OH_ArkUI_KeyframeAnimateOption_SetDuration() {}
#[no_mangle]
extern "C" fn OH_ArkUI_KeyframeAnimateOption_SetIterations() {}
#[no_mangle]
extern "C" fn OH_ArkUI_LayoutConstraint_Copy() {}
#[no_mangle]
extern "C" fn OH_ArkUI_LayoutConstraint_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_LayoutConstraint_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_LayoutConstraint_GetMaxHeight() {}
#[no_mangle]
extern "C" fn OH_ArkUI_LayoutConstraint_GetMaxWidth() {}
#[no_mangle]
extern "C" fn OH_ArkUI_LayoutConstraint_GetMinHeight() {}
#[no_mangle]
extern "C" fn OH_ArkUI_LayoutConstraint_GetMinWidth() {}
#[no_mangle]
extern "C" fn OH_ArkUI_LayoutConstraint_GetPercentReferenceHeight() {}
#[no_mangle]
extern "C" fn OH_ArkUI_LayoutConstraint_GetPercentReferenceWidth() {}
#[no_mangle]
extern "C" fn OH_ArkUI_LayoutConstraint_SetMaxHeight() {}
#[no_mangle]
extern "C" fn OH_ArkUI_LayoutConstraint_SetMaxWidth() {}
#[no_mangle]
extern "C" fn OH_ArkUI_LayoutConstraint_SetMinHeight() {}
#[no_mangle]
extern "C" fn OH_ArkUI_LayoutConstraint_SetMinWidth() {}
#[no_mangle]
extern "C" fn OH_ArkUI_LayoutConstraint_SetPercentReferenceHeight() {}
#[no_mangle]
extern "C" fn OH_ArkUI_LayoutConstraint_SetPercentReferenceWidth() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListChildrenMainSizeOption_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListChildrenMainSizeOption_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListChildrenMainSizeOption_GetDefaultMainSize() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListChildrenMainSizeOption_GetMainSize() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListChildrenMainSizeOption_Resize() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListChildrenMainSizeOption_SetDefaultMainSize() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListChildrenMainSizeOption_Splice() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListChildrenMainSizeOption_UpdateSize() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListItemSwipeActionItem_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListItemSwipeActionItem_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListItemSwipeActionItem_GetActionAreaDistance() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListItemSwipeActionItem_SetActionAreaDistance() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListItemSwipeActionItem_SetContent() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListItemSwipeActionItem_SetOnActionWithUserData() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListItemSwipeActionItem_SetOnEnterActionAreaWithUserData() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListItemSwipeActionItem_SetOnExitActionAreaWithUserData() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListItemSwipeActionItem_SetOnStateChangeWithUserData() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListItemSwipeActionOption_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListItemSwipeActionOption_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListItemSwipeActionOption_GetEdgeEffect() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListItemSwipeActionOption_SetEdgeEffect() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListItemSwipeActionOption_SetEnd() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListItemSwipeActionOption_SetOnOffsetChangeWithUserData() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ListItemSwipeActionOption_SetStart() {}
#[no_mangle]
extern "C" fn OH_ArkUI_LongPress_GetRepeatCount() {}
#[no_mangle]
extern "C" fn OH_ArkUI_MouseEvent_GetMouseAction() {}
#[no_mangle]
extern "C" fn OH_ArkUI_MouseEvent_GetMouseButton() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapter_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapter_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapter_GetAllItems() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapter_GetTotalNodeCount() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapter_InsertItem() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapter_MoveItem() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapter_ReloadAllItems() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapter_ReloadItem() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapter_RemoveItem() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapter_SetTotalNodeCount() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapter_UnregisterEventReceiver() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapterEvent_GetHostNode() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapterEvent_GetItemIndex() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapterEvent_GetRemovedNode() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapterEvent_GetType() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapterEvent_GetUserData() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapterEvent_SetItem() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeAdapterEvent_SetNodeId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeContent_AddNode() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeContent_GetUserData() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeContent_InsertNode() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeContent_RegisterCallback() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeContent_RemoveNode() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeContent_SetUserData() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeContentEvent_GetEventType() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeContentEvent_GetNodeContentHandle() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeCustomEvent_GetCustomSpanDrawInfo() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeCustomEvent_GetCustomSpanMeasureInfo() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeCustomEvent_GetDrawContextInDraw() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeCustomEvent_GetEventTargetId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeCustomEvent_GetEventType() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeCustomEvent_GetLayoutConstraintInMeasure() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeCustomEvent_GetNodeHandle() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeCustomEvent_GetPositionInLayout() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeCustomEvent_GetUserData() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeCustomEvent_SetCustomSpanMetrics() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeEvent_GetDragEvent() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeEvent_GetEventType() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeEvent_GetInputEvent() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeEvent_GetNodeComponentEvent() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeEvent_GetNodeHandle() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeEvent_GetNumberValue() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeEvent_GetPreDragStatus() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeEvent_GetStringAsyncEvent() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeEvent_GetStringValue() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeEvent_GetTargetId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeEvent_GetUserData() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeEvent_SetReturnNumberValue() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeUtils_GetLayoutPositionInWindow() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeUtils_GetLayoutSize() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeUtils_GetPositionWithTranslateInWindow() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PanGesture_GetOffsetX() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PanGesture_GetOffsetY() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PanGesture_GetVelocity() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PanGesture_GetVelocityX() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PanGesture_GetVelocityY() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ParallelInnerGestureEvent_GetConflictRecognizers() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ParallelInnerGestureEvent_GetCurrentRecognizer() {}
#[no_mangle]
extern "C" fn OH_ArkUI_ParallelInnerGestureEvent_GetUserData() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PinchGesture_GetCenterX() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PinchGesture_GetCenterY() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PinchGesture_GetScale() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetDisplayX() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetDisplayXByIndex() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetDisplayY() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetDisplayYByIndex() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetHistoryDisplayX() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetHistoryDisplayY() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetHistoryEventTime() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetHistoryPointerCount() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetHistoryPointerId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetHistoryPressure() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetHistorySize() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetHistoryTiltX() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetHistoryTiltY() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetHistoryTouchAreaHeight() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetHistoryTouchAreaWidth() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetHistoryWindowX() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetHistoryWindowY() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetHistoryX() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetHistoryY() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetPointerCount() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetPointerId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetPressure() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetTiltX() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetTiltY() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetTouchAreaHeight() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetTouchAreaWidth() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetWindowX() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetWindowXByIndex() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetWindowY() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetWindowYByIndex() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetX() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetXByIndex() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetY() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetYByIndex() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_SetInterceptHitTestMode() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_SetStopPropagation() {}
#[no_mangle]
extern "C" fn OH_ArkUI_QueryModuleInterfaceByName() {}
#[no_mangle]
extern "C" fn OH_ArkUI_RotationGesture_GetAngle() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SetArkUIGestureRecognizerDisposeNotify() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SetGestureRecognizerEnabled() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwipeGesture_GetAngle() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwipeGesture_GetVelocity() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_GetBottomPosition() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_GetColor() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_GetEndPosition() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_GetItemHeight() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_GetItemWidth() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_GetMask() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_GetMaxDisplayCount() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_GetSelectedColor() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_GetSelectedItemHeight() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_GetSelectedItemWidth() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_GetStartPosition() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_GetTopPosition() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_SetBottomPosition() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_SetColor() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_SetEndPosition() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_SetItemHeight() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_SetItemWidth() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_SetMask() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_SetMaxDisplayCount() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_SetSelectedColor() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_SetSelectedItemHeight() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_SetSelectedItemWidth() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_SetStartPosition() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SwiperIndicator_SetTopPosition() {}
#[no_mangle]
extern "C" fn OH_ArkUI_TransitionEffect_Combine() {}
#[no_mangle]
extern "C" fn OH_ArkUI_TransitionEffect_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_TransitionEffect_SetAnimation() {}
#[no_mangle]
extern "C" fn OH_ArkUI_UIInputEvent_GetAction() {}
#[no_mangle]
extern "C" fn OH_ArkUI_UIInputEvent_GetEventTime() {}
#[no_mangle]
extern "C" fn OH_ArkUI_UIInputEvent_GetSourceType() {}
#[no_mangle]
extern "C" fn OH_ArkUI_UIInputEvent_GetToolType() {}
#[no_mangle]
extern "C" fn OH_ArkUI_UIInputEvent_GetType() {}
#[no_mangle]
extern "C" fn OH_ArkUI_WaterFlowSectionOption_Create() {}
#[no_mangle]
extern "C" fn OH_ArkUI_WaterFlowSectionOption_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_WaterFlowSectionOption_GetColumnGap() {}
#[no_mangle]
extern "C" fn OH_ArkUI_WaterFlowSectionOption_GetCrossCount() {}
#[no_mangle]
extern "C" fn OH_ArkUI_WaterFlowSectionOption_GetItemCount() {}
#[no_mangle]
extern "C" fn OH_ArkUI_WaterFlowSectionOption_GetMargin() {}
#[no_mangle]
extern "C" fn OH_ArkUI_WaterFlowSectionOption_GetRowGap() {}
#[no_mangle]
extern "C" fn OH_ArkUI_WaterFlowSectionOption_GetSize() {}
#[no_mangle]
extern "C" fn OH_ArkUI_WaterFlowSectionOption_RegisterGetItemMainSizeCallbackByIndexWithUserData() {
}
#[no_mangle]
extern "C" fn OH_ArkUI_WaterFlowSectionOption_SetColumnGap() {}
#[no_mangle]
extern "C" fn OH_ArkUI_WaterFlowSectionOption_SetCrossCount() {}
#[no_mangle]
extern "C" fn OH_ArkUI_WaterFlowSectionOption_SetItemCount() {}
#[no_mangle]
extern "C" fn OH_ArkUI_WaterFlowSectionOption_SetMargin() {}
#[no_mangle]
extern "C" fn OH_ArkUI_WaterFlowSectionOption_SetRowGap() {}
#[no_mangle]
extern "C" fn OH_ArkUI_WaterFlowSectionOption_SetSize() {}
#[no_mangle]
extern "C" fn OH_AttachOptions_Create() {}
#[no_mangle]
extern "C" fn OH_AttachOptions_Destroy() {}
#[no_mangle]
extern "C" fn OH_AttachOptions_IsShowKeyboard() {}
#[no_mangle]
extern "C" fn OH_CursorInfo_Create() {}
#[no_mangle]
extern "C" fn OH_CursorInfo_Destroy() {}
#[no_mangle]
extern "C" fn OH_CursorInfo_GetRect() {}
#[no_mangle]
extern "C" fn OH_CursorInfo_SetRect() {}
#[no_mangle]
extern "C" fn OH_InputMethodController_Attach() {}
#[no_mangle]
extern "C" fn OH_InputMethodController_Detach() {}
#[no_mangle]
extern "C" fn OH_InputMethodProxy_HideKeyboard() {}
#[no_mangle]
extern "C" fn OH_InputMethodProxy_ShowKeyboard() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_CreateDefaultDisplayCutoutInfo() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_DestroyDefaultDisplayCutoutInfo() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_GetDefaultDisplayDensityDpi() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_GetDefaultDisplayDensityPixels() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_GetDefaultDisplayDensityXdpi() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_GetDefaultDisplayDensityYdpi() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_GetDefaultDisplayHeight() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_GetDefaultDisplayId() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_GetDefaultDisplayOrientation() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_GetDefaultDisplayRefreshRate() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_GetDefaultDisplayRotation() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_GetDefaultDisplayScaledDensity() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_GetDefaultDisplayVirtualPixelRatio() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_GetDefaultDisplayWidth() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_GetFoldDisplayMode() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_IsFoldable() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_GetKeyEvent() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_GetKeyEventAction() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_GetKeyEventCode() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_GetKeyEventDeviceId() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_GetKeyEventSourceType() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_GetKeyEventTimestamp() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_GetMouseEvent() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_GetNativeXComponent() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_GetTouchEvent() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_GetTouchPointToolType() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_GetXComponentId() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_GetXComponentOffset() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_GetXComponentSize() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_RegisterCallback() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_RegisterMouseEventCallback() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_RegisterOnFrameCallback() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_SetExpectedFrameRateRange() {}
#[no_mangle]
extern "C" fn OH_PrivateCommand_Destroy() {}
#[no_mangle]
extern "C" fn OH_TextConfig_Create() {}
#[no_mangle]
extern "C" fn OH_TextConfig_Destroy() {}
#[no_mangle]
extern "C" fn OH_TextConfig_GetCursorInfo() {}
#[no_mangle]
extern "C" fn OH_TextConfig_GetEnterKeyType() {}
#[no_mangle]
extern "C" fn OH_TextConfig_GetInputType() {}
#[no_mangle]
extern "C" fn OH_TextConfig_GetSelection() {}
#[no_mangle]
extern "C" fn OH_TextConfig_GetWindowId() {}
#[no_mangle]
extern "C" fn OH_TextConfig_IsPreviewTextSupported() {}
#[no_mangle]
extern "C" fn OH_TextConfig_SetEnterKeyType() {}
#[no_mangle]
extern "C" fn OH_TextConfig_SetInputType() {}
#[no_mangle]
extern "C" fn OH_TextConfig_SetPreviewTextSupport() {}
#[no_mangle]
extern "C" fn OH_TextConfig_SetSelection() {}
#[no_mangle]
extern "C" fn OH_TextConfig_SetWindowId() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_Create() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_Destroy() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_SetDeleteBackwardFunc() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_SetDeleteForwardFunc() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_SetFinishTextPreviewFunc() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_SetGetLeftTextOfCursorFunc() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_SetGetRightTextOfCursorFunc() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_SetGetTextConfigFunc() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_SetGetTextIndexAtCursorFunc() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_SetHandleExtendActionFunc() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_SetHandleSetSelectionFunc() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_SetInsertTextFunc() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_SetMoveCursorFunc() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_SetReceivePrivateCommandFunc() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_SetSendEnterKeyFunc() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_SetSendKeyboardStatusFunc() {}
#[no_mangle]
extern "C" fn OH_TextEditorProxy_SetSetPreviewTextFunc() {}

// --- round 3 (2026-10-26, host link triage of full `cargo test --all-targets`) ---
// Unresolved symbols reported by LNK2019/LNK1120 on the first full host test
// build with the wired -L native=target/host-stub-libs path. dlopen/dlsym move
// here from stub-web.rs: crates/ability display.rs declares them directly, so
// every host link that pulls the ability crate needs them (ohweb.lib is only
// pulled by links that include ohos-web-sys).
#[no_mangle]
extern "C" fn dlopen(_filename: *const i8, _flags: i32) -> *mut core::ffi::c_void {
    core::ptr::null_mut()
}
#[no_mangle]
extern "C" fn dlsym(_handle: *mut core::ffi::c_void, _symbol: *const i8) -> *mut core::ffi::c_void {
    core::ptr::null_mut()
}
#[no_mangle]
extern "C" fn OH_NativeXComponent_RegisterKeyEventCallback() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_RegisterUIInputEventCallback() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_GetNativeAccessibilityProvider() {}

// --- round 4 (2026-10-26, second host link triage) ---
// 36 symbols unresolved after round 3 (round-4 census: 27 OH_ResourceManager_* then +
// 8 ArkWeb + 1 OH_LOG_Print; round 5 later added 2 more RM stubs, so the RM subset below
// counts 29 today): the OH_ResourceManager_* subset the
// host links actually reference (29 of the 67 the binding declares, not the
// full family; the remaining 38 are deliberately not stubbed -- round 5 note
// below; ohresmgr.lib is an empty existence-only archive), 8 ArkWeb
// scheme-handler/resource symbols referenced by the demo NAPI crates,
// and OH_LOG_Print (hilog binding). All land in the always-linked
// archive; none overlap the ohweb.lib ArkWeb set, so no LNK2005 risk.
#[no_mangle]
extern "C" fn OH_ArkWeb_SetSchemeHandler() {}
#[no_mangle]
extern "C" fn OH_ArkWebHttpBodyStream_Read() {}
#[no_mangle]
extern "C" fn OH_ArkWebHttpBodyStream_SetReadCallback() {}
#[no_mangle]
extern "C" fn OH_ArkWebHttpBodyStream_SetUserData() {}
#[no_mangle]
extern "C" fn OH_ArkWebResourceHandler_DidReceiveData() {}
#[no_mangle]
extern "C" fn OH_ArkWebResponse_SetHeaderByName() {}
#[no_mangle]
extern "C" fn OH_ArkWebSchemeHandler_SetOnRequestStart() {}
#[no_mangle]
extern "C" fn OH_ArkWebSchemeHandler_SetUserData() {}
#[no_mangle]
extern "C" fn OH_LOG_Print() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_CloseRawDir() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_CloseRawFile() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_CloseRawFile64() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_GetDrawableDescriptor() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_GetDrawableDescriptorByName() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_GetMedia() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_GetMediaBase64() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_GetMediaBase64ByName() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_GetMediaByName() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_GetRawFileCount() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_GetRawFileDescriptor64() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_GetRawFileDescriptorData() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_GetRawFileName() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_GetRawFileOffset() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_GetRawFileOffset64() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_GetRawFileRemainingLength() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_GetRawFileRemainingLength64() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_GetRawFileSize() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_GetRawFileSize64() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_InitNativeResourceManager() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_IsRawDir() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_OpenRawDir() {}
// round 5 (2026-10-28): missed by round 4 -- both exist in the resource-manager
// binding since at least 0.3.1 (the version Cargo.lock pins; 0.3.1-0.3.4 all
// declare the same 67 OH_ResourceManager_* symbols, so this is not a
// dependency-upgrade artifact) and are pulled into the plugin-resource +
// demo_native host links through the binding crate (LNK2019).
// Scope (PR#55 review gate F2): the stubs cover the OH_ResourceManager_*
// symbols the workspace's host links actually reference -- 29 of the 67 the
// binding declares. The remaining 38 are unreferenced today and deliberately
// not stubbed; a future link that pulls one fails with LNK2019 and gets its
// stub added here on demand.
#[no_mangle]
extern "C" fn OH_ResourceManager_OpenRawFile() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_OpenRawFile64() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_ReadRawFile() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_ReadRawFile64() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_ReleaseNativeResourceManager() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_SeekRawFile() {}
#[no_mangle]
extern "C" fn OH_ResourceManager_SeekRawFile64() {}
