#!/bin/sh
# agent_list.sh - List default + named agents available for delegation.
#
# Env:
#   WORK_DIR     - path to the main script's working directory
#   AGENTS_DIR   - path to the agents/ directory
#   AGENT_NAME   - name of the calling agent (for awareness)

work_dir="${WORK_DIR:-/data}"
agents_dir="${AGENTS_DIR:-/data/agents}"

# JSON escape for a string value: replace \ then " then control chars.
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | tr -d '\n\r'
}

first=1
printf '['
# Default
desc=$(head -1 "$work_dir/SYSTEM_PROMPT.md" 2>/dev/null | sed 's/^# *//')
[ -z "$desc" ] && desc="(no description)"
[ $first -eq 0 ] && printf ','
printf '{"name":"default","description":"%s"}' "$(json_escape "$desc")"
first=0
# Named
if [ -d "$agents_dir" ]; then
    for d in "$agents_dir"/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        [ "$name" = "*" ] && continue
        [ ! -f "$d/system.md" ] && continue
        ddesc=$(head -1 "$d/system.md" 2>/dev/null | sed 's/^# *//')
        [ -z "$ddesc" ] && ddesc="(no description)"
        [ $first -eq 0 ] && printf ','
        printf '{"name":"%s","description":"%s"}' "$name" "$(json_escape "$ddesc")"
        first=0
    done
fi
printf ']\n'
