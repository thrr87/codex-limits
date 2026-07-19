# Codex Limits

A lightweight macOS menu-bar app for tracking the remaining Codex usage allowance and pacing it until reset.

The menu bar shows the current remaining percentage. The popover adds the reset time, a suggested pace, a burn-down chart, and one of three plain-language assessments: `Slow down`, `On track`, or `Room to use more`.

> [!NOTE]
> Codex Limits is an independent, unofficial project. It is not affiliated with or endorsed by OpenAI.

## What it does

- Reads the main Codex limit and any independent model-specific limits.
- Records local samples to show actual usage during the current window.
- Compares actual usage with a straight target path ending at a configurable safety buffer.
- Projects the current pace and compares it with recent historical usage.
- Refreshes on launch, wake, popover open, every ten minutes, or when requested manually.
- Runs as a native SwiftUI menu-bar app with no third-party runtime dependencies.

The default safety buffer is 3%. You can change it in the app settings.

## Privacy

Codex Limits is local-first:

- It does not copy or store Codex credentials.
- It starts the user-managed Codex CLI and reads usage through its local app-server interface.
- It stores usage samples only in macOS `UserDefaults` for the app.
- It has no telemetry, analytics, notifications, or direct network client.
- The Codex CLI may contact the Codex service as part of its normal operation.

Do not attach raw CLI output or screenshots containing account usage to public issues.

## Requirements

- macOS 14 or later
- Xcode 15.3 or later
- a signed-in, Homebrew-managed Codex CLI at either `/opt/homebrew/bin/codex` or `/usr/local/bin/codex`

Codex Limits deliberately does not use a Codex binary bundled inside another application. Install and update the standalone CLI yourself.

## Build

Clone the repository and run:

```sh
Scripts/build-app.sh
```

The script creates an ad-hoc signed app at `.build/release/Codex Limits.app`. It does not produce a notarized distribution build.

To run it:

```sh
open ".build/release/Codex Limits.app"
```

Open `Package.swift` in Xcode to work on the source.

## Test

```sh
swift test
```

The test suite intentionally uses synthetic usage data. Do not commit exported account data or local app state as fixtures.

## Signed commits on another Mac

Use a different SSH key pair on each computer. Never copy a private key between machines.

After adding that Mac's public key to GitHub for authentication, add the same public key as a signing key and configure this clone:

```sh
gh auth refresh -h github.com -s admin:ssh_signing_key
gh ssh-key add ~/.ssh/id_ed25519.pub --type signing --title "Mac signing key"
git config gpg.format ssh
git config user.signingkey ~/.ssh/id_ed25519.pub
git config commit.gpgsign true
```

GitHub should show locally created commits as `Verified`.

## Current limitations

- No prebuilt or notarized release is provided.
- Forecast quality improves as the app collects local samples.
- Codex CLI app-server responses may change between CLI versions. If parsing fails, update the CLI before reporting a problem.

## Security

Please report vulnerabilities privately. See [SECURITY.md](.github/SECURITY.md) for instructions.

Commits reaching `main` must be signed. Use a separate signing key on each development machine; never copy a private key between computers.

## License

MIT. See [LICENSE](LICENSE).
