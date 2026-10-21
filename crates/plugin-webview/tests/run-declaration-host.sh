#!/usr/bin/env bash
set -euo pipefail
test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ohos-webview-declarations.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
python3 - "$test_dir" "$test_tmp" <<'PY'
from pathlib import Path
import re, sys
source = Path(sys.argv[1]).parent / 'src'
output = Path(sys.argv[2])
text = (source / 'lib.rs').read_text()
names = ['WebviewCallbackOptions', 'WebviewDownloadEndEvent', 'WebviewDownloadStartRequest',
         'WebviewDownloadStartResponse', 'WebviewDragEvent', 'WebviewDropEvent',
         'WebviewHttpsInterceptRequest', 'WebviewHttpsInterceptResponse', 'WebviewNavigationRequest',
         'WebviewNavigationResponse', 'WebviewNewWindowRequest', 'WebviewNewWindowResponse',
         'WebviewPageEvent', 'WebviewTitleChangeEvent', 'NativeWebviewControllerEvent', 'WebviewEventAcknowledgement']
def block(start):
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]
types = []
for name in names:
    derives = '#[derive(Clone, Debug' + (', Default' if name == 'WebviewCallbackOptions' else '') + ')]\n'
    types.append(derives + block(text.index('pub struct ' + name + ' {')))
for name in ['WebviewDownloadStartResponse', 'WebviewHttpsInterceptResponse']:
    types.append(block(text.index('impl ' + name + ' {')))
types.append('#[derive(Default)]\n' + block(text.index('pub struct WebviewBridgePlugin {')))
types.append('impl WebviewBridgePlugin {\n' + '\n'.join(block(text.index('fn ' + method + '(')) for method in ['native_key', 'dispatch_native_controller', 'clear_controller_state']) + '\n}')
types.extend(block(text.index('fn ' + method + '(')) for method in ['attach_controller', 'retire_controller'])
types.append(block(text.index('impl Drop for WebviewBridgePlugin {')))
text = (source / 'native.rs').read_text()
types.append('#[derive(Clone, Debug)]\n' + block(text.index('pub struct NativeWebviewEvent {')))
(output / 'types.rs').write_text('\n'.join(types))
(output / 'main.rs').write_text((Path(sys.argv[1]) / 'host/declarations.rs').read_text().replace('SOURCE_DIRECTORY', str(source)))
(output / 'Cargo.toml').write_text('[package]\nname="webview-declaration-host"\nversion="0.0.0"\nedition="2021"\n[workspace]\n[dependencies]\nlog="0.4"\nhttp="1"\n[[test]]\nname="declarations"\npath="main.rs"\n')
PY
CARGO_TARGET_DIR="${WEBVIEW_HOST_TARGET:-$test_tmp/target}" cargo test --offline --manifest-path "$test_tmp/Cargo.toml" --test declarations -- "$@"
