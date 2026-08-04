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

if [[ ${CODEX_LIMITS_UNIVERSAL:-0} == 1 ]]; then
    for architecture in arm64 x86_64; do
        scratch="$project_dir/.build/universal-$architecture"
        xcrun swift build "${build_args[@]}" \
            --triple "$architecture-apple-macosx14.0" \
            --scratch-path "$scratch" \
            --cache-path "$project_dir/.build/package-cache"
    done
    arm_release="$project_dir/.build/universal-arm64/arm64-apple-macosx/release"
    intel_release="$project_dir/.build/universal-x86_64/x86_64-apple-macosx/release"
    executable="$project_dir/.build/release/CodexLimits"
    mkdir -p "${executable:h}"
    lipo -create \
        "$arm_release/CodexLimits" \
        "$intel_release/CodexLimits" \
        -output "$executable"
    framework="$arm_release/Sparkle.framework"
else
    xcrun swift build "${build_args[@]}"
    executable="$project_dir/.build/release/CodexLimits"
    framework="$project_dir/.build/release/Sparkle.framework"
fi

rm -rf "$app_dir"
mkdir -p \
    "$app_dir/Contents/MacOS" \
    "$app_dir/Contents/Resources" \
    "$app_dir/Contents/Frameworks"
cp "$executable" "$app_dir/Contents/MacOS/CodexLimits"
install_name_tool -add_rpath \
    @loader_path/../Frameworks \
    "$app_dir/Contents/MacOS/CodexLimits"
ditto "$framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
if [[ -n ${CODEX_LIMITS_VERSION:-} ]]; then
    /usr/libexec/PlistBuddy -c \
        "Set :CFBundleShortVersionString $CODEX_LIMITS_VERSION" \
        "$app_dir/Contents/Info.plist"
fi
if [[ -n ${CODEX_LIMITS_BUILD:-} ]]; then
    /usr/libexec/PlistBuddy -c \
        "Set :CFBundleVersion $CODEX_LIMITS_BUILD" \
        "$app_dir/Contents/Info.plist"
fi
if [[ -n ${CODEX_LIMITS_FEED_URL:-} ]]; then
    /usr/libexec/PlistBuddy -c \
        "Set :SUFeedURL $CODEX_LIMITS_FEED_URL" \
        "$app_dir/Contents/Info.plist"
fi
if [[ -n ${CODEX_LIMITS_PUBLIC_ED_KEY:-} ]]; then
    /usr/libexec/PlistBuddy -c \
        "Set :SUPublicEDKey $CODEX_LIMITS_PUBLIC_ED_KEY" \
        "$app_dir/Contents/Info.plist"
fi
if [[ ${CODEX_LIMITS_QA:-0} == 1 ]]; then
    /usr/libexec/PlistBuddy -c \
        "Set :CFBundleIdentifier com.github.thrr87.CodexLimits.QA" \
        "$app_dir/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c \
        "Set :CFBundleDisplayName Codex Limits QA" \
        "$app_dir/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c \
        "Add :NSAppTransportSecurity dict" \
        "$app_dir/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c \
        "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" \
        "$app_dir/Contents/Info.plist"
fi
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"

print -r -- "$app_dir"
