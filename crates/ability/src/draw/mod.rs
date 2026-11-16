//! Frame timing payload for redraw ticks.

#[derive(Clone)]
/// Frame callback timing info from the XComponent frame listener.
pub struct IntervalInfo {
    /// Timestamp of the current frame (ns, from `OH_NativeXComponent` callback).
    pub time_stamp: i64,
    /// Target presentation timestamp of the frame (ns).
    pub target_time_stamp: i64,
}
