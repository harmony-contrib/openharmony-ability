use std::{
    cell::Cell,
    fmt,
    sync::atomic::{AtomicU32, Ordering},
};

pub(crate) fn allocate_id(counter: &AtomicU32) -> Option<u32> {
    let mut id = counter.load(Ordering::Relaxed);
    loop {
        let next = id.checked_add(1)?;
        match counter.compare_exchange_weak(id, next, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return Some(id),
            Err(current) => id = current,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum AdmissionError {
    Retired,
    Busy,
}

impl fmt::Display for AdmissionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Retired => "is retired",
            Self::Busy => "already has an operation in progress",
        })
    }
}

#[derive(Default)]
pub(crate) struct AttachmentState {
    retired: Cell<bool>,
    active: Cell<bool>,
}

impl AttachmentState {
    pub(crate) fn is_retired(&self) -> bool {
        self.retired.get()
    }

    pub(crate) fn begin(&self) -> Result<Active<'_>, AdmissionError> {
        if self.retired.get() {
            return Err(AdmissionError::Retired);
        }
        self.enter()
    }

    pub(crate) fn begin_retire(&self) -> Result<Active<'_>, AdmissionError> {
        let active = self.enter()?;
        self.retired.set(true);
        Ok(active)
    }

    fn enter(&self) -> Result<Active<'_>, AdmissionError> {
        if self.active.replace(true) {
            Err(AdmissionError::Busy)
        } else {
            Ok(Active(&self.active))
        }
    }
}

#[must_use]
pub(crate) struct Active<'a>(&'a Cell<bool>);

impl Drop for Active<'_> {
    fn drop(&mut self) {
        self.0.set(false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_monotonic_and_never_wrap() {
        let counter = AtomicU32::new(1);
        assert_eq!(allocate_id(&counter), Some(1));
        assert_eq!(allocate_id(&counter), Some(2));
        counter.store(u32::MAX - 1, Ordering::Relaxed);
        assert_eq!(allocate_id(&counter), Some(u32::MAX - 1));
        assert_eq!(allocate_id(&counter), None);
        assert_eq!(allocate_id(&counter), None);
        assert_eq!(counter.load(Ordering::Relaxed), u32::MAX);
    }

    #[test]
    fn callback_holds_the_guard_through_reentrant_retirement() {
        let state = AttachmentState::default();
        {
            let _callback = state.begin().unwrap();
            assert!(matches!(state.begin(), Err(AdmissionError::Busy)));
            assert!(matches!(state.begin_retire(), Err(AdmissionError::Busy)));
        }
        assert!(state.begin().is_ok());
    }

    #[test]
    fn retirement_permanently_rejects_callbacks_but_allows_detachment_retry() {
        let state = AttachmentState::default();
        {
            let _retirement = state.begin_retire().unwrap();
            assert!(matches!(state.begin(), Err(AdmissionError::Retired)));
        }
        assert!(matches!(state.begin(), Err(AdmissionError::Retired)));
        let _retry = state.begin_retire().unwrap();
        assert!(matches!(state.begin(), Err(AdmissionError::Retired)));
    }

    #[test]
    fn unwinding_a_callback_releases_admission() {
        let state = AttachmentState::default();
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _callback = state.begin().unwrap();
            panic!("callback failed");
        }));
        assert!(state.begin().is_ok());
    }

    #[test]
    fn unwinding_retirement_never_reopens_callbacks() {
        let state = AttachmentState::default();
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _retirement = state.begin_retire().unwrap();
            panic!("detachment failed");
        }));
        assert!(matches!(state.begin(), Err(AdmissionError::Retired)));
        assert!(state.begin_retire().is_ok());
    }
}
