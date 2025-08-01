#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

rm -rf $SCRIPT_DIR/../package/src/main/ets
rm -rf $SCRIPT_DIR/../dist

cp -rf $SCRIPT_DIR/../rust_ability/ability_rust/src/main/ets/ $SCRIPT_DIR/../package/src/main/ets

pushd $SCRIPT_DIR/../ && ohrs artifact