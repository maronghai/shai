# lib/agent.sh — Agent personas: switching, listing, prompting
#
# Sourced by ai-agent.sh. Provides:
#   - list_agents:           numbered list, optional @tag filter
#   - _resolve_agent_id:     1-based id -> agent name
#   - switch_agent:          switch active persona (updates DB, history, tools)
#   - agent_status:          print current agent metadata
#   - _agent_prompt:         build the REPL prompt string
#   - parse_frontmatter:     extract description+tags from `---` block
#   - agent_description:     frontmatter description or H1 fallback
#   - agent_tags:            frontmatter tags CSV
#   - _agent_matches_tag:    case where a tag filter matches
#
# All functions read $CURRENT_AGENT / $AGENTS_DIR / $WORK_DIR / $DB_PATH at call time.

list_agents() {
    local filter_tag="${1:-}"
    local marker name desc tags d found=0 idx=0
    if [[ -z "$CURRENT_AGENT" ]]; then marker="*"; else marker=" "; fi
    desc=$(agent_description "${WORK_DIR}/SYSTEM_PROMPT.md")
    [[ -z "$desc" ]] && desc="(no description)"
    tags=$(agent_tags "${WORK_DIR}/SYSTEM_PROMPT.md")
    if _agent_matches_tag "$tags" "$filter_tag"; then
        idx=$((idx+1))
        _print_agent_line "$idx" "default" "$desc" "$tags" "$marker"
        found=1
    fi
    if [[ -d "$AGENTS_DIR" ]]; then
        for d in "$AGENTS_DIR"/*/; do
            [[ -d "$d" ]] || continue
            name=$(basename "$d")
            [[ ! -f "$d/system.md" ]] && continue
            desc=$(agent_description "$d/system.md")
            [[ -z "$desc" ]] && desc="(no description)"
            tags=$(agent_tags "$d/system.md")
            if [[ "$name" == "$CURRENT_AGENT" ]]; then marker="*"; else marker=" "; fi
            if _agent_matches_tag "$tags" "$filter_tag"; then
                idx=$((idx+1))
                _print_agent_line "$idx" "$name" "$desc" "$tags" "$marker"
                found=1
            fi
        done
    fi
    if [[ $found -eq 0 && -n "$filter_tag" ]]; then
        warn "no agents match tag @$filter_tag"
    fi
}

# Echo the agent name corresponding to the Nth entry in list_agents order
# (1-based: 1 = default, 2..N = named agents in directory iteration order).
# Returns 0 on success, 1 if the id is out of range. Pure helper, no side effects.
_resolve_agent_id() {
    local target="$1"
    [[ "$target" =~ ^[0-9]+$ ]] || return 1
    local idx=0 d name
    idx=$((idx+1))
    if [[ "$idx" == "$target" ]]; then echo "default"; return 0; fi
    if [[ -d "$AGENTS_DIR" ]]; then
        for d in "$AGENTS_DIR"/*/; do
            [[ -d "$d" ]] || continue
            name=$(basename "$d")
            [[ ! -f "$d/system.md" ]] && continue
            idx=$((idx+1))
            if [[ "$idx" == "$target" ]]; then echo "$name"; return 0; fi
        done
    fi
    return 1
}

switch_agent() {
    local name="$1"
    local target_agent="" target_prompt=""

    if [[ -z "$name" || "$name" == "default" ]]; then
        target_prompt="${WORK_DIR}/SYSTEM_PROMPT.md"
        if [[ ! -f "$target_prompt" ]]; then
            warn "default system prompt not found: $target_prompt"
            return 1
        fi
    else
        if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            warn "invalid agent name: $name"
            return 1
        fi
        target_agent="$name"
        target_prompt="$AGENTS_DIR/$name/system.md"
        if [[ ! -f "$target_prompt" ]]; then
            warn "agent '$name' not found (missing $target_prompt)"
            return 1
        fi
    fi

    CURRENT_AGENT="$target_agent"

    if [[ -n "$CURRENT_AGENT" ]]; then
        printf '%s' "$CURRENT_AGENT" > "$CURRENT_AGENT_FILE"
    else
        rm -f "$CURRENT_AGENT_FILE" 2>/dev/null || true
    fi

    DB_PATH=$(db_path)
    TOOLS_CACHE="$DATA_DIR/tools_cache${CURRENT_AGENT:+_$CURRENT_AGENT}.json"
    TOOLS_DESC_CACHE="$DATA_DIR/tools_desc${CURRENT_AGENT:+_$CURRENT_AGENT}.txt"

    SYSTEM_PROMPT="$(load_system_prompt)"

    init_db
    prune_history
    load_history
    load_tools

    return 0
}

agent_status() {
    local cur msgs_n tools_n
    if [[ -z "$CURRENT_AGENT" ]]; then cur="default"; else cur="$CURRENT_AGENT"; fi
    msgs_n=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM messages" 2>/dev/null || echo 0)
    tools_n=$(echo "$tools_json" | jq 'length' 2>/dev/null || echo 0)
    local desc tags f
    if [[ -n "$CURRENT_AGENT" ]]; then f="$AGENTS_DIR/$CURRENT_AGENT/system.md"; else f="${WORK_DIR}/SYSTEM_PROMPT.md"; fi
    desc=$(agent_description "$f")
    tags=$(agent_tags "$f")
    printf 'name=%s\n' "$cur"
    [[ -n "$desc" ]] && printf 'description=%s\n' "$desc"
    [[ -n "$tags" ]] && printf 'tags=%s\n' "$tags"
    printf 'db=%s msgs=%s tools=%s\n' "$DB_PATH" "$msgs_n" "$tools_n"
}

# Build the REPL prompt. Format:
#   You [default]>                     (green; default agent)
#   You [code-reviewer · read-only]>   (yellow; named agent, desc truncated to 30 chars)
# Non-default agents get yellow so the user notices they're in a specialized context.
_agent_prompt() {
    local label color f desc hint=""
    if [[ -n "$CURRENT_AGENT" ]]; then
        label="$CURRENT_AGENT"
        color="$Y"
        f="$AGENTS_DIR/$CURRENT_AGENT/system.md"
        if [[ -f "$f" ]]; then
            desc=$(agent_description "$f" 2>/dev/null)
            if [[ -n "$desc" && "$desc" != "(no description)" ]]; then
                if [[ ${#desc} -gt 30 ]]; then
                    hint=" ${D}· ${desc:0:30}…${R}"
                else
                    hint=" ${D}· $desc${R}"
                fi
            fi
        fi
    else
        label="default"
        color="$G"
    fi
    printf '%bYou%b [%b%s%b]%b> ' "$B" "$R" "$color" "$label" "$hint" "$R"
}

parse_frontmatter() {
    local file="$1"
    FM_DESC=""
    FM_TAGS=""
    [[ ! -f "$file" ]] && return 1
    local in_fm=0 line key val
    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            ((in_fm++))
            [[ $in_fm -ge 2 ]] && break
            continue
        fi
        if [[ $in_fm -eq 1 && "$line" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_-]*)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            case "$key" in
                description) FM_DESC="$val" ;;
                tags) FM_TAGS="$val" ;;
            esac
        fi
    done < <(head -20 "$file")
}

agent_description() {
    local file="$1"
    parse_frontmatter "$file"
    if [[ -n "$FM_DESC" ]]; then
        echo "$FM_DESC"
    else
        head -1 "$file" 2>/dev/null | sed 's/^# *//'
    fi
}

agent_tags() {
    local file="$1"
    parse_frontmatter "$file"
    echo "$FM_TAGS"
}

_agent_matches_tag() {
    local tags="$1" filter_tag="$2"
    if [[ -z "$filter_tag" ]]; then return 0; fi
    local IFS=','
    local t
    for t in $tags; do
        t="${t#"${t%%[![:space:]]*}"}"
        t="${t%"${t##*[![:space:]]}"}"
        [[ -n "$t" && "$t" == "$filter_tag" ]] && return 0
    done
    return 1
}
