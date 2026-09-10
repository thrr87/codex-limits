#!/bin/zsh
set -euo pipefail

if [[ ${1:-} == --self-test ]]; then
    output=$(mktemp /private/tmp/codex-limits-idle-self-test.XXXXXX.csv)
    trap 'rm -f "$output"' EXIT
    "$0" $$ 2 1 "$output" >/dev/null
    [[ $(wc -l < "$output") -eq 3 ]]
    print "Idle sampler checks passed"
    exit
fi

pid=${1:?"Usage: $0 PID DURATION_SECONDS INTERVAL_SECONDS OUTPUT.csv"}
duration=${2:?"Usage: $0 PID DURATION_SECONDS INTERVAL_SECONDS OUTPUT.csv"}
interval=${3:?"Usage: $0 PID DURATION_SECONDS INTERVAL_SECONDS OUTPUT.csv"}
output=${4:?"Usage: $0 PID DURATION_SECONDS INTERVAL_SECONDS OUTPUT.csv"}

[[ $pid == <-> && $pid -gt 0 ]]
[[ $duration == <-> && $duration -gt 0 ]]
[[ $interval == <-> && $interval -gt 0 && $interval -le 60 ]]
kill -0 "$pid"

samples=$(( (duration + interval - 1) / interval ))
print 'timestamp,parent_rss_kib,parent_cpu_percent,child_count,child_rss_kib,child_cpu_percent' > "$output"

for ((sample = 1; sample <= samples; sample++)); do
    parent=$(/bin/ps -o rss=,%cpu= -p "$pid" | awk '{$1=$1; print}')
    [[ -n $parent ]] || {
        print -u2 "Process $pid ended after $((sample - 1)) samples"
        exit 66
    }
    read -r parent_rss parent_cpu <<< "$parent"
    children=$(/bin/ps -axo ppid=,rss=,%cpu= | awk -v parent="$pid" '
        $1 == parent { count += 1; rss += $2; cpu += $3 }
        END { printf "%d %d %.3f", count, rss, cpu }
    ')
    read -r child_count child_rss child_cpu <<< "$children"
    print "$(date +%s),$parent_rss,$parent_cpu,$child_count,$child_rss,$child_cpu" >> "$output"

    if (( sample % 6 == 0 || sample == samples )); then
        print -u2 "sample $sample/$samples rss=${parent_rss}KiB cpu=${parent_cpu}% children=$child_count"
    fi
    if (( sample < samples )); then
        sleep "$interval"
    fi
done
