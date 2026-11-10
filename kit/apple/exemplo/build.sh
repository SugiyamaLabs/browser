#!/usr/bin/env bash
# Builds the embed sample app (docs/poc/embed.md) and runs its self-check, which opens no window.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -swift-version 5 main.swift -o build/exemplo
swiftc -O janelas.swift -o build/janelas
build/exemplo --selftest
echo "ok: $PWD/build/exemplo"
