//! Compile the production ownership/dispatch code without linking OHOS libraries.
extern crate self as log;

#[macro_export]
macro_rules! error {
    ($($args:tt)*) => { eprintln!($($args)*) };
}

#[path = "../src/motion_routes.rs"]
mod motion_routes;
