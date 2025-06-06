import { DefaultWebViewComponent } from "./DefaultWebview";

export const RouteName = 'RustWebViewAbility';

@Entry({ routeName: RouteName })
@Component
struct Index {
  build() {
    Row() {
      Column() {
        DefaultWebViewComponent()
      }.width("100%")
    }.height("100%")
  }
}

