#!/usr/bin/env bash

ROOT="$(dirname "$(realpath "$0")")"

git apply "$ROOT/use-the-version-0.2.0-of-webdav-handler.patch"
