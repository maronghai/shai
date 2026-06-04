# lib/complete.sh — TAB completion for the ai-agent REPL
#
# Provides:
#   - _ai_cmds            canonical /commands + subcommands (one per line)
#   - _ai_subcmds_of      echo subcommand verbs/flags for a given parent
#   - _ai_lcp             longest common prefix of stdin lines
#   - _ai_complete        readline TAB handler (bound via bind -x)
#
# Behaviour
# ---------
# On TAB:
#   1. Find the current word (the run of non-space chars ending at the cursor)
#      and the previous word (the run of non-space chars before that).
#   2. If current is empty:
#        - if prev is a known parent (/board, /task, /team, /tools, /agent,
#          /hist): list its subcommands
#        - otherwise: list all /commands
#   3. If current starts with /: list all /commands matching the prefix.
#   4. If prev is a known parent: list its subcommands that start with current.
#   5. Otherwise: no completion.
#
#   When exactly one candidate: complete to it.
#   When >1 candidates: extend to the longest common prefix; if LCP == current,
#     list all candidates below the line (re-render the prompt after).

# Canonical /commands (one per line). Subcommands are listed as their parent
# plus a space plus the sub verb (e.g. "/board write"). Keep in sync with the
# case statement in ai-agent.sh's REPL loop.
_ai_cmds() {
    printf '%s\n' \
        /exit /reload /help \
        /agents /agent \
        /agent\ reload \
        /clear /board \
        /board\ write /board\ reply /board\ clear /board\ topics /board\ grep /board\ stat \
        /tasks /task \
        /task\ clear /task\ clear\ -y /task\ clear\ --yes \
        /team \
        /team\ start /team\ next /team\ stop /team\ clear /team\ clear\ -y \
        /read /grep /exec /save /tools \
        /tools\ reload \
        /hist \
        /hist\ full \
    | sort -u
}

# Echo subcommands (verbs OR flags like -y/--yes) for a given parent.
_ai_subcmds_of() {
    local parent="$1"
    case "$parent" in
        /board)  printf '%s\n' write reply clear topics grep stat ;;
        /task)   printf '%s\n' clear -y --yes ;;
        /tasks)  printf '%s\n' ready ;;
        /team)   printf '%s\n' start next stop clear -y --yes ;;
        /tools)  printf '%s\n' reload ;;
        /agent)  printf '%s\n' reload ;;
        /hist)   printf '%s\n' full ;;
        *)       ;;
    esac
}

# Echo the FLAGS that a subcommand verb of a parent accepts.
# Used when the user has typed "/task clear -" and we want to offer
# the -y/--yes family.
_ai_flags_for() {
    # args: parent verb
    case "$1:$2" in
        /task:clear)  printf '%s\n' -y --yes ;;
        /team:clear)  printf '%s\n' -y --yes ;;
        *)            ;;
    esac
}

# True if `$2` is a known subcommand verb of parent `$1` (exact match).
_ai_is_subverb() {
    local parent="$1" verb="$2"
    while IFS= read -r sub; do
        [[ "$sub" == "$verb" ]] && return 0
    done < <(_ai_subcmds_of "$parent")
    return 1
}

# Longest common prefix of stdin lines. Echoed to stdout (no trailing newline).
_ai_lcp() {
    local line lcp= n=0 first=1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if (( first )); then
            lcp="$line"
            first=0
            n=${#lcp}
        else
            while (( n > ${#line} )) || [[ "${line:0:n}" != "$lcp" ]]; do
                n=$(( n - 1 ))
                lcp="${lcp:0:n}"
                (( n == 0 )) && break
            done
        fi
        (( n == 0 )) && break
    done
    printf '%s' "$lcp"
}

# Escape a string for use as a literal pattern in a basic regex.
# Used to make `grep -E "^$esc"` match the prefix as a literal.
_ai_re_escape() {
    printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g'
}

# The TAB handler. Runs in a subshell spawned by `bind -x` but can read
# and write READLINE_LINE / READLINE_POINT to mutate the input buffer.
_ai_complete() {
    [[ -z "${READLINE_LINE+x}" ]] && return 0

    local line="${READLINE_LINE}"
    local point="${READLINE_POINT}"
    (( point > ${#line} )) && point=${#line}
    local prefix="${line:0:point}"

    # Current word = last non-space run ending at the cursor
    local current=""
    if [[ "$prefix" =~ ([^[:space:]]*)$ ]]; then
        current="${BASH_REMATCH[1]}"
    fi

    # Previous word = last non-space run BEFORE the current one (the gap
    # is at least one space, possibly more)
    local before="${prefix:0:${#prefix}-${#current}}"
    before="${before%"${before##*[![:space:]]}"}"
    local prev=""
    if [[ "$before" =~ ([^[:space:]]+)$ ]]; then
        prev="${BASH_REMATCH[1]}"
    fi

    # ---- pick candidates ----
    # We always store candidates as the FULL completion string the user
    # would see if they tabbed once on a clean prompt (i.e. including
    # the parent). For parent-scoped completions, this means the
    # subcommand verb goes in the candidate as-is; the parent is
    # implicit in the line.
    local candidates=""
    local esc

    if [[ -z "$current" ]]; then
        # Empty current word: show all commands (or subcommands if a parent)
        if [[ -n "$prev" ]] && _ai_subcmds_of "$prev" >/dev/null 2>&1 \
           && [[ -n "$(_ai_subcmds_of "$prev")" ]]; then
            # parent has subcommands → list them as the verb
            candidates=$(_ai_subcmds_of "$prev")
        else
            candidates=$(_ai_cmds)
        fi
    elif [[ "$current" == /* ]]; then
        # Typing a /command: filter the canonical list
        esc=$(_ai_re_escape "$current")
        candidates=$(_ai_cmds | grep -E "^${esc}" || true)
    elif [[ -n "$prev" ]] && [[ -n "$(_ai_subcmds_of "$prev")" ]]; then
        # Typing the verb of a known parent command
        esc=$(_ai_re_escape "$current")
        candidates=$(_ai_subcmds_of "$prev" | grep -E "^${esc}" || true)
    elif [[ "$current" == -* ]] && [[ -n "$prev" ]] && [[ -n "$before" ]]; then
        # Typing a flag (starts with -) right after a subcommand verb.
        # Look up the parent via the word before the verb.
        local grandparent=""
        # `before` = line content before current, with trailing whitespace
        # stripped. The last word of `before` is `$prev`; the word before
        # THAT is the grandparent (the parent /command).
        local b2="${before%"${prev}"}"      # drop prev
        b2="${b2%"${b2##*[![:space:]]}"}"  # drop trailing spaces
        if [[ "$b2" =~ ([^[:space:]]+)$ ]]; then
            grandparent="${BASH_REMATCH[1]}"
        fi
        if [[ -n "$grandparent" ]] && _ai_is_subverb "$grandparent" "$prev"; then
            local flags
            flags=$(_ai_flags_for "$grandparent" "$prev")
            if [[ -n "$flags" ]]; then
                esc=$(_ai_re_escape "$current")
                candidates=$(printf '%s\n' "$flags" | grep -E "^${esc}" || true)
            fi
        fi
    fi

    [[ -z "$candidates" ]] && return 0

    local count
    count=$(printf '%s\n' "$candidates" | awk 'NF{c++} END{print c+0}')

    if (( count == 0 )); then
        return 0
    fi

    # ---- apply completion ----
    # Decide what the "insert text" is, given the relationship between
    # current and the candidate:
    #
    #   current  candidates                            insert
    #   -------   -----------------------------------   ----------------
    #   ""        ["write","reply",...]                list (don't insert)
    #   "/a"      ["/agent","/agent reload","/agents"]  longest = "/agent"
    #   "w"       ["write"] (prev=/board)              "write" (current empty, single)
    #
    # The insert text is whatever extends the user's `current` to the
    # completed form. For /command completion, the full candidate is
    # the completed form. For sub-verb completion, the verb alone is
    # the completed form (the parent is already in the line).
    local insert=""
    if (( count == 1 )); then
        insert=$(printf '%s\n' "$candidates" | awk 'NF{print; exit}')
    else
        # >1 candidates: try the LCP first
        local lcp
        lcp=$(printf '%s\n' "$candidates" | _ai_lcp)
        if [[ -z "$current" || -z "$lcp" ]]; then
            # empty current or no common prefix → just list
            : # fall through to list branch below
        elif [[ "${#lcp}" -gt "${#current}" ]]; then
            insert="$lcp"
        else
            : # LCP == current → list
        fi
    fi

    if [[ -n "$insert" ]]; then
        # Replace the current word with the insert text
        local new_line="${line:0:$((point - ${#current}))}${insert}${line:point}"
        READLINE_LINE="$new_line"
        READLINE_POINT=$(( point - ${#current} + ${#insert} ))
    else
        # List candidates below the line; re-render prompt + line.
        printf '\n' >&2
        printf '%s\n' "$candidates" | awk 'NF{printf "  %s\n", $0}' >&2
        # Re-display the prompt + current line
        printf '\001%s\002%s' "${PS1:-\$ }" "$line" >&2
        # Move cursor to its original position
        local pad=$(( ${#line} - point ))
        if (( pad > 0 )); then
            printf '\033[%dD' "$pad" >&2
        fi
    fi
    return 0
}

# Wire TAB to our handler. Only takes effect when `read -e` is active
# (i.e. inside the REPL). `bind -x` runs in a subshell but READLINE_LINE /
# READLINE_POINT propagate back, so the input buffer updates in place.
bind -x '"\C-i": _ai_complete' 2>/dev/null || true
