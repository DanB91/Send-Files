#!/bin/bash
set -e

BUILD_DIR=build
NAME=sendfiles

compile() {
    odin build . -debug -out:$BUILD_DIR/$NAME
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