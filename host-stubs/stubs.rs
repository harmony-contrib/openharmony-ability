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

// Round 6: symbols pulled by the upstream (harmony-contrib) binding bump --
// ohos-arkui-binding 0.6.0 (accessibility element-info/event-info setters,
// drag action/drag-and-drop info, pointer-event clone family, axis events,
// node-utils layout position, mouse-event deltas), ohos-device-binding (canIUse).
// First full host test link of the ohos-patch worktree (LNK2019 sweep).
#[no_mangle]
extern "C" fn canIUse() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetAccessibilityDescription() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetAccessibilityFocused() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetAccessibilityGroup() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetAccessibilityLevel() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetAccessibilityOffset() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetAccessibilityOpacity() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetAccessibilityText() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetBackgroundColor() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetBackgroundImage() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetBlur() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetCheckable() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetChecked() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetChildNodeIds() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetClickable() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetComponentType() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetContents() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetCurrentItemIndex() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetEditable() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetElementId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetEnabled() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetEndItemIndex() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetFocusable() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetFocused() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetGridInfo() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetGridItemInfo() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetHintText() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetHitTestBehavior() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetIsHint() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetIsPassword() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetItemCount() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetLongClickable() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetOperationActions() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetParentId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetRangeInfo() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetScreenRect() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetScrollable() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetSelected() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetSelectedTextEnd() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetSelectedTextStart() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetStartItemIndex() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetVisible() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityElementInfoSetZIndex() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityEventSetElementInfo() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityEventSetEventType() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityEventSetRequestFocusId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AccessibilityEventSetTextAnnouncedForAccessibility() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AddAndGetAccessibilityElementInfo() {}
#[no_mangle]
extern "C" fn OH_ArkUI_AxisEvent_GetAxisAction() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CreateAccessibilityElementInfo() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CreateAccessibilityEventInfo() {}
#[no_mangle]
extern "C" fn OH_ArkUI_CreateDragActionWithNode() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DestoryAccessibilityElementInfo() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DestoryAccessibilityEventInfo() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DragAction_Dispose() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DragAction_SetPointerId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DragAction_SetTouchPointX() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DragAction_SetTouchPointY() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DragAction_UnregisterStatusListener() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DragAndDropInfo_GetDragEvent() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DragAndDropInfo_GetDragStatus() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DragEvent_GetDragResult() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DragEvent_GetDropOperation() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DragEvent_GetTouchPointXToWindow() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DragEvent_GetTouchPointYToWindow() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DragEvent_SetDragResult() {}
#[no_mangle]
extern "C" fn OH_ArkUI_DragEvent_SetSuggestedDropOperation() {}
#[no_mangle]
extern "C" fn OH_ArkUI_FindAccessibilityActionArgumentByKey() {}
#[no_mangle]
extern "C" fn OH_ArkUI_FocusAxisEvent_GetAxisValue() {}
#[no_mangle]
extern "C" fn OH_ArkUI_FocusAxisEvent_SetStopPropagation() {}
#[no_mangle]
extern "C" fn OH_ArkUI_MouseEvent_GetPressedButtons() {}
#[no_mangle]
extern "C" fn OH_ArkUI_MouseEvent_GetRawDeltaX() {}
#[no_mangle]
extern "C" fn OH_ArkUI_MouseEvent_GetRawDeltaY() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeUtils_GetLayoutPosition() {}
#[no_mangle]
extern "C" fn OH_ArkUI_NodeUtils_GetLayoutPositionInScreen() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_CreateClonedEvent() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_DestroyClonedEvent() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetChangedPointerId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetInteractionHand() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetInteractionHandByIndex() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_GetPressedTimeByIndex() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_PostClonedEvent() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_SetClonedEventActionType() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_SetClonedEventChangedFingerId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_SetClonedEventFingerIdByIndex() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_SetClonedEventLocalPosition() {}
#[no_mangle]
extern "C" fn OH_ArkUI_PointerEvent_SetClonedEventLocalPositionByIndex() {}
#[no_mangle]
extern "C" fn OH_ArkUI_SendAccessibilityAsyncEvent() {}
#[no_mangle]
extern "C" fn OH_ArkUI_StartDrag() {}
#[no_mangle]
extern "C" fn OH_ArkUI_UIInputEvent_GetDeviceId() {}
#[no_mangle]
extern "C" fn OH_ArkUI_UIInputEvent_GetPressedKeys() {}
#[no_mangle]
extern "C" fn OH_ArkUI_UIInputEvent_GetTargetDisplayId() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureInfo_Create() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureInfo_GetPixelFormat() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureInfo_GetRowStride() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureInfo_GetSize() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureInfo_GetType() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureInfo_Release() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureInfo_SetPixelFormat() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureInfo_SetRowStride() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureInfo_SetSize() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureInfo_SetType() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureNative_Create() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureNative_GetInfo() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureNative_GetMetadata() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureNative_GetType() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureNative_ReadPixels() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureNative_Release() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureNative_SetInfo() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureNative_SetMetadata() {}
#[no_mangle]
extern "C" fn OH_AuxiliaryPictureNative_WritePixels() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_Create() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_GetCropAndScaleStrategy() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_GetCropRegion() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_GetDesiredColorSpace() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_GetDesiredDynamicRange() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_GetDesiredRegion() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_GetDesiredSize() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_GetIndex() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_GetPixelFormat() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_GetRotate() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_Release() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_SetCropAndScaleStrategy() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_SetCropRegion() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_SetDesiredColorSpace() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_SetDesiredDynamicRange() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_SetDesiredRegion() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_SetDesiredSize() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_SetIndex() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_SetPixelFormat() {}
#[no_mangle]
extern "C" fn OH_DecodingOptions_SetRotate() {}
#[no_mangle]
extern "C" fn OH_DecodingOptionsForPicture_Create() {}
#[no_mangle]
extern "C" fn OH_DecodingOptionsForPicture_GetDesiredAuxiliaryPictures() {}
#[no_mangle]
extern "C" fn OH_DecodingOptionsForPicture_Release() {}
#[no_mangle]
extern "C" fn OH_DecodingOptionsForPicture_SetDesiredAuxiliaryPictures() {}
// OH_Get* deviceinfo family: ohos-device-binding funnels the string members
// through c_str_to_static, which only guards null - a `() {}` body leaves the
// return register undefined, and register residue under some test
// interleavings dereferences to a host ACCESS_VIOLATION (flaky only in
// parallel test mode). These stubs return deterministic values instead:
// null for the string members (the binding maps null -> None) and 0 for the
// version ints (below every API gate, keeping gated host paths on their
// documented "not supported" branch).
#[no_mangle]
extern "C" fn OH_GetAbiList() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetBootloaderVersion() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetBrand() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetBuildHost() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetBuildRootHash() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetBuildTime() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetBuildType() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetBuildUser() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetDeviceType() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetDisplayVersion() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetDistributionOSApiVersion() -> u32 {
    0
}
#[no_mangle]
extern "C" fn OH_GetDistributionOSName() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetDistributionOSReleaseType() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetDistributionOSVersion() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetFirstApiVersion() -> u32 {
    0
}
#[no_mangle]
extern "C" fn OH_GetHardwareModel() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetIncrementalVersion() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetManufacture() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetMarketName() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetOSFullName() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetOsReleaseType() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetProductModel() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetProductSeries() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetSdkApiVersion() -> u32 {
    0
}
#[no_mangle]
extern "C" fn OH_GetSecurityPatchTag() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetSoftwareModel() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_GetVersionId() -> *const core::ffi::c_char {
    core::ptr::null()
}
#[no_mangle]
extern "C" fn OH_ImageNative_GetBufferSize() {}
#[no_mangle]
extern "C" fn OH_ImageNative_GetByteBuffer() {}
#[no_mangle]
extern "C" fn OH_ImageNative_GetComponentTypes() {}
#[no_mangle]
extern "C" fn OH_ImageNative_GetImageSize() {}
#[no_mangle]
extern "C" fn OH_ImageNative_GetPixelStride() {}
#[no_mangle]
extern "C" fn OH_ImageNative_GetRowStride() {}
#[no_mangle]
extern "C" fn OH_ImageNative_GetTimestamp() {}
#[no_mangle]
extern "C" fn OH_ImageNative_Release() {}
#[no_mangle]
extern "C" fn OH_ImagePackerNative_Create() {}
#[no_mangle]
extern "C" fn OH_ImagePackerNative_GetSupportedFormats() {}
#[no_mangle]
extern "C" fn OH_ImagePackerNative_PackToDataFromImageSource() {}
#[no_mangle]
extern "C" fn OH_ImagePackerNative_PackToDataFromPicture() {}
#[no_mangle]
extern "C" fn OH_ImagePackerNative_PackToDataFromPixelmap() {}
#[no_mangle]
extern "C" fn OH_ImagePackerNative_PackToDataFromPixelmapSequence() {}
#[no_mangle]
extern "C" fn OH_ImagePackerNative_PackToFileFromImageSource() {}
#[no_mangle]
extern "C" fn OH_ImagePackerNative_PackToFileFromPicture() {}
#[no_mangle]
extern "C" fn OH_ImagePackerNative_PackToFileFromPixelmap() {}
#[no_mangle]
extern "C" fn OH_ImagePackerNative_PackToFileFromPixelmapSequence() {}
#[no_mangle]
extern "C" fn OH_ImagePackerNative_Release() {}
#[no_mangle]
extern "C" fn OH_ImageReceiverNative_Create() {}
#[no_mangle]
extern "C" fn OH_ImageReceiverNative_GetCapacity() {}
#[no_mangle]
extern "C" fn OH_ImageReceiverNative_GetReceivingSurfaceId() {}
#[no_mangle]
extern "C" fn OH_ImageReceiverNative_GetSize() {}
#[no_mangle]
extern "C" fn OH_ImageReceiverNative_Off() {}
#[no_mangle]
extern "C" fn OH_ImageReceiverNative_OffImageArrive() {}
#[no_mangle]
extern "C" fn OH_ImageReceiverNative_ReadLatestImage() {}
#[no_mangle]
extern "C" fn OH_ImageReceiverNative_ReadNextImage() {}
#[no_mangle]
extern "C" fn OH_ImageReceiverNative_Release() {}
#[no_mangle]
extern "C" fn OH_ImageReceiverOptions_Create() {}
#[no_mangle]
extern "C" fn OH_ImageReceiverOptions_GetCapacity() {}
#[no_mangle]
extern "C" fn OH_ImageReceiverOptions_GetSize() {}
#[no_mangle]
extern "C" fn OH_ImageReceiverOptions_Release() {}
#[no_mangle]
extern "C" fn OH_ImageReceiverOptions_SetCapacity() {}
#[no_mangle]
extern "C" fn OH_ImageReceiverOptions_SetSize() {}
#[no_mangle]
extern "C" fn OH_ImageSourceInfo_Create() {}
#[no_mangle]
extern "C" fn OH_ImageSourceInfo_GetDynamicRange() {}
#[no_mangle]
extern "C" fn OH_ImageSourceInfo_GetHeight() {}
#[no_mangle]
extern "C" fn OH_ImageSourceInfo_GetMimeType() {}
#[no_mangle]
extern "C" fn OH_ImageSourceInfo_GetWidth() {}
#[no_mangle]
extern "C" fn OH_ImageSourceInfo_Release() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_CreateFromData() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_CreateFromFd() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_CreateFromRawFile() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_CreateFromUri() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_CreatePicture() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_CreatePictureAtIndex() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_CreatePixelmap() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_CreatePixelmapList() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_CreatePixelmapUsingAllocator() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_GetDelayTimeList() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_GetFrameCount() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_GetImageInfo() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_GetImageProperty() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_GetImagePropertyWithNull() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_GetSupportedFormats() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_ModifyImageProperty() {}
#[no_mangle]
extern "C" fn OH_ImageSourceNative_Release() {}
#[no_mangle]
extern "C" fn OH_InputMethodProxy_NotifyConfigurationChange() {}
#[no_mangle]
extern "C" fn OH_InputMethodProxy_NotifyCursorUpdate() {}
#[no_mangle]
extern "C" fn OH_InputMethodProxy_NotifySelectionChange() {}
#[no_mangle]
extern "C" fn OH_NativeBuffer_Alloc() {}
#[no_mangle]
extern "C" fn OH_NativeBuffer_FromNativeWindowBuffer() {}
#[no_mangle]
extern "C" fn OH_NativeBuffer_GetConfig() {}
#[no_mangle]
extern "C" fn OH_NativeBuffer_Map() {}
#[no_mangle]
extern "C" fn OH_NativeBuffer_Reference() {}
#[no_mangle]
extern "C" fn OH_NativeBuffer_Unmap() {}
#[no_mangle]
extern "C" fn OH_NativeBuffer_Unreference() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_CreateAllDisplays() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_CreateAvailableArea() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_CreateDisplayById() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_CreatePrimaryDisplay() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_DestroyAllDisplays() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_DestroyAvailableArea() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_DestroyDisplay() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_GetDisplayPosition() {}
#[no_mangle]
extern "C" fn OH_NativeDisplayManager_GetDisplaySourceMode() {}
#[no_mangle]
extern "C" fn OH_NativeWindowManager_RegisterKeyEventFilter() {}
#[no_mangle]
extern "C" fn OH_NativeWindowManager_RegisterMouseEventFilter() {}
#[no_mangle]
extern "C" fn OH_NativeWindowManager_RegisterTouchEventFilter() {}
#[no_mangle]
extern "C" fn OH_NativeWindowManager_UnregisterKeyEventFilter() {}
#[no_mangle]
extern "C" fn OH_NativeWindowManager_UnregisterMouseEventFilter() {}
#[no_mangle]
extern "C" fn OH_NativeWindowManager_UnregisterTouchEventFilter() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_GetTouchPointTiltX() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_GetTouchPointTiltY() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_SetNeedSoftKeyboard() {}
#[no_mangle]
extern "C" fn OH_NativeXComponent_UnregisterOnFrameCallback() {}
#[no_mangle]
extern "C" fn OH_PackingOptions_Create() {}
#[no_mangle]
extern "C" fn OH_PackingOptions_GetDesiredDynamicRange() {}
#[no_mangle]
extern "C" fn OH_PackingOptions_GetMimeType() {}
#[no_mangle]
extern "C" fn OH_PackingOptions_GetMimeTypeWithNull() {}
#[no_mangle]
extern "C" fn OH_PackingOptions_GetNeedsPackProperties() {}
#[no_mangle]
extern "C" fn OH_PackingOptions_GetQuality() {}
#[no_mangle]
extern "C" fn OH_PackingOptions_Release() {}
#[no_mangle]
extern "C" fn OH_PackingOptions_SetDesiredDynamicRange() {}
#[no_mangle]
extern "C" fn OH_PackingOptions_SetMimeType() {}
#[no_mangle]
extern "C" fn OH_PackingOptions_SetNeedsPackProperties() {}
#[no_mangle]
extern "C" fn OH_PackingOptions_SetQuality() {}
#[no_mangle]
extern "C" fn OH_PackingOptionsForSequence_Create() {}
#[no_mangle]
extern "C" fn OH_PackingOptionsForSequence_GetDelayTimeList() {}
#[no_mangle]
extern "C" fn OH_PackingOptionsForSequence_GetDisposalTypes() {}
#[no_mangle]
extern "C" fn OH_PackingOptionsForSequence_GetFrameCount() {}
#[no_mangle]
extern "C" fn OH_PackingOptionsForSequence_GetLoopCount() {}
#[no_mangle]
extern "C" fn OH_PackingOptionsForSequence_Release() {}
#[no_mangle]
extern "C" fn OH_PackingOptionsForSequence_SetDelayTimeList() {}
#[no_mangle]
extern "C" fn OH_PackingOptionsForSequence_SetDisposalTypes() {}
#[no_mangle]
extern "C" fn OH_PackingOptionsForSequence_SetFrameCount() {}
#[no_mangle]
extern "C" fn OH_PackingOptionsForSequence_SetLoopCount() {}
#[no_mangle]
extern "C" fn OH_PictureMetadata_Clone() {}
#[no_mangle]
extern "C" fn OH_PictureMetadata_Create() {}
#[no_mangle]
extern "C" fn OH_PictureMetadata_GetProperty() {}
#[no_mangle]
extern "C" fn OH_PictureMetadata_GetPropertyWithNull() {}
#[no_mangle]
extern "C" fn OH_PictureMetadata_Release() {}
#[no_mangle]
extern "C" fn OH_PictureMetadata_SetProperty() {}
#[no_mangle]
extern "C" fn OH_PictureNative_CreatePicture() {}
#[no_mangle]
extern "C" fn OH_PictureNative_GetAuxiliaryPicture() {}
#[no_mangle]
extern "C" fn OH_PictureNative_GetGainmapPixelmap() {}
#[no_mangle]
extern "C" fn OH_PictureNative_GetHdrComposedPixelmap() {}
#[no_mangle]
extern "C" fn OH_PictureNative_GetMainPixelmap() {}
#[no_mangle]
extern "C" fn OH_PictureNative_GetMetadata() {}
#[no_mangle]
extern "C" fn OH_PictureNative_Release() {}
#[no_mangle]
extern "C" fn OH_PictureNative_SetAuxiliaryPicture() {}
#[no_mangle]
extern "C" fn OH_PictureNative_SetMetadata() {}
#[no_mangle]
extern "C" fn OH_PixelmapImageInfo_Create() {}
#[no_mangle]
extern "C" fn OH_PixelmapImageInfo_GetAlphaMode() {}
#[no_mangle]
extern "C" fn OH_PixelmapImageInfo_GetAlphaType() {}
#[no_mangle]
extern "C" fn OH_PixelmapImageInfo_GetDynamicRange() {}
#[no_mangle]
extern "C" fn OH_PixelmapImageInfo_GetHeight() {}
#[no_mangle]
extern "C" fn OH_PixelmapImageInfo_GetPixelFormat() {}
#[no_mangle]
extern "C" fn OH_PixelmapImageInfo_GetRowStride() {}
#[no_mangle]
extern "C" fn OH_PixelmapImageInfo_GetWidth() {}
#[no_mangle]
extern "C" fn OH_PixelmapImageInfo_Release() {}
#[no_mangle]
extern "C" fn OH_PixelmapInitializationOptions_Create() {}
#[no_mangle]
extern "C" fn OH_PixelmapInitializationOptions_GetAlphaType() {}
#[no_mangle]
extern "C" fn OH_PixelmapInitializationOptions_GetEditable() {}
#[no_mangle]
extern "C" fn OH_PixelmapInitializationOptions_GetHeight() {}
#[no_mangle]
extern "C" fn OH_PixelmapInitializationOptions_GetPixelFormat() {}
#[no_mangle]
extern "C" fn OH_PixelmapInitializationOptions_GetRowStride() {}
#[no_mangle]
extern "C" fn OH_PixelmapInitializationOptions_GetSrcPixelFormat() {}
#[no_mangle]
extern "C" fn OH_PixelmapInitializationOptions_GetWidth() {}
#[no_mangle]
extern "C" fn OH_PixelmapInitializationOptions_Release() {}
#[no_mangle]
extern "C" fn OH_PixelmapInitializationOptions_SetAlphaType() {}
#[no_mangle]
extern "C" fn OH_PixelmapInitializationOptions_SetEditable() {}
#[no_mangle]
extern "C" fn OH_PixelmapInitializationOptions_SetHeight() {}
#[no_mangle]
extern "C" fn OH_PixelmapInitializationOptions_SetPixelFormat() {}
#[no_mangle]
extern "C" fn OH_PixelmapInitializationOptions_SetRowStride() {}
#[no_mangle]
extern "C" fn OH_PixelmapInitializationOptions_SetSrcPixelFormat() {}
#[no_mangle]
extern "C" fn OH_PixelmapInitializationOptions_SetWidth() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_AccessPixels() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_Clone() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_ConvertAlphaFormat() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_ConvertPixelmapNativeFromNapi() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_ConvertPixelmapNativeToNapi() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_CreateAlphaPixelmap() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_CreateCroppedAndScaledPixelMap() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_CreateEmptyPixelmap() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_CreateEmptyPixelmapUsingAllocator() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_CreatePixelmap() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_CreatePixelmapFromNativeBuffer() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_CreatePixelmapFromSurface() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_CreatePixelmapUsingAllocator() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_CreateScaledPixelMap() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_CreateScaledPixelMapWithAntiAliasing() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_Crop() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_Destroy() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_Flip() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_GetAllocationByteCount() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_GetArgbPixels() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_GetByteCount() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_GetColorSpaceNative() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_GetImageInfo() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_GetMetadata() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_GetNativeBuffer() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_GetUniqueId() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_IsReleased() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_Opacity() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_ReadPixels() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_ReadPixelsFromArea() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_Release() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_Rotate() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_Scale() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_ScaleWithAntiAliasing() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_SetColorSpaceNative() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_SetMemoryName() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_SetMetadata() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_ToSdr() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_Translate() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_UnaccessPixels() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_WritePixels() {}
#[no_mangle]
extern "C" fn OH_PixelmapNative_WritePixelsToArea() {}
#[no_mangle]
extern "C" fn OH_Udmf_SetUnifiedData() {}
#[no_mangle]
extern "C" fn OH_UdmfData_AddRecord() {}
#[no_mangle]
extern "C" fn OH_UdmfData_Create() {}
#[no_mangle]
extern "C" fn OH_UdmfData_Destroy() {}
#[no_mangle]
extern "C" fn OH_UdmfData_GetPrimaryHtml() {}
#[no_mangle]
extern "C" fn OH_UdmfData_GetPrimaryPlainText() {}
#[no_mangle]
extern "C" fn OH_UdmfData_GetRecord() {}
#[no_mangle]
extern "C" fn OH_UdmfData_GetRecordCount() {}
#[no_mangle]
extern "C" fn OH_UdmfData_GetRecords() {}
#[no_mangle]
extern "C" fn OH_UdmfData_GetTypes() {}
#[no_mangle]
extern "C" fn OH_UdmfData_HasType() {}
#[no_mangle]
extern "C" fn OH_UdmfData_IsLocal() {}
#[no_mangle]
extern "C" fn OH_UdmfRecord_AddFileUri() {}
#[no_mangle]
extern "C" fn OH_UdmfRecord_AddGeneralEntry() {}
#[no_mangle]
extern "C" fn OH_UdmfRecord_AddHtml() {}
#[no_mangle]
extern "C" fn OH_UdmfRecord_AddPixelMap() {}
#[no_mangle]
extern "C" fn OH_UdmfRecord_AddPlainText() {}
#[no_mangle]
extern "C" fn OH_UdmfRecord_Create() {}
#[no_mangle]
extern "C" fn OH_UdmfRecord_Destroy() {}
#[no_mangle]
extern "C" fn OH_UdmfRecord_GetFileUri() {}
#[no_mangle]
extern "C" fn OH_UdmfRecord_GetGeneralEntry() {}
#[no_mangle]
extern "C" fn OH_UdmfRecord_GetHtml() {}
#[no_mangle]
extern "C" fn OH_UdmfRecord_GetPlainText() {}
#[no_mangle]
extern "C" fn OH_UdmfRecord_GetTypes() {}
#[no_mangle]
extern "C" fn OH_UdsFileUri_Create() {}
#[no_mangle]
extern "C" fn OH_UdsFileUri_Destroy() {}
#[no_mangle]
extern "C" fn OH_UdsFileUri_GetFileType() {}
#[no_mangle]
extern "C" fn OH_UdsFileUri_GetFileUri() {}
#[no_mangle]
extern "C" fn OH_UdsFileUri_SetFileType() {}
#[no_mangle]
extern "C" fn OH_UdsFileUri_SetFileUri() {}
#[no_mangle]
extern "C" fn OH_UdsHtml_Create() {}
#[no_mangle]
extern "C" fn OH_UdsHtml_Destroy() {}
#[no_mangle]
extern "C" fn OH_UdsHtml_GetContent() {}
#[no_mangle]
extern "C" fn OH_UdsHtml_GetPlainContent() {}
#[no_mangle]
extern "C" fn OH_UdsPixelMap_Create() {}
#[no_mangle]
extern "C" fn OH_UdsPixelMap_Destroy() {}
#[no_mangle]
extern "C" fn OH_UdsPixelMap_GetPixelMap() {}
#[no_mangle]
extern "C" fn OH_UdsPixelMap_GetType() {}
#[no_mangle]
extern "C" fn OH_UdsPixelMap_SetPixelMap() {}
#[no_mangle]
extern "C" fn OH_UdsPlainText_Create() {}
#[no_mangle]
extern "C" fn OH_UdsPlainText_Destroy() {}
#[no_mangle]
extern "C" fn OH_UdsPlainText_GetContent() {}
#[no_mangle]
extern "C" fn OH_UdsPlainText_GetType() {}
#[no_mangle]
extern "C" fn OH_Utd_Create() {}
#[no_mangle]
extern "C" fn OH_Utd_Destroy() {}
#[no_mangle]
extern "C" fn OH_Utd_Equals() {}
#[no_mangle]
extern "C" fn OH_Utd_IsHigher() {}
#[no_mangle]
extern "C" fn OH_Utd_IsLower() {}
#[no_mangle]
extern "C" fn OH_WindowManager_GetAllMainWindowInfo() {}
#[no_mangle]
extern "C" fn OH_WindowManager_GetAllWindowLayoutInfoList() {}
#[no_mangle]
extern "C" fn OH_WindowManager_GetMainWindowSnapshot() {}
#[no_mangle]
extern "C" fn OH_WindowManager_GetWindowAvoidArea() {}
#[no_mangle]
extern "C" fn OH_WindowManager_GetWindowProperties() {}
#[no_mangle]
extern "C" fn OH_WindowManager_InjectTouchEvent() {}
#[no_mangle]
extern "C" fn OH_WindowManager_IsWindowShown() {}
#[no_mangle]
extern "C" fn OH_WindowManager_LockCursor() {}
#[no_mangle]
extern "C" fn OH_WindowManager_ReleaseAllMainWindowInfo() {}
#[no_mangle]
extern "C" fn OH_WindowManager_ReleaseAllWindowLayoutInfoList() {}
#[no_mangle]
extern "C" fn OH_WindowManager_ReleaseMainWindowSnapshot() {}
#[no_mangle]
extern "C" fn OH_WindowManager_SetWindowBackgroundColor() {}
#[no_mangle]
extern "C" fn OH_WindowManager_SetWindowBrightness() {}
#[no_mangle]
extern "C" fn OH_WindowManager_SetWindowFocusable() {}
#[no_mangle]
extern "C" fn OH_WindowManager_SetWindowKeepScreenOn() {}
#[no_mangle]
extern "C" fn OH_WindowManager_SetWindowNavigationBarEnabled() {}
#[no_mangle]
extern "C" fn OH_WindowManager_SetWindowPrivacyMode() {}
#[no_mangle]
extern "C" fn OH_WindowManager_SetWindowStatusBarColor() {}
#[no_mangle]
extern "C" fn OH_WindowManager_SetWindowStatusBarEnabled() {}
#[no_mangle]
extern "C" fn OH_WindowManager_SetWindowTouchable() {}
#[no_mangle]
extern "C" fn OH_WindowManager_ShowWindow() {}
#[no_mangle]
extern "C" fn OH_WindowManager_Snapshot() {}
#[no_mangle]
extern "C" fn OH_WindowManager_UnlockCursor() {}
