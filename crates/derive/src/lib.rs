use proc_macro::TokenStream;
use syn::ItemFn;

#[proc_macro_attribute]
pub fn activity(attr: TokenStream, item: TokenStream) -> TokenStream {
    let ast = syn::parse_macro_input!(item as ItemFn);
    let block = &ast.block;

    let f = quote::quote! {
        #block
    };

    f.into()
}
