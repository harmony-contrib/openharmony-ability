/// Window stage event codes forwarded by the ArkTS bridge (`onWindowStageEvent`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StageEventType {
    /// Window stage is shown (OHOS `SHOWN`, value 1).
    Shown = 1,
    /// Window gained focus (OHOS `ACTIVE`, value 2).
    Active,
    /// Window lost focus (OHOS `INACTIVE`, value 3).
    Inactive,
    /// Window stage is hidden (OHOS `HIDDEN`, value 4).
    Hidden,
    /// Ability resumed to foreground (OHOS `RESUMED`, value 5).
    Resumed,
    /// Ability paused to background (OHOS `PAUSED`, value 6).
    Paused,
}

impl TryFrom<i32> for StageEventType {
    type Error = i32;

    fn try_from(value: i32) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(StageEventType::Shown),
            2 => Ok(StageEventType::Active),
            3 => Ok(StageEventType::Inactive),
            4 => Ok(StageEventType::Hidden),
            5 => Ok(StageEventType::Resumed),
            6 => Ok(StageEventType::Paused),
            v => Err(v),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::StageEventType;
    use std::convert::TryFrom;

    /// UT for #221: each known stage event code 1..=6 maps to its variant.
    /// # Brief: call `StageEventType::try_from` for every code in 1..=6 and
    /// assert the expected variant is produced.
    #[test]
    fn ut_stage_event_try_from_known_values() {
        let expected = [
            (1_i32, StageEventType::Shown),
            (2_i32, StageEventType::Active),
            (3_i32, StageEventType::Inactive),
            (4_i32, StageEventType::Hidden),
            (5_i32, StageEventType::Resumed),
            (6_i32, StageEventType::Paused),
        ];
        for (code, want) in expected {
            let got = StageEventType::try_from(code).unwrap();
            assert_eq!(got as i32, want as i32, "code {code} mapped wrongly");
        }
    }

    /// UT for #221: unknown stage event codes return `Err` carrying the same
    /// value instead of panicking.
    /// # Brief: call `try_from` for 0/7/-1/2147483647 and assert `Err(v)`.
    #[test]
    fn ut_stage_event_try_from_unknown_values() {
        for code in [0_i32, 7_i32, -1_i32, 2147483647_i32] {
            assert_eq!(StageEventType::try_from(code), Err(code));
        }
    }
}
