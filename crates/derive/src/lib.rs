use proc_macro::TokenStream;
use syn::ItemFn;

#[proc_macro_attribute]
pub fn ability(_attr: TokenStream, item: TokenStream) -> TokenStream {
    let ast = syn::parse_macro_input!(item as ItemFn);
    let fn_name = &ast.sig.ident;
    let block = &ast.block;

    let f = quote::quote! {
        fn #fn_name(app: &openharmony_ability::App) #block

        thread_local! {
            pub static APP: std::cell::RefCell<App> = std::cell::RefCell::new(App::new());
            pub static ROOT_NODE: std::cell::RefCell<Option<openharmony_ability::arkui::RootNode>> = std::cell::RefCell::new(None);
        }
        
        #[napi_derive_ohos::js_function(1)]
        pub fn init(
            ctx: napi_ohos::CallContext,
        ) -> napi_ohos::Result<openharmony_ability::ApplicationLifecycle> {
            let lifecycle = APP.with(|app| {
                let app_ref = app.borrow();
                #fn_name(&*app_ref);
        
                let lifecycle_handle = openharmony_ability::create_lifecycle_handle(ctx, app.clone())?;
                Ok(lifecycle_handle)
            });
            lifecycle
        }
        
        #[napi_derive_ohos::js_function(2)]
        pub fn render(ctx: napi_ohos::CallContext) -> napi_ohos::Result<openharmony_ability::Render> {
            let app_ref: std::cell::RefCell<App> = APP.with(|app| app.clone());
            let (root, ret) = openharmony_ability::render(ctx, app_ref.clone())?;
            ROOT_NODE.replace(Some(root));
            Ok(ret)
        }
        
        #[napi_derive_ohos::module_exports]
        fn module_export_init(
            mut exports: napi_ohos::JsObject,
            _env: napi_ohos::Env,
        ) -> napi_ohos::Result<()> {
            exports.create_named_method("init", init)?;
            exports.create_named_method("render", render)?;
            Ok(())
        }
    };

    f.into()
}
