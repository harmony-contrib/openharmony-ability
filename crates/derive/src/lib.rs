use proc_macro::TokenStream;
use syn::ItemFn;

#[proc_macro_attribute]
pub fn ability(_attr: TokenStream, item: TokenStream) -> TokenStream {
    let ast = syn::parse_macro_input!(item as ItemFn);
    let fn_name = &ast.sig.ident;
    let block = &ast.block;
    let arg = &ast.sig.inputs;

    let f = quote::quote! {
        fn #fn_name(#arg) #block

        thread_local! {
            pub static APP: std::cell::RefCell<openharmony_ability::OpenHarmonyApp> = std::cell::RefCell::new(openharmony_ability::OpenHarmonyApp::new());
            pub static ROOT_NODE: std::cell::RefCell<Option<openharmony_ability::arkui::RootNode>> = std::cell::RefCell::new(None);
        }

        #[openharmony_ability::napi_derive::js_function(1)]
        pub fn init(
            ctx: openharmony_ability::napi::CallContext,
        ) -> openharmony_ability::napi::Result<openharmony_ability::ApplicationLifecycle> {
            let lifecycle = APP.with(|app| {
                let app_ref = app.borrow();
                #fn_name((&*app_ref).clone());

                let lifecycle_handle = openharmony_ability::create_lifecycle_handle(ctx, app.clone())?;
                Ok(lifecycle_handle)
            });
            lifecycle
        }

        #[openharmony_ability::napi_derive::js_function(2)]
        pub fn render(ctx: openharmony_ability::napi::CallContext) -> openharmony_ability::napi::Result<openharmony_ability::Render> {
            let app_ref: std::cell::RefCell<openharmony_ability::OpenHarmonyApp> = APP.with(|app| app.clone());
            let (root, ret) = openharmony_ability::render(ctx, app_ref.clone())?;
            ROOT_NODE.replace(Some(root));
            Ok(ret)
        }

        #[openharmony_ability::napi_derive::module_exports]
        fn module_export_init(
            mut exports: openharmony_ability::napi::JsObject,
            _env: openharmony_ability::napi::Env,
        ) -> openharmony_ability::napi::Result<()> {
            exports.create_named_method("init", init)?;
            exports.create_named_method("render", render)?;
            Ok(())
        }
    };

    f.into()
}
