#!/bin/zsh
# Builds the menu-bar apps into ./build and runs their self-tests.
# Usage: ./build.sh [claude] [codex]      (default: both)
# Signing: ad-hoc by default. Set SIGN_IDENTITY to a codesigning identity (name or SHA-1) to use your own.
set -eu
cd -- "${0:A:h}"
targets=("$@"); (( $# )) || targets=(claude codex)
identity="${SIGN_IDENTITY:--}"
mkdir -p build .module-cache

plist() { # name exe bundle-id
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$3</string>
<key>CFBundleName</key><string>$1</string>
<key>CFBundleExecutable</key><string>$2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
}

build_app() { # dir name exe bundle-id helper
  local app="build/$2.app"
  rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  xcrun swiftc -swift-version 5 -O -module-cache-path "$PWD/.module-cache" \
    -framework AppKit -framework Security "$1/main.swift" -o "$app/Contents/MacOS/$3"
  plist "$2" "$3" "$4" > "$app/Contents/Info.plist"
  cp "$1/$5" "$app/Contents/Resources/"
  codesign --force --sign "$identity" "$app"
  codesign --verify --strict "$app"
  "$app/Contents/MacOS/$3" --self-test
  print "Built $PWD/$app"
}

for t in $targets; do
  case $t in
    claude) build_app claude-usage 'Claude Usage' ClaudeUsage local.claude.usage.companion renew_login.py ;;
    codex)  build_app codex-usage  'Codex Usage'  CodexUsage  local.codex.usage.companion  read_usage.py ;;
    *) print -u2 "Unknown target: $t (use claude and/or codex)"; exit 1 ;;
  esac
done
