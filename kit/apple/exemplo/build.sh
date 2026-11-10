#!/usr/bin/env bash
# Builds the embed sample app (docs/kit.md) against BrowserKit, without Xcode, and runs its
# self-check, which opens no window and starts no engine.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
kit=../BrowserKit/Sources/BrowserKit
swiftc -O -swift-version 6 -parse-as-library -module-name BrowserKit -emit-module -emit-module-path build/BrowserKit.swiftmodule \
  -emit-library -static -o build/libBrowserKit.a "$kit"/*.swift
swiftc -O -swift-version 6 -I build -L build -lBrowserKit main.swift -o build/exemplo
swiftc -O janelas.swift -o build/janelas
build/exemplo --selftest
echo "ok: $PWD/build/exemplo"
