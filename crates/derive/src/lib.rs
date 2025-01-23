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

        pub static APP: std::sync::LazyLock<openharmony_ability::OpenHarmonyApp> =
            std::sync::LazyLock::new(|| openharmony_ability::OpenHarmonyApp::new());

        thread_local! {
            pub static ROOT_NODE: std::cell::RefCell<Option<openharmony_ability::arkui::RootNode>> = std::cell::RefCell::new(None);
        }

        #[openharmony_ability::napi_derive::js_function(1)]
        pub fn init(
            ctx: openharmony_ability::napi::CallContext,
        ) -> openharmony_ability::napi::Result<openharmony_ability::ApplicationLifecycle> {
            #fn_name((*APP).clone());
            let lifecycle_handle = openharmony_ability::create_lifecycle_handle(ctx, (*APP).clone())?;
            Ok(lifecycle_handle)
        }

        #[openharmony_ability::napi_derive::js_function(2)]
        pub fn render(
            ctx: openharmony_ability::napi::CallContext,
        ) -> openharmony_ability::napi::Result<openharmony_ability::Render> {
            let (root, ret) = openharmony_ability::render(ctx, (*APP).clone())?;
            ROOT_NODE.replace(Some(root));
            Ok(ret)
        }

        #[openharmony_ability::napi_derive::js_function(2)]
        pub fn show_keyboard(
            ctx: openharmony_ability::napi::CallContext,
        ) -> openharmony_ability::napi::Result<()> {
            let app = &*APP;
            app.show_keyboard();
            Ok(())
        }

        #[openharmony_ability::napi_derive::module_exports]
        fn module_export_init(
            mut exports: openharmony_ability::napi::JsObject,
            _env: openharmony_ability::napi::Env,
        ) -> openharmony_ability::napi::Result<()> {
            exports.create_named_method("init", init)?;
            exports.create_named_method("render", render)?;
            exports.create_named_method("show_keyboard", show_keyboard)?;
            Ok(())
        }
    };

    f.into()
}
