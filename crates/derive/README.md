# activity-macro

## Introduce

activity-macro is  a macro crate for the openharmony-activity project. It provides a set of macros for generating code related to activities in the openharmony-activity project.

## Example

```rust
#[main]
pub fn main() {
    let activity = Activity::new();
    activity.run();
}
```