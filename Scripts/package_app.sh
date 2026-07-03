#!/usr/bin/env bash
# Build a release ccemaphore.app via Xcode and drop it in build/ for local use.
# Distribution (Developer ID signing + notarization + DMG) is done in CI — see README.
set -euo pipefail
cd "$(dirname "$0")/.."

DD="$(mktemp -d)"
trap 'rm -rf "$DD"' EXIT

xcodebuild -project ccemaphore.xcodeproj -scheme ccemaphore -configuration Release \
  -derivedDataPath "$DD" build CODE_SIGNING_ALLOWED=NO >/dev/null

rm -rf build/ccemaphore.app
mkdir -p build
cp -R "$DD/Build/Products/Release/ccemaphore.app" build/ccemaphore.app

echo "Built build/ccemaphore.app"
echo "Sign for local run:  codesign --force --options runtime --sign - build/ccemaphore.app"
echo "Run:                 open build/ccemaphore.app"
