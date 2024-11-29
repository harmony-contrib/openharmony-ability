use crate::{Configuration, ContentRect, IntervalInfo, SaveLoader, SaveSaver, Size};

pub enum Event {
    /// window stage create event
    /// alias onWindowStageCreate
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonwindowstagecreate
    WindowCreate,
    /// window stage destroy event
    /// alias onWindowStageDestroy
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonwindowstagedestroy
    WindowDestroy,

    WindowRedraw(IntervalInfo),
    /// window resize event
    /// alias window.on("windowSizeChange")
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-window-V5#onwindowsizechange7
    WindowResize(Size),
    /// window rect change event
    /// alias window.on("windowRectChange")
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-window-V5#onwindowrectchange12
    ContentRectChange(ContentRect),

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
    Resume(SaveLoader),
    /// window pause
    /// alias WindowStageEventType.PAUSED
    Pause,
    /// window stop
    /// alias WindowStageEventType.HIDDEN
    Stop,

    /// ability save state event
    /// alias onAbilitySaveState
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonabilitysavestate12
    SaveState(SaveSaver),
    /// ability create event
    /// alias onAbilityCreate
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonabilitycreate
    Create,
    /// ability destroy event
    /// alias onAbilityDestroy
    /// https://developer.huawei.com/consumer/cn/doc/harmonyos-references-V5/js-apis-app-ability-abilitylifecyclecallback-V5#abilitylifecyclecallbackonabilitydestroy
    Destroy,

    /// surface create event
    /// alias onSurfaceCreated for XComponent
    /// We can render EGL/OpenGL in this event
    SurfaceCreate,
    /// surface destroy event
    /// alias onSurfaceDestroyed for XComponent
    SurfaceDestroy,
    /// surface input event
    /// IME
    Input
}

impl Event {
    pub fn as_str(&self) -> &'static str {
        match self {
            Event::WindowCreate => "WindowCreate",
            Event::WindowDestroy => "WindowDestroy",
            Event::WindowRedraw(_) => "WindowRedraw",
            Event::WindowResize(_) => "WindowResize",
            Event::ContentRectChange(_) => "ContentRectChange",
            Event::ConfigChanged(_) => "ConfigChanged",
            Event::LowMemory => "LowMemory",
            Event::Start => "Start",
            Event::GainedFocus => "GainedFocus",
            Event::LostFocus => "LostFocus",
            Event::Resume(_) => "Resume",
            Event::Pause => "Pause",
            Event::Stop => "Stop",
            Event::SaveState(_) => "SaveState",
            Event::Create => "Create",
            Event::Destroy => "Destroy",
            Event::SurfaceCreate => "SurfaceCreate",
            Event::SurfaceDestroy => "SurfaceDestroy",
            Event::Input => "Input",
        }
    }
}
