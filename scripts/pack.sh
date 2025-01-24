#!/bin/bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

rm -rf $SCRIPT_DIR/../package/src/main/ets
rm -rf $SCRIPT_DIR/../dist

# Avoid the older version of the ohrs failed
mkdir $SCRIPT_DIR/../dist
touch $SCRIPT_DIR/../dist/hello.txt

cp -rf $SCRIPT_DIR/../example/ability_rust/src/main/ets/ $SCRIPT_DIR/../package/src/main/ets

pushd $SCRIPT_DIR/../ && ohrs artifact