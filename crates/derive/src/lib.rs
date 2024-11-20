use proc_macro::TokenStream;
use syn::ItemFn;

#[proc_macro_attribute]
pub fn activity(_attr: TokenStream, item: TokenStream) -> TokenStream {
    let ast = syn::parse_macro_input!(item as ItemFn);
    let fn_name = &ast.sig.ident;
    let block = &ast.block;

    let f = quote::quote! {
        fn #fn_name(app: &openharmony_activity::App) #block

        #[napi_derive_ohos::js_function]
        pub fn init(ctx: napi_ohos::CallContext) -> napi_ohos::Result<openharmony_activity::ApplicationLifecycle> {
            let inner_app = std::rc::Rc::new(std::cell::RefCell::new(App::new()));
            let inner_app_ref = inner_app.borrow();

            #fn_name(&inner_app_ref);

            openharmony_activity::create_lifecycle_handle(ctx, inner_app.clone())
        }

        #[napi_derive_ohos::module_exports]
        fn module_export_init(mut exports: napi_ohos::JsObject, _env: napi_ohos::Env) -> napi_ohos::Result<()> {
            exports.create_named_method("init", init)?;
            Ok(())
        }
    };

    f.into()
}
