#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
app_dir="$project_dir/.build/release/Codex Limits.app"
update_dir="$project_dir/.build/qa-update"
executable_pattern="$project_dir/.build/.*/Codex Limits.app/Contents/MacOS/CodexLimits"
relative_executable_pattern="\\.build/.*/Codex Limits\\.app/Contents/MacOS/CodexLimits"
update_executable_pattern="$update_dir/Codex Limits QA.app/Contents/MacOS/CodexLimits"
action=${1:-launch}

cleanup() {
    pkill -f "$executable_pattern" 2>/dev/null || true
    pkill -f "$relative_executable_pattern" 2>/dev/null || true
    pkill -f "$update_executable_pattern" 2>/dev/null || true
    if [[ -f "$update_dir/server.pid" ]]; then
        kill "$(<"$update_dir/server.pid")" 2>/dev/null || true
    fi
}

case "$action" in
    cleanup)
        cleanup
        ;;
    launch)
        cleanup
        CODEX_LIMITS_QA=1 "$project_dir/Scripts/build-app.sh"
        open "$app_dir"
        ;;
    update)
        cleanup
        rm -rf "$update_dir"
        mkdir -p "$update_dir/feed"

        key_material=$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
            xcrun swift -e 'import CryptoKit; import Foundation; let key = Curve25519.Signing.PrivateKey(); print(key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())')
        private_key=${key_material%% *}
        public_key=${key_material#* }

        feed_url="http://127.0.0.1:8765/appcast.xml"
        CODEX_LIMITS_QA=1 \
        CODEX_LIMITS_VERSION=0.2.6 \
        CODEX_LIMITS_BUILD=7 \
        CODEX_LIMITS_FEED_URL="$feed_url" \
        CODEX_LIMITS_PUBLIC_ED_KEY="$public_key" \
            "$project_dir/Scripts/build-app.sh"
        ditto "$app_dir" "$update_dir/Codex Limits QA.app"

        CODEX_LIMITS_QA=1 \
        CODEX_LIMITS_VERSION=0.2.7 \
        CODEX_LIMITS_BUILD=8 \
        CODEX_LIMITS_FEED_URL="$feed_url" \
        CODEX_LIMITS_PUBLIC_ED_KEY="$public_key" \
            "$project_dir/Scripts/build-app.sh"
        archive="$update_dir/feed/Codex-Limits-QA-0.2.7.zip"
        ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive"
        print -r -- 'Secure in-app updates are ready for local QA.' \
            > "$update_dir/feed/Codex-Limits-QA-0.2.7.md"
        print -rn -- "$private_key" | \
            "$project_dir/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
            --ed-key-file - \
            --download-url-prefix "http://127.0.0.1:8765/" \
            --embed-release-notes \
            --maximum-deltas 0 \
            --critical-update-version '' \
            "$update_dir/feed"

        nohup python3 -m http.server 8765 --bind 127.0.0.1 \
            --directory "$update_dir/feed" \
            </dev/null > "$update_dir/server.log" 2>&1 &
        print -r -- $! > "$update_dir/server.pid"
        for _ in {1..20}; do
            curl --silent --fail "$feed_url" >/dev/null && break
            sleep 0.1
        done
        curl --silent --fail "$feed_url" >/dev/null
        open "$update_dir/Codex Limits QA.app"
        wait "$(<"$update_dir/server.pid")"
        ;;
    *)
        print -u2 "Usage: $0 [launch|update|cleanup]"
        exit 64
        ;;
esac
