use std::cell::RefCell;
use std::{collections::HashMap, rc::Rc};

use napi_ohos::{
    bindgen_prelude::{Function, Object},
    Error, Ref, Result,
};
use napi_ohos::{Either, JsString};

use crate::helper::{WebViewInitData, WebViewStyle, Webview};

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
    on_drag_and_drop: Option<Box<dyn Fn(String) -> ()>>,
    on_download_start: Option<Box<dyn Fn(String) -> ()>>,
    on_download_end: Option<Box<dyn Fn(String) -> ()>>,
    on_navigation_request: Option<Box<dyn Fn(String) -> bool>>,
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

    pub fn on_download_start<F: Fn(String) -> ()>(self, on_download_start: F) -> WebViewBuilder {
        let static_handler = unsafe {
            std::mem::transmute::<Box<dyn Fn(String) -> ()>, Box<dyn Fn(String) -> () + 'static>>(
                Box::new(move |event| on_download_start(event)),
            )
        };
        WebViewBuilder {
            on_download_start: Some(static_handler),
            ..self
        }
    }

    pub fn on_download_end<F: Fn(String) -> ()>(self, on_download_end: F) -> WebViewBuilder {
        let static_handler = unsafe {
            std::mem::transmute::<Box<dyn Fn(String) -> ()>, Box<dyn Fn(String) -> () + 'static>>(
                Box::new(move |event| on_download_end(event)),
            )
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
                    .get_named_property::<Function<'_, WebViewInitData, Rc<Object>>>(
                        "createWebview",
                    )?;

                let on_drag_and_drop = self.on_drag_and_drop.and_then(|handler| {
                    env.create_function_from_closure("on_drag_and_drop", move |ctx| {
                        let ret = ctx.try_get::<JsString>(1)?;
                        let ret = match ret {
                            Either::A(ret) => ret.into_utf8()?.as_str()?.to_string(),
                            Either::B(_ret) => String::new(),
                        };
                        handler(ret);
                        Ok(())
                    })
                    .ok()
                });

                let on_download_start = self.on_download_start.and_then(|handler| {
                    env.create_function_from_closure("on_download_start", move |ctx| {
                        let ret = ctx.try_get::<JsString>(1)?;
                        let ret = match ret {
                            Either::A(ret) => ret.into_utf8()?.as_str()?.to_string(),
                            Either::B(_ret) => String::new(),
                        };
                        handler(ret);
                        Ok(())
                    })
                    .ok()
                });

                let on_download_end = self.on_download_end.and_then(|handler| {
                    env.create_function_from_closure("on_download_end", move |ctx| {
                        let ret = ctx.try_get::<JsString>(1)?;
                        let ret = match ret {
                            Either::A(ret) => ret.into_utf8()?.as_str()?.to_string(),
                            Either::B(_ret) => String::new(),
                        };
                        handler(ret);
                        Ok(())
                    })
                    .ok()
                });

                let on_navigation_request = self.on_navigation_request.and_then(|handler| {
                    env.create_function_from_closure("on_navigation_request", move |ctx| {
                        let ret = ctx.try_get::<JsString>(1)?;
                        let ret = match ret {
                            Either::A(ret) => ret.into_utf8()?.as_str()?.to_string(),
                            Either::B(_ret) => String::new(),
                        };
                        let ret = handler(ret);
                        Ok(ret.into())
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
                    on_drag_and_drop,
                    on_download_start,
                    on_download_end,
                    on_navigation_request,
                })?;

                let webview_ref = Ref::new(env, &*webview)?;

                let web = Webview::new(id.clone(), webview_ref)?;
                return Ok(web);
            }

            return Err(Error::from_reason("Failed to create webview"));
        }
        Err(Error::from_reason("Failed to create webview"))
    }
}
