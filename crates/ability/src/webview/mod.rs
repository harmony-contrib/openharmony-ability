use std::{collections::HashMap, rc::Rc};

use napi_ohos::{
    bindgen_prelude::{Function, Object},
    Error, Ref, Result,
};

use crate::helper::{WebViewInitData, WebViewStyle, Webview};

#[cfg(feature = "webview")]
#[derive(Debug, Clone, Default)]
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

    pub fn headers(self, headers: &http::HeaderMap) -> WebViewBuilder {
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
