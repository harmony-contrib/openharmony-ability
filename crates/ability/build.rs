fn main() {
    // Desktop and mobile are OHOS device classes selected by the application build.
    println!("cargo:rustc-check-cfg=cfg(desktop)");
    println!("cargo:rustc-check-cfg=cfg(mobile)");

    println!("cargo:rerun-if-env-changed=OHOS_DEVICE_TYPE");
    let device_type = std::env::var("OHOS_DEVICE_TYPE").unwrap_or_else(|_| "mobile".to_string());
    if device_type == "desktop" {
        println!("cargo:rustc-cfg=desktop");
    } else {
        println!("cargo:rustc-cfg=mobile");
    }
}
