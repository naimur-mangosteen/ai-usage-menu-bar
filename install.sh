#!/bin/zsh
# Builds, installs to ~/Applications, starts, and enables Open at Login.
# Usage: ./install.sh [claude] [codex] [cursor] [antigravity]   (default: claude codex)
set -eu
cd -- "${0:A:h}"
targets=("$@"); (( $# )) || targets=(claude codex)
./build.sh $targets
dest="$HOME/Applications"; mkdir -p "$dest"
for t in $targets; do
  case $t in
    claude) name='Claude Usage'; exe=ClaudeUsage ;;
    codex)  name='Codex Usage';  exe=CodexUsage ;;
    cursor) name='Cursor Usage'; exe=CursorUsage ;;
    antigravity) name='Antigravity Usage'; exe=AntigravityUsage ;;
  esac
  pkill -x "$exe" 2>/dev/null && sleep 1 || true
  rm -rf "$dest/$name.app"
  cp -R "build/$name.app" "$dest/"
  "$dest/$name.app/Contents/MacOS/$exe" --enable-login || print -u2 "Could not enable Open at Login for $name; add it in System Settings → General → Login Items."
  open "$dest/$name.app"
  print "Installed and started $dest/$name.app"
done
