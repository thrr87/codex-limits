# User-managed stable Codex CLI

The app uses the standalone stable `codex` installed by Homebrew at `/opt/homebrew/bin/codex` or `/usr/local/bin/codex`. It does not fall back to a prerelease binary bundled inside another application. CLI updates remain under the user's control; the app never modifies the CLI and shows a simple update instruction when the protocol is incompatible.
