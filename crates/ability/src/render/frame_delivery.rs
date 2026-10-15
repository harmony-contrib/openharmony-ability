use crate::FrameInputDelivery;

/// Requested delivery survives surface recreation; applied delivery does not.
#[derive(Clone, Copy, Default)]
pub(crate) struct FrameDeliveryState {
    pub(crate) requested: FrameInputDelivery,
    applied: Option<FrameInputDelivery>,
}

impl FrameDeliveryState {
    pub(crate) fn is_applied(&self, delivery: FrameInputDelivery) -> bool {
        self.requested == delivery && self.applied == Some(delivery)
    }

    pub(crate) fn request(&mut self, delivery: FrameInputDelivery) -> bool {
        self.requested = delivery;
        self.applied != Some(delivery)
    }

    pub(crate) fn applied(&mut self, delivery: FrameInputDelivery) {
        self.applied = Some(delivery);
    }

    pub(crate) fn invalidate(&mut self) {
        self.applied = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failed_registration_is_retried_and_recreation_invalidates_success() {
        let mut state = FrameDeliveryState::default();
        assert!(state.request(FrameInputDelivery::Continuous));
        // No success is recorded when the native call fails.
        assert!(state.request(FrameInputDelivery::Continuous));
        state.applied(FrameInputDelivery::Continuous);
        assert!(state.is_applied(FrameInputDelivery::Continuous));
        assert!(!state.request(FrameInputDelivery::Continuous));
        state.invalidate();
        assert!(state.request(FrameInputDelivery::Continuous));
        state.applied(FrameInputDelivery::Continuous);
        assert!(state.request(FrameInputDelivery::OnDemand));
        assert!(state.request(FrameInputDelivery::OnDemand));
        state.applied(FrameInputDelivery::OnDemand);
        assert!(!state.request(FrameInputDelivery::OnDemand));
    }
}
