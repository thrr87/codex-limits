# Releasing Codex Limits

Releases are prepared by the manual `Release` GitHub Actions workflow. It builds one universal macOS app, signs the update archive and feed with Sparkle EdDSA, and stops at a Draft GitHub Release.

## One-time setup

1. Create a protected GitHub environment named `release` and restrict it to the `main` branch.
2. Store the exported Sparkle private key as the environment secret `SPARKLE_PRIVATE_KEY`.
3. Store a second copy of the private key in Bitwarden. Never commit or paste it into an issue, pull request, workflow input, or chat.
4. Keep the public key in `Resources/Info.plist`.

Losing the EdDSA private key prevents ad-hoc-signed installations from trusting future updates. Keep both protected copies.

## Release flow

1. Ask Codex to prepare a release and provide the stable version number.
2. Codex runs tests and QA, then updates `CFBundleShortVersionString` and increments `CFBundleVersion`.
3. Run `Scripts/validate-release.sh VERSION` and the `Release` workflow with `dry_run` enabled.
4. Inspect the universal app archive, signed `appcast.xml`, generated notes, and workflow result.
5. Run the workflow with `dry_run` disabled. It creates a Draft Release only.
6. Inspect the draft and explicitly tell Codex to publish it.

Publishing a stable GitHub Release makes its `appcast.xml` available through the repository's `releases/latest/download` URL. Drafts and prereleases are not returned by that URL.

The app and update archive are ad-hoc signed because this project has no Apple Developer ID certificate. Sparkle still verifies the EdDSA-signed feed and archive. A user's first manual installation remains subject to macOS Gatekeeper; in-app updates do not remove that first-install limitation.
