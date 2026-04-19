#!/bin/bash
set -e

BUILD_DIR=build
NAME=sendfiles

export ODIN_CLANG_PATH=/opt/homebrew/Cellar/llvm/22.1.3/bin/clang
compile() {
    odin build . -o:none -debug -sanitize:address -out:$BUILD_DIR/$NAME
    # odin build . -o:none -debug  -out:$BUILD_DIR/$NAME
    # odin build . -o:speed -out:$BUILD_DIR/$NAME
}

if [[ ! -d $BUILD_DIR ]]; then
    mkdir $BUILD_DIR
fi


case "$1" in
"run")
    compile
    $BUILD_DIR/$NAME
    ;;
"clean")
    rm -rf $BUILD_DIR
    ;;
"")
    compile
    ;;
esac