import webview from '@ohos.web.webview';

export const getCookies = (url: string) => {
  return webview.WebCookieManager.fetchCookieSync(url)
}