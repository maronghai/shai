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

# Parse YAML-ish frontmatter at top of $1 (within first 20 lines).
# Outputs lines like "KEY:value" for description: and tags: only.
# Falls back to first-line H1 if no frontmatter or missing key.
parse_frontmatter() {
    local_file="$1"
    awk '
        NR > 20 { exit }
        /^---[[:space:]]*$/ { count++; if (count == 2) exit; next }
        count == 1 {
            n = index($0, ":")
            if (n > 0) {
                k = substr($0, 1, n - 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
                if (k == "description" || k == "tags") {
                    v = substr($0, n + 1)
                    sub(/^[[:space:]]+/, "", v)
                    printf "%s:%s\n", toupper(k), v
                }
            }
        }
    ' "$local_file"
}

agent_fm() {
    local_file="$1"
    [ -f "$local_file" ] || { printf '\t\n'; return; }
    fm=$(parse_frontmatter "$local_file" 2>/dev/null)
    desc=$(printf '%s\n' "$fm" | sed -n 's/^DESCRIPTION://p' | head -1)
    tags=$(printf '%s\n' "$fm" | sed -n 's/^TAGS://p' | head -1)
    if [ -z "$desc" ]; then
        desc=$(head -1 "$local_file" 2>/dev/null | sed 's/^# *//')
        [ -z "$desc" ] && desc="(no description)"
    fi
    printf '%s\t%s\n' "$desc" "$tags"
}

emit_agent() {
    local aname="$1" afile="$2"
    out=$(agent_fm "$afile")
    fm_desc=$(printf '%s' "$out" | cut -f1)
    fm_tags=$(printf '%s' "$out" | cut -f2)
    [ $first -eq 0 ] && printf ','
    printf '{"name":"%s","description":"%s"' "$aname" "$(json_escape "$fm_desc")"
    if [ -n "$fm_tags" ]; then
        printf ',"tags":"%s"' "$(json_escape "$fm_tags")"
    fi
    printf '}'
    first=0
}

first=1
printf '['
emit_agent "default" "$work_dir/SYSTEM_PROMPT.md"
if [ -d "$agents_dir" ]; then
    for d in "$agents_dir"/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        [ "$name" = "*" ] && continue
        [ ! -f "$d/system.md" ] && continue
        emit_agent "$name" "$d/system.md"
    done
fi
printf ']\n'
