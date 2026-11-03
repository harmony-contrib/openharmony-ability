// Host link stubs for the ArkWeb C API (ohweb.lib): plugin-webview and
// demo_native host binaries pull ArkWeb scheme-handler/resource symbols that
// no other stub archive covers.
// dlopen/dlsym and the XComponent callback registrations live in stubs.rs
// (ohinputmethod.lib is linked into every host binary, ohweb.lib is not) -
// do not duplicate them here or the linker reports LNK2005 when both
// archives are pulled into one link.
#[no_mangle]
extern "C" fn OH_ArkWeb_CreateResponse() {}
#[no_mangle]
extern "C" fn OH_ArkWeb_CreateSchemeHandler() {}
#[no_mangle]
extern "C" fn OH_ArkWeb_DestroySchemeHandler() {}
#[no_mangle]
extern "C" fn OH_ArkWeb_GetNativeAPI() {}
#[no_mangle]
extern "C" fn OH_ArkWeb_RegisterCustomSchemes() {}
#[no_mangle]
extern "C" fn OH_ArkWeb_ReleaseByteArray() {}
#[no_mangle]
extern "C" fn OH_ArkWeb_ReleaseString() {}
#[no_mangle]
extern "C" fn OH_ArkWebHttpBodyStream_GetSize() {}
#[no_mangle]
extern "C" fn OH_ArkWebHttpBodyStream_GetUserData() {}
#[no_mangle]
extern "C" fn OH_ArkWebHttpBodyStream_Init() {}
#[no_mangle]
extern "C" fn OH_ArkWebHttpBodyStream_IsChunked() {}
#[no_mangle]
extern "C" fn OH_ArkWebHttpBodyStream_IsEof() {}
#[no_mangle]
extern "C" fn OH_ArkWebHttpBodyStream_IsInMemory() {}
#[no_mangle]
extern "C" fn OH_ArkWebRequestHeaderList_Destroy() {}
#[no_mangle]
extern "C" fn OH_ArkWebRequestHeaderList_GetHeader() {}
#[no_mangle]
extern "C" fn OH_ArkWebRequestHeaderList_GetSize() {}
#[no_mangle]
extern "C" fn OH_ArkWebResourceHandler_DidFinish() {}
#[no_mangle]
extern "C" fn OH_ArkWebResourceHandler_DidReceiveResponse() {}
#[no_mangle]
extern "C" fn OH_ArkWebResourceRequest_GetFrameUrl() {}
#[no_mangle]
extern "C" fn OH_ArkWebResourceRequest_GetHttpBodyStream() {}
#[no_mangle]
extern "C" fn OH_ArkWebResourceRequest_GetMethod() {}
#[no_mangle]
extern "C" fn OH_ArkWebResourceRequest_GetReferrer() {}
#[no_mangle]
extern "C" fn OH_ArkWebResourceRequest_GetRequestHeaders() {}
#[no_mangle]
extern "C" fn OH_ArkWebResourceRequest_GetResourceType() {}
#[no_mangle]
extern "C" fn OH_ArkWebResourceRequest_GetUrl() {}
#[no_mangle]
extern "C" fn OH_ArkWebResourceRequest_HasGesture() {}
#[no_mangle]
extern "C" fn OH_ArkWebResourceRequest_IsMainFrame() {}
#[no_mangle]
extern "C" fn OH_ArkWebResourceRequest_IsRedirect() {}
#[no_mangle]
extern "C" fn OH_ArkWebResponse_GetCharset() {}
#[no_mangle]
extern "C" fn OH_ArkWebResponse_GetError() {}
#[no_mangle]
extern "C" fn OH_ArkWebResponse_GetMimeType() {}
#[no_mangle]
extern "C" fn OH_ArkWebResponse_GetStatus() {}
#[no_mangle]
extern "C" fn OH_ArkWebResponse_GetStatusText() {}
#[no_mangle]
extern "C" fn OH_ArkWebResponse_GetUrl() {}
#[no_mangle]
extern "C" fn OH_ArkWebResponse_SetError() {}
#[no_mangle]
extern "C" fn OH_ArkWebResponse_SetStatus() {}
#[no_mangle]
extern "C" fn OH_ArkWebSchemeHandler_GetUserData() {}
