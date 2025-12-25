#!/usr/bin/env bash

ROOT="$(dirname "$(realpath "$0")")"

git apply "$ROOT/add-a-fake-dependency-on-github.com-chai2010-protorpc.patch"
