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

        static APP: std::sync::LazyLock<openharmony_ability::OpenHarmonyApp> =
        std::sync::LazyLock::new(|| openharmony_ability::OpenHarmonyApp::new());
    
        thread_local! {
            pub static ROOT_NODE: std::cell::RefCell<Option<openharmony_ability::arkui::RootNode>> = std::cell::RefCell::new(None);
        }
        
        #[openharmony_ability::napi_derive::napi]
        pub fn init<'a>(
            env: &'a openharmony_ability::napi::Env,
            helper: openharmony_ability::ArkTSHelper,
        ) -> openharmony_ability::napi::Result<openharmony_ability::ApplicationLifecycle<'a>> {
            let lifecycle_handle =
                openharmony_ability::create_lifecycle_handle(env, helper, (*APP).clone())?;
            #fn_name((*APP).clone());
            Ok(lifecycle_handle)
        }
        
        #[openharmony_ability::napi_derive::napi]
        pub fn render<'a>(
            env: &'a openharmony_ability::napi::Env,
            slot: openharmony_ability::arkui::ArkUIHandle,
            callback: openharmony_ability::napi::bindgen_prelude::Function<'a, (), ()>,
        ) -> openharmony_ability::napi::Result<openharmony_ability::Render<'a>> {
            let (root, ret) = openharmony_ability::render(env, slot, callback, (*APP).clone())?;
            ROOT_NODE.replace(Some(root));
            Ok(ret)
        }
    };

    f.into()
}
