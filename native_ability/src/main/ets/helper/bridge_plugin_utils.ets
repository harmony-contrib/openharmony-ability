import { BridgeTypedValue } from '../ability/type';

/**
 * Shared request-type validation for bridge plugins (issue #87 minor-6).
 *
 * Every plugin used to carry its own copy of this function (with drifting
 * signatures: some returned the unwrapped value, some returned void) plus its
 * own `{ accepted: boolean }` acknowledgement class and `DOMAIN` constant.
 * Those now live here / in constants.ets and are re-exported through the
 * `@ohos-rs/ability` barrel.
 *
 * Wire contract note: each plugin's ACKNOWLEDGEMENT_TYPE string stays
 * plugin-local — it is pinned on the Rust side by `impl_bridge_napi_type!`
 * and must NOT be unified. Only the ArkTS-side class shape is shared.
 */

/** Shape shared by every Rust-side acknowledgement (`{ accepted: bool }`). */
export class BridgeAcknowledgement {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

/**
 * Validates that a bridge payload carries the expected named NAPI type and
 * returns the unwrapped value. Throws with the
 * `<pluginId>.<action> requires bridge type <typeName>` message that every
 * plugin's former local copy produced (byte-identical when the same pluginId
 * is passed).
 */
export function expectBridgeRequestType(
  payload: BridgeTypedValue,
  pluginId: string,
  action: string,
  typeName: string,
): ESObject {
  if (payload.typeName !== typeName || payload.value === null || typeof payload.value !== "object") {
    throw new Error(`${pluginId}.${action} requires bridge type ${typeName}`);
  }
  return payload.value as ESObject;
}
