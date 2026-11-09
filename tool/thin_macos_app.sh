#!/usr/bin/env bash
# Usage: tool/thin_macos_app.sh <universal.app> <arch: arm64|x86_64> <out.app> <entitlements>
# Strips a universal .app down to one architecture, then re-signs ad-hoc.
set -euo pipefail

src="$1"
arch="$2"
out="$3"
entitlements="$4"

rm -rf "$out"
ditto "$src" "$out"

while IFS= read -r -d '' file; do
  archs=$(lipo -archs "$file" 2>/dev/null || true)
  if [[ "$archs" == *" "* && "$archs" == *"$arch"* ]]; then
    lipo -thin "$arch" "$file" -output "$file.thin"
    mv "$file.thin" "$file"
  fi
done < <(find "$out" -type f -print0)

# lipo invalidates signatures; Apple Silicon refuses to run unsigned arm64 code.
# Sign nested code inside-out, then the app itself with its sandbox entitlements.
find "$out/Contents/Frameworks" -depth \( -name "*.framework" -o -name "*.dylib" \) \
  -exec codesign --force --sign - {} \;
codesign --force --sign - --entitlements "$entitlements" "$out"
codesign --verify --deep --strict "$out"
