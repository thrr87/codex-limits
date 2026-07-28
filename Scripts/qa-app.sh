#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
app_dir="$project_dir/.build/release/Codex Limits.app"
executable_pattern="$project_dir/.build/.*/Codex Limits.app/Contents/MacOS/CodexLimits"
relative_executable_pattern="\\.build/.*/Codex Limits\\.app/Contents/MacOS/CodexLimits"
action=${1:-launch}

cleanup() {
    pkill -f "$executable_pattern" 2>/dev/null || true
    pkill -f "$relative_executable_pattern" 2>/dev/null || true
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
    *)
        print -u2 "Usage: $0 [launch|cleanup]"
        exit 64
        ;;
esac
