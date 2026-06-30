use napi_ohos::{Error, Result};

use super::types::{StatusBarItem, StatusBarMenuItem};

pub fn validate_status_bar_item(item: &StatusBarItem) -> Result<()> {
    if item.quick_operation.height == 0 {
        return Err(Error::from_reason("height must > 0"));
    }

    if let Some(menus) = &item.status_bar_group_menu {
        let total_items: usize = menus.iter().map(|g| g.len()).sum();
        if total_items > 20 {
            return Err(Error::from_reason("menu items limit exceeded (max 20)"));
        }

        for group in menus {
            for item in group {
                if let Some(sub) = &item.sub_menu {
                    if sub.len() > 20 {
                        return Err(Error::from_reason("sub menu items limit exceeded (max 20)"));
                    }
                }
                if item.menu_action.is_none() && item.sub_menu.is_none() {
                    return Err(Error::from_reason(
                        "menuAction and subMenu cannot both be none",
                    ));
                }
            }
        }
    }

    if let Some(tips) = &item.hover_tips {
        if tips.is_empty() || tips.len() > 128 {
            return Err(Error::from_reason("hoverTips length must be 1~128"));
        }
    }

    Ok(())
}

pub fn validate_menus(menus: &Vec<Vec<StatusBarMenuItem>>) -> Result<()> {
    let total_items: usize = menus.iter().map(|g| g.len()).sum();
    if total_items > 20 {
        return Err(Error::from_reason("menu items limit exceeded (max 20)"));
    }

    for group in menus {
        for item in group {
            if let Some(sub) = &item.sub_menu {
                if sub.len() > 20 {
                    return Err(Error::from_reason("sub menu items limit exceeded (max 20)"));
                }
            }
            if item.menu_action.is_none() && item.sub_menu.is_none() {
                return Err(Error::from_reason(
                    "menuAction and subMenu cannot both be none",
                ));
            }
        }
    }

    Ok(())
}

pub fn validate_hover_tips(tips: &str) -> Result<()> {
    if tips.is_empty() || tips.len() > 128 {
        return Err(Error::from_reason("tips length must be 1~128"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::types::{
        StatusBarItem, StatusBarMenuAction, StatusBarMenuItem, StatusBarSubMenuItem,
    };
    use super::*;

    #[test]
    fn height_must_be_positive() {
        let item = StatusBarItem {
            quick_operation: super::super::types::QuickOperation {
                height: 0,
                ..Default::default()
            },
            ..Default::default()
        };
        assert!(validate_status_bar_item(&item).is_err());

        let valid_item = StatusBarItem {
            quick_operation: super::super::types::QuickOperation {
                height: 1,
                ..Default::default()
            },
            ..Default::default()
        };
        assert!(validate_status_bar_item(&valid_item).is_ok());
    }

    #[test]
    fn menu_items_limit_20() {
        let over_limit: Vec<Vec<StatusBarMenuItem>> =
            vec![(0..21).map(|_| StatusBarMenuItem { menu_action: Some(StatusBarMenuAction::default()), ..Default::default() }).collect()];
        assert!(validate_menus(&over_limit).is_err());

        let at_limit: Vec<Vec<StatusBarMenuItem>> =
            vec![(0..20).map(|_| StatusBarMenuItem { menu_action: Some(StatusBarMenuAction::default()), ..Default::default() }).collect()];
        assert!(validate_menus(&at_limit).is_ok());
    }

    #[test]
    fn submenu_limit_20() {
        let item = StatusBarMenuItem {
            sub_menu: Some((0..21).map(|_| StatusBarSubMenuItem::default()).collect()),
            menu_action: None,
            ..Default::default()
        };
        let menus = vec![vec![item]];
        assert!(validate_menus(&menus).is_err());

        let valid_item = StatusBarMenuItem {
            sub_menu: Some((0..20).map(|_| StatusBarSubMenuItem::default()).collect()),
            menu_action: None,
            ..Default::default()
        };
        let valid_menus = vec![vec![valid_item]];
        assert!(validate_menus(&valid_menus).is_ok());
    }

    #[test]
    fn menu_action_and_submenu_cannot_both_be_none() {
        let item = StatusBarMenuItem {
            sub_menu: None,
            menu_action: None,
            ..Default::default()
        };
        let menus = vec![vec![item]];
        assert!(validate_menus(&menus).is_err());

        let with_action = StatusBarMenuItem {
            sub_menu: None,
            menu_action: Some(StatusBarMenuAction::default()),
            ..Default::default()
        };
        let valid_menus = vec![vec![with_action]];
        assert!(validate_menus(&valid_menus).is_ok());
    }

    #[test]
    fn hover_tips_length_1_to_128() {
        assert!(validate_hover_tips("").is_err());
        assert!(validate_hover_tips(&"x".repeat(129)).is_err());
        assert!(validate_hover_tips(&"x".repeat(128)).is_ok());
        assert!(validate_hover_tips("x").is_ok());
        assert!(validate_hover_tips("normal tips").is_ok());
    }
}
