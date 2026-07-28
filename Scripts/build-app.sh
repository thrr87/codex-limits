#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
app_dir="$project_dir/.build/release/Codex Limits.app"

cd "$project_dir"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH=/private/tmp/codex-limits-clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/codex-limits-swiftpm-cache

build_args=(-c release --disable-sandbox)
if [[ ${CODEX_LIMITS_QA:-0} == 1 ]]; then
    build_args+=(-Xswiftc -DCODEX_LIMITS_QA)
fi

xcrun swift build "${build_args[@]}"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp .build/release/CodexLimits "$app_dir/Contents/MacOS/CodexLimits"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
if [[ ${CODEX_LIMITS_QA:-0} == 1 ]]; then
    /usr/libexec/PlistBuddy -c \
        "Set :CFBundleIdentifier com.github.thrr87.CodexLimits.QA" \
        "$app_dir/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c \
        "Set :CFBundleDisplayName Codex Limits QA" \
        "$app_dir/Contents/Info.plist"
fi
codesign --force --sign - "$app_dir"

print -r -- "$app_dir"
