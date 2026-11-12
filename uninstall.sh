#!/bin/zsh
# Quits the apps and moves them to the Trash. Their Login Items entries disappear with them.
set -u
for pair in 'Claude Usage:ClaudeUsage' 'Codex Usage:CodexUsage' 'Cursor Usage:CursorUsage' 'Antigravity Usage:AntigravityUsage'; do
  name=${pair%%:*}; exe=${pair##*:}
  pkill -x "$exe" 2>/dev/null
  app="$HOME/Applications/$name.app"
  [[ -e $app ]] && mv "$app" "$HOME/.Trash/" && print "Moved $name to Trash"
done
