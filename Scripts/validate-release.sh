#!/bin/zsh
set -euo pipefail

autoload -Uz is-at-least

is_newer_than() {
    local candidate=$1
    local previous=$2
    ! is-at-least "$candidate" "$previous"
}

is_accepted_multi_integration_status() {
    [[ $1 == 'Status: Accepted for v1 implementation' ]]
}

release_gate_accepted() {
    local gate=$1
    local version=$2
    awk -F '|' -v gate="$gate" -v waiver="Waived for $version" '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        trim($2) == gate {
            found = 1
            passed = trim($4) == "Passed" || trim($4) == waiver
        }
        END { exit !(found && passed) }
    '
}

if [[ ${1:-} == --self-test ]]; then
    is_newer_than 0.2.7 0.2.6
    ! is_newer_than 0.2.7 0.2.7 || exit 1
    ! is_newer_than 0.2.7 0.2.8 || exit 1
    is_accepted_multi_integration_status \
        'Status: Accepted for v1 implementation'
    ! is_accepted_multi_integration_status \
        'Status: Needs revision — release gates remain' || exit 1
    release_gate_accepted 'All-enabled idle comparison' 0.3.0 <<< \
        '| All-enabled idle comparison | Recorded evidence | Passed |'
    ! release_gate_accepted 'All-enabled idle comparison' 0.3.0 <<< \
        '| All-enabled idle comparison | Not run | Pending |' || exit 1
    ! release_gate_accepted 'Eight-hour mixed lifecycle soak' 0.3.0 <<< \
        '| Another gate | Recorded evidence | Passed |' || exit 1
    release_gate_accepted 'Eight-hour mixed lifecycle soak' 0.3.0 <<< \
        '| Eight-hour mixed lifecycle soak | Owner decision | Waived for 0.3.0 |'
    ! release_gate_accepted 'Eight-hour mixed lifecycle soak' 0.3.1 <<< \
        '| Eight-hour mixed lifecycle soak | Owner decision | Waived for 0.3.0 |' || exit 1
    ! release_gate_accepted 'Eight-hour mixed lifecycle soak' 0.3.0 <<< \
        '| Eight-hour mixed lifecycle soak | Unscoped exception | Waived |' || exit 1
    print "Release validator checks passed"
    exit
fi

version=${1:?"Usage: $0 VERSION"}
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
    print -u2 "Release version must be stable semantic versioning, for example 0.2.7"
    exit 64
}

project_dir=${0:A:h:h}
multi_integration_prd="$project_dir/docs/prd/multi-integration-workspace.md"
multi_integration_status=$(sed -n '/^Status: /{p;q;}' "$multi_integration_prd")
is_accepted_multi_integration_status "$multi_integration_status" || {
    print -u2 "Multi-integration v1 release gates are not accepted"
    exit 65
}
for gate in \
    'All-enabled idle comparison' \
    'Eight-hour mixed lifecycle soak'; do
    release_gate_accepted "$gate" "$version" < "$multi_integration_prd" || {
        print -u2 "Multi-integration release gate is not accepted for $version: $gate"
        exit 65
    }
done
plist="$project_dir/Resources/Info.plist"
plist_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
[[ $plist_version == $version ]] || {
    print -u2 "Info.plist version is $plist_version, expected $version"
    exit 65
}
[[ $build == <-> ]] || {
    print -u2 "CFBundleVersion must be an integer"
    exit 65
}

cd "$project_dir"
tag="v$version"
if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    print -u2 "$tag already exists"
    exit 65
fi

latest_tag=$(git tag --list 'v[0-9]*' --sort=-version:refname | head -n 1)
if [[ -n $latest_tag ]]; then
    latest_version=${latest_tag#v}
    is_newer_than "$version" "$latest_version" || {
        print -u2 "$version must be newer than $latest_version"
        exit 65
    }

    previous_plist=$(mktemp)
    trap 'rm -f "$previous_plist"' EXIT
    git show "$latest_tag:Resources/Info.plist" > "$previous_plist"
    previous_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$previous_plist")
    (( build > previous_build )) || {
        print -u2 "Build $build must be greater than $previous_build"
        exit 65
    }
fi

print "Validated $tag (build $build)"
