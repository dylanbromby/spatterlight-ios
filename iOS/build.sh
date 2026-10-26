#!/bin/sh
# Usage: build.sh <scheme> [extra xcodebuild args]
# Builds for the iOS simulator, printing only diagnostics.
cd "$(dirname "$0")"
scheme="$1"; shift
xcodebuild -project SpatterlightiOS.xcodeproj -scheme "$scheme" -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO "$@" build 2>&1 \
  | grep -E "error:|\*\* BUILD|Undefined symbols|ld: |clang: error" | sort -u | head -60
