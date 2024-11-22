use crate::Configuration;

pub enum Event {
    /// window stage create event
    /// alias onWindowStageCreate
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonwindowstagecreate
    WindowCreate,
    /// window stage destroy event
    /// alias onWindowStageDestroy
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonwindowstagedestroy
    WindowDestroy,

    WindowRedraw,
    /// window resize event
    /// alias window.on("windowSizeChange")
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-window-V5#onwindowsizechange7
    WindowResize,
    /// window rect change event
    /// alias window.on("windowRectChange")
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-window-V5#onwindowrectchange12
    ContentRectChange,


    /// window configuration changed
    /// alias onWindowConfigurationChanged
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-environmentcallback-V5#environmentcallbackonconfigurationupdated
    ConfigChanged(Configuration),
    /// low memory event
    /// alias onMemoryLevel
    /// it will execute when system memory is low(MEMORY_LEVEL_CRITICAL)
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-environmentcallback-V5#environmentcallbackonmemorylevel
    LowMemory,

    /// WindowStateEventChanged 
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-window-V5#onwindowstageevent9
    /// window show
    /// alias WindowStageEventType.SHOWN
    Start,
    /// window stage focus event
    /// alias WindowStageEventType.ACTIVE
    GainedFocus,
    /// window stage unfocus event
    /// alias WindowStageEventType.INAVTIVE
    LostFocus,
    /// window resume
    /// alias WindowStageEventType.RESUMED
    Resume,
    /// window pause
    /// alias WindowStageEventType.PAUSED
    Pause,
    /// window stop
    /// alias WindowStageEventType.HIDDEN
    Stop,


    /// ability save state event
    /// alias onAbilitySaveState
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonabilitysavestate12
    SaveState,
    /// ability destroy event
    /// alias onAbilityDestroy
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonabilitydestroy
    Destroy,
}
