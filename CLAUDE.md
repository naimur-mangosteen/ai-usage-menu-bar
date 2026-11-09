# Instructions for Claude Code

This repo contains two macOS menu-bar apps: `claude-usage/` shows Claude Code plan usage and `codex-usage/` shows Codex usage. Each is a single `main.swift` file plus one Python helper. There is no Xcode project; `build.sh` compiles them with `swiftc`.

## When the user asks to install or set it up

1. Check prerequisites and report anything missing. Do not install anything system-wide without asking.
   - `xcode-select -p` (Command Line Tools)
   - `claude auth status`: signed in? Note the email.
   - `codex --version` (optional). If Codex is not installed, install only Claude Usage: `./install.sh claude`.
2. Ask whether they want to monitor more than one Claude account. If yes:
   - Have them run `CLAUDE_CONFIG_DIR=~/.claude-second claude auth login` themselves. It opens a browser sign-in, so never handle their credentials.
   - Write `~/Library/Application Support/Claude Usage/accounts.json` based on `examples/accounts.json`, using badges and labels they choose.
   - Confirm that each slot reports a different email with `claude auth status`.
3. Run `./install.sh` (or `./install.sh claude`). It builds the apps, runs self-tests, copies them to `~/Applications`, starts them, and enables Open at Login.
4. Verify that `pgrep -x ClaudeUsage` (and `pgrep -x CodexUsage`) shows a running process, and that `~/Applications/Claude\ Usage.app/Contents/MacOS/ClaudeUsage --login-status` prints status `1` (enabled).
5. Tell the user how to read the label: `badge 5h%/weekly%·time-to-weekly-reset`. `*` means stale, `!` means there is an issue, and clicking an item shows details.

## Rules

- Never print, log or copy OAuth tokens or Keychain secrets. Do not run `security find-generic-password -w` yourself.
- Do not change Keychain ACLs or partition lists. The app reads through `/usr/bin/security` so that it never triggers prompts.
- Do not modify or inject anything into the Claude Desktop app.
- After changing source code, run `./build.sh` first. It runs `--self-test` for each app and must pass before you reinstall.

## Code notes

- Claude Keychain service name: `Claude Code-credentials`. When `CLAUDE_CONFIG_DIR` is set, it is followed by `-` and the first 8 hex digits of SHA-256 of that path (see `Account.service`).
- Endpoints: `https://api.anthropic.com/api/oauth/usage` and `/api/oauth/profile`, both with the header `anthropic-beta: oauth-2025-04-20`.
- Login items start with a minimal PATH, so the helpers look for the `claude` and `codex` binaries in fixed locations.
- Signing is ad-hoc by default. Set `SIGN_IDENTITY` to sign with your own identity.
