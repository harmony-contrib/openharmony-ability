// Copyright 2019-2024 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

//! OHOS global shortcut types.
//!
//! The bridge plugin facade (`openharmony-ability-plugin-global-shortcut`)
//! now handles register/unregister/event operations through the bridge
//! plugin model. This module retains only the type definitions and the
//! NAPI event callback for backward compatibility.

pub mod event;
pub mod types;

// Re-export public types
pub use self::types::{
    Key as ShortcutKey, Modifier as ShortcutModifier, ShortcutEvent, ShortcutState,
};
