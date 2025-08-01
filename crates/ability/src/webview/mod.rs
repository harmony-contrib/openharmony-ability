use std::{collections::HashMap, path::PathBuf};

use napi_ohos::{
    bindgen_prelude::{Function, JsObjectValue, ObjectRef},
    Error, Result,
};
use napi_ohos::{Either};

use crate::helper::{DownloadStartResult, WebViewInitData, WebViewStyle, Webview};

mod drag;

#[cfg(feature = "webview")]
#[derive(Default)]
pub struct WebViewBuilder {
    pub url: Option<String>,
    pub style: Option<WebViewStyle>,
    pub javascript_enabled: Option<bool>,
    pub devtools: Option<bool>,
    pub user_agent: Option<String>,
    pub autoplay: Option<bool>,
    pub initialization_scripts: Option<Vec<String>>,
    pub headers: Option<HashMap<String, String>>,
    pub html: Option<String>,
    pub transparent: Option<bool>,

    id: Option<String>,
    #[cfg(feature = "drag_and_drop")]
    on_drag_and_drop: Option<Box<dyn Fn(String) -> ()>>,
    on_download_start: Option<Box<dyn Fn(String, &mut PathBuf) -> bool>>,
    on_download_end: Option<Box<dyn Fn(String, Option<PathBuf>, bool) -> ()>>,
    on_navigation_request: Option<Box<dyn Fn(String) -> bool>>,
    on_title_change: Option<Box<dyn Fn(String) -> ()>>,
}

impl WebViewBuilder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn id<S: Into<String>>(self, id: S) -> WebViewBuilder {
        WebViewBuilder {
            id: Some(id.into()),
            ..self
        }
    }

    pub fn url<S: Into<String>>(self, url: S) -> WebViewBuilder {
        WebViewBuilder {
            url: Some(url.into()),
            ..self
        }
    }

    pub fn style(self, style: WebViewStyle) -> WebViewBuilder {
        WebViewBuilder {
            style: Some(style),
            ..self
        }
    }

    pub fn javascript_enabled(self, javascript_enabled: bool) -> WebViewBuilder {
        WebViewBuilder {
            javascript_enabled: Some(javascript_enabled),
            ..self
        }
    }

    pub fn devtools(self, devtools: bool) -> WebViewBuilder {
        WebViewBuilder {
            devtools: Some(devtools),
            ..self
        }
    }

    pub fn user_agent<S: Into<String>>(self, user_agent: S) -> WebViewBuilder {
        WebViewBuilder {
            user_agent: Some(user_agent.into()),
            ..self
        }
    }

    pub fn autoplay(self, autoplay: bool) -> WebViewBuilder {
        WebViewBuilder {
            autoplay: Some(autoplay),
            ..self
        }
    }

    pub fn initialization_scripts(self, initialization_scripts: Vec<String>) -> WebViewBuilder {
        WebViewBuilder {
            initialization_scripts: Some(initialization_scripts),
            ..self
        }
    }

    pub fn headers(self, headers: http::HeaderMap) -> WebViewBuilder {
        let convert_header: HashMap<String, String> = headers
            .iter()
            .map(|(key, value)| (key.to_string(), value.to_str().unwrap().to_string()))
            .collect();

        WebViewBuilder {
            headers: Some(convert_header),
            ..self
        }
    }

    pub fn html<S: Into<String>>(self, html: S) -> WebViewBuilder {
        WebViewBuilder {
            html: Some(html.into()),
            ..self
        }
    }

    pub fn transparent(self, transparent: bool) -> WebViewBuilder {
        WebViewBuilder {
            transparent: Some(transparent),
            ..self
        }
    }

    #[cfg(feature = "drag_and_drop")]
    pub fn on_drag_and_drop<F: Fn(String) -> ()>(self, on_drag_and_drop: F) -> WebViewBuilder {
        let static_handler = unsafe {
            std::mem::transmute::<Box<dyn Fn(String) -> ()>, Box<dyn Fn(String) -> () + 'static>>(
                Box::new(move |event| on_drag_and_drop(event)),
            )
        };
        WebViewBuilder {
            on_drag_and_drop: Some(static_handler),
            ..self
        }
    }

    pub fn on_download_start<F: Fn(String, &mut PathBuf) -> bool>(
        self,
        on_download_start: F,
    ) -> WebViewBuilder {
        let static_handler = unsafe {
            std::mem::transmute::<
                Box<dyn Fn(String, &mut PathBuf) -> bool>,
                Box<dyn Fn(String, &mut PathBuf) -> bool + 'static>,
            >(Box::new(move |url, temp_path| {
                on_download_start(url, temp_path)
            }))
        };
        WebViewBuilder {
            on_download_start: Some(static_handler),
            ..self
        }
    }

    pub fn on_download_end<F: Fn(String, Option<PathBuf>, bool) -> ()>(
        self,
        on_download_end: F,
    ) -> WebViewBuilder {
        let static_handler = unsafe {
            std::mem::transmute::<
                Box<dyn Fn(String, Option<PathBuf>, bool) -> ()>,
                Box<dyn Fn(String, Option<PathBuf>, bool) -> () + 'static>,
            >(Box::new(move |url, temp_path, success| {
                on_download_end(url, temp_path, success)
            }))
        };
        WebViewBuilder {
            on_download_end: Some(static_handler),
            ..self
        }
    }

    pub fn on_navigation_request<F: Fn(String) -> bool>(
        self,
        on_navigation_request: F,
    ) -> WebViewBuilder {
        let static_handler = unsafe {
            std::mem::transmute::<Box<dyn Fn(String) -> bool>, Box<dyn Fn(String) -> bool + 'static>>(
                Box::new(move |event| on_navigation_request(event)),
            )
        };
        WebViewBuilder {
            on_navigation_request: Some(static_handler),
            ..self
        }
    }

    pub fn on_title_change<F: Fn(String) -> ()>(self, on_title_change: F) -> WebViewBuilder {
        let static_handler = unsafe {
            std::mem::transmute::<Box<dyn Fn(String) -> ()>, Box<dyn Fn(String) -> () + 'static>>(
                Box::new(move |event| on_title_change(event)),
            )
        };
        WebViewBuilder {
            on_title_change: Some(static_handler),
            ..self
        }
    }

    pub fn build(self) -> Result<Webview> {
        let id = self
            .id
            .ok_or(Error::from_reason("WebTag should be provided"))?;

        let ret = unsafe {
            use crate::get_helper;
            get_helper()
        };

        if let Some(h) = ret.borrow().as_ref() {
            use crate::get_main_thread_env;

            if let Some(env) = get_main_thread_env().borrow().as_ref() {
                let ret = h.get_value(&env)?;
                let create_webview_func = ret
                    .get_named_property::<Function<'_, WebViewInitData, ObjectRef>>(
                        "createWebview",
                    )?;

                #[cfg(feature = "drag_and_drop")]
                let on_drag_and_drop = self.on_drag_and_drop.and_then(|handler| {
                    env.create_function_from_closure("on_drag_and_drop", move |ctx| {
                        let ret = ctx.try_get::<String>(1)?;
                        let ret = match ret {
                            Either::A(s) => s,
                            Either::B(_ret) => String::new(),
                        };
                        handler(ret);
                        Ok(())
                    })
                    .ok()
                });

                let on_download_start = self.on_download_start.and_then(|handler| {
                    env.create_function_from_closure("on_download_start", move |ctx| {
                        let origin_url = ctx.try_get::<String>(1)?;
                        let temp_path = ctx.try_get::<String>(2)?;
                        let origin_url_str = match origin_url {
                            Either::A(s) => s,
                            Either::B(_ret) => String::new(),
                        };
                        let temp_path_str = match temp_path {
                            Either::A(s) => s,
                            Either::B(_ret) => String::new(),
                        };
                        let mut temp_path = PathBuf::from(temp_path_str);
                        let ret = handler(origin_url_str, &mut temp_path);
                        Ok(DownloadStartResult {
                            allow: ret,
                            temp_path: Some(temp_path.to_string_lossy().to_string()),
                        }
                        .into())
                    })
                    .ok()
                });

                let on_download_end = self.on_download_end.and_then(|handler| {
                    env.create_function_from_closure("on_download_end", move |ctx| {
                        let origin_url = ctx.try_get::<String>(1)?;
                        let temp_path = ctx.try_get::<String>(2)?;
                        let success = ctx.try_get::<bool>(3)?;
                        let origin_url_str = match origin_url {
                            Either::A(s) => s,
                            Either::B(_ret) => String::new(),
                        };
                        let temp_path_str = match temp_path {
                            Either::A(s) => Some(PathBuf::from(s)),
                            Either::B(_ret) => None,
                        };
                        let success_bool = match success {
                            Either::A(ret) => ret,
                            Either::B(_ret) => false,
                        };
                        handler(origin_url_str, temp_path_str, success_bool);
                        Ok(())
                    })
                    .ok()
                });

                let on_navigation_request = self.on_navigation_request.and_then(|handler| {
                    env.create_function_from_closure("on_navigation_request", move |ctx| {
                        let ret = ctx.try_get::<String>(1)?;
                        let ret = match ret {
                            Either::A(s) => s,
                            Either::B(_ret) => String::new(),
                        };
                        let ret = handler(ret);
                        Ok(ret.into())
                    })
                    .ok()
                });

                let on_title_change = self.on_title_change.and_then(|handler| {
                    env.create_function_from_closure("on_title_change", move |ctx| {
                        let ret = ctx.try_get::<String>(1)?;
                        let ret = match ret {
                            Either::A(s) => s,
                            Either::B(_ret) => String::new(),
                        };
                        handler(ret);
                        Ok(())
                    })
                    .ok()
                });

                let webview = create_webview_func.call(WebViewInitData {
                    url: self.url,
                    id: Some(id.clone()),
                    style: self.style,
                    javascript_enabled: self.javascript_enabled,
                    devtools: self.devtools,
                    user_agent: self.user_agent,
                    autoplay: self.autoplay,
                    initialization_scripts: self.initialization_scripts,
                    headers: self.headers,
                    html: self.html,
                    transparent: self.transparent,
                    #[cfg(feature = "drag_and_drop")]
                    on_drag_and_drop,

                    #[cfg(not(feature = "drag_and_drop"))]
                    on_drag_and_drop: None,
                    on_download_start,
                    on_download_end,
                    on_navigation_request,
                    on_title_change,
                })?;

                let web = Webview::new(id.clone(), webview)?;
                return Ok(web);
            }

            return Err(Error::from_reason("Failed to create webview"));
        }
        Err(Error::from_reason("Failed to create webview"))
    }
}
