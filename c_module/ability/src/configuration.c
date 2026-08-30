/*
 * Parses the ArkTS onConfigurationUpdated payload (10 fields) into OHAbility_Configuration,
 * mirroring the Rust configuration module. Missing properties fall back to defaults.
 * String fields of the result are malloc'd; free them with oh_configuration_free().
 */
#include "oh_state.h"

#include <stdlib.h>

int oh_configuration_from_object(napi_env env, napi_value object, OHAbility_Configuration *out) {
    napi_value value;

    out->language = NULL;
    out->mcc = NULL;
    out->mnc = NULL;
    out->color_mode = OH_ABILITY_COLOR_MODE_NO_SET;
    out->direction = OH_ABILITY_DIRECTION_NO_SET;
    out->screen_density = OH_ABILITY_SCREEN_DENSITY_NO_SET;
    out->display_id = 0;
    out->has_pointer_device = false;
    out->font_size_scale = 1.0;
    out->font_weight_scale = 1.0;

    if (object == NULL) {
        out->language = oh_strdup("");
        out->mcc = oh_strdup("");
        out->mnc = oh_strdup("");
        return OH_ABILITY_ERROR_OK;
    }

    if (napi_get_named_property(env, object, "language", &value) == napi_ok) {
        out->language = oh_napi_get_string(env, value);
    } else {
        out->language = oh_strdup("");
    }
    if (napi_get_named_property(env, object, "mcc", &value) == napi_ok) {
        out->mcc = oh_napi_get_string(env, value);
    } else {
        out->mcc = oh_strdup("");
    }
    if (napi_get_named_property(env, object, "mnc", &value) == napi_ok) {
        out->mnc = oh_napi_get_string(env, value);
    } else {
        out->mnc = oh_strdup("");
    }

    /* colorMode / direction / screenDensity keep the raw platform values; the enum tags in
     * oh_ability_events.h are bit-identical to the Rust crate's mapping. */
    if (napi_get_named_property(env, object, "colorMode", &value) == napi_ok) {
        int32_t raw = -1;
        if (napi_get_value_int32(env, value, &raw) == napi_ok) {
            out->color_mode = (OHAbility_ColorMode)raw;
        }
    }
    if (napi_get_named_property(env, object, "direction", &value) == napi_ok) {
        int32_t raw = -1;
        if (napi_get_value_int32(env, value, &raw) == napi_ok) {
            out->direction = (OHAbility_Direction)raw;
        }
    }
    if (napi_get_named_property(env, object, "screenDensity", &value) == napi_ok) {
        int32_t raw = 0;
        if (napi_get_value_int32(env, value, &raw) == napi_ok) {
            out->screen_density = (OHAbility_ScreenDensity)raw;
        }
    }
    if (napi_get_named_property(env, object, "displayId", &value) == napi_ok) {
        napi_get_value_int32(env, value, &out->display_id);
    }
    if (napi_get_named_property(env, object, "hasPointerDevice", &value) == napi_ok) {
        bool has_pointer = false;
        if (napi_get_value_bool(env, value, &has_pointer) == napi_ok) {
            out->has_pointer_device = has_pointer;
        }
    }
    if (napi_get_named_property(env, object, "fontSizeScale", &value) == napi_ok) {
        double scale = 1.0;
        if (napi_get_value_double(env, value, &scale) == napi_ok) {
            out->font_size_scale = scale;
        }
    }
    if (napi_get_named_property(env, object, "fontWeightScale", &value) == napi_ok) {
        double scale = 1.0;
        if (napi_get_value_double(env, value, &scale) == napi_ok) {
            out->font_weight_scale = scale;
        }
    }

    return OH_ABILITY_ERROR_OK;
}

void oh_configuration_free(OHAbility_Configuration *config) {
    if (config == NULL) {
        return;
    }
    free((char *)config->language);
    free((char *)config->mcc);
    free((char *)config->mnc);
    config->language = NULL;
    config->mcc = NULL;
    config->mnc = NULL;
}

/* Replaces the framework snapshot with a deep copy of `fresh` (string fields duplicated; the
 * snapshot keeps ownership and the old strings are released). */
void oh_configuration_replace(OHAbility_Configuration *snapshot,
                              const OHAbility_Configuration *fresh) {
    char *language = oh_strdup(fresh->language);
    char *mcc = oh_strdup(fresh->mcc);
    char *mnc = oh_strdup(fresh->mnc);
    free((char *)snapshot->language);
    free((char *)snapshot->mcc);
    free((char *)snapshot->mnc);
    *snapshot = *fresh;
    snapshot->language = language;
    snapshot->mcc = mcc;
    snapshot->mnc = mnc;
}
