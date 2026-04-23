#!/bin/bash
set -e

BUILD_DIR=build
NAME=sendfiles
SERVER_NAME=discovery_server

IS_MAC_OS=false
if [[ `uname` == 'Darwin' ]]; then
    IS_MAC_OS=true
fi
if $IS_MAC_OS; then
    export ODIN_CLANG_PATH=/opt/homebrew/Cellar/llvm/22.1.3/bin/clang
fi
compile() {
    if $IS_MAC_OS; then
        odin build . -o:none -debug -sanitize:address -out:$BUILD_DIR/$NAME
        # odin build . -o:none -debug  -out:$BUILD_DIR/$NAME
        # odin build . -o:speed -out:$BUILD_DIR/$NAME
        codesign -s - --entitlements entitlements.plist --force $BUILD_DIR/$NAME
    fi
}
compile_server() {
    odin build ./$SERVER_NAME -o:none -debug -sanitize:address -out:$BUILD_DIR/$SERVER_NAME
    # odin build . -o:none -debug  -out:$BUILD_DIR/$NAME
    # odin build . -o:speed -out:$BUILD_DIR/$NAME
    if $IS_MAC_OS; then
        codesign -s - --entitlements entitlements.plist --force $BUILD_DIR/$SERVER_NAME
    fi
}

if [[ ! -d $BUILD_DIR ]]; then
    mkdir $BUILD_DIR
fi


case "$1" in
"run")
    compile
    $BUILD_DIR/$NAME
    ;;
"run_server")
    compile_server
    shift
    $BUILD_DIR/$SERVER_NAME "$@"
    ;;
"clean")
    rm -rf $BUILD_DIR
    ;;
"")
    compile
    compile_server
    ;;
esac