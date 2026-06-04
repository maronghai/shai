# lib/cmd.sh — Slash-command helpers: "did you mean" suggestions
#
# Sourced by ai-agent.sh. Provides:
#   - _cmd_known:           list of canonical slash commands (one per line)
#   - _levenshtein:         edit distance (pure bash, integer return)
#   - _suggest_command:     print top-N similar commands for an unknown input,
#                           or empty if nothing is close enough
#
# Used by the REPL's /<unknown> catch-all case to give typo feedback
# without falling through to the LLM.

# Canonical slash commands. Keep in sync with the case statement in ai-agent.sh.
# Only the BARE command form (no args) is matched — variants like "/tasks ready"
# or "/team clear -y" are exposed via their parent "/tasks" / "/team" suggestion.
_cmd_known() {
    printf "%s\n" \
        "/exit"     "/reload"  "/help"     \
        "/agents"   "/agent"   \
        "/clear"    "/board"   \
        "/tasks"    "/task"    \
        "/team"     \
        "/hist"     \
        "/tools"    "/save"
}

# Pure-bash Levenshtein. Iterative two-row DP. O(len_a * len_b).
# Echoes the edit distance (integer).
_levenshtein() {
    local a="$1" b="$2"
    local la=${#a} lb=${#b}
    # If either is empty, distance is the length of the other.
    if (( la == 0 )); then echo "$lb"; return; fi
    if (( lb == 0 )); then echo "$la"; return; fi

    # Two row buffers (prev / curr) indexed 0..lb.
    local -a prev curr
    local i j cost del ins rep c
    for (( j = 0; j <= lb; j++ )); do prev[j]=$j; done

    for (( i = 1; i <= la; i++ )); do
        curr[0]=$i
        for (( j = 1; j <= lb; j++ )); do
            if [[ "${a:i-1:1}" == "${b:j-1:1}" ]]; then cost=0; else cost=1; fi
            (( del = prev[j] + 1 ))
            (( ins = curr[j-1] + 1 ))
            (( rep = prev[j-1] + cost ))
            c=$del
            (( ins < c )) && c=$ins
            (( rep < c )) && c=$rep
            curr[j]=$c
        done
        # swap prev <-> curr
        local -a tmp
        tmp=("${prev[@]}")
        prev=("${curr[@]}")
        curr=("${tmp[@]}")
    done
    echo "${prev[lb]}"
}

# Suggest similar commands for an unknown slash input.
# Usage: _suggest_command "/agnet" [max_results] [max_distance]
# Prints up to max_results (default 3) suggestions, one per line, sorted by
# distance ascending. Skips suggestions whose distance is > max_distance
# (default 2 for short commands, scaled for long ones — see below).
# Prints nothing if nothing is close enough.
_suggest_command() {
    local input="$1"
    local max_results="${2:-3}"
    # Strip the leading slash and any trailing arg so we only compare the
    # command word: "/agnet" -> "agnet", "/agnet foo bar" -> "agnet".
    local cmd="${input#/}"
    cmd="${cmd%% *}"
    [[ -z "$cmd" ]] && return 0
    local len=${#cmd}

    # Threshold: keep the suggestion set honest.
    # - len <= 4  -> max_distance 1  (single typo on a short word)
    # - len <= 8  -> max_distance 2
    # - len >  8  -> max_distance 3
    local max_d
    if   (( len <= 4 )); then max_d=1
    elif (( len <= 8 )); then max_d=2
    else                       max_d=3
    fi

    # Compute distance to every known command, collect CSV: distance|command
    local cand dist
    local results=""
    while IFS= read -r cand; do
        [[ -z "$cand" ]] && continue
        # Compare against the bare command (strip leading "/")
        local bare="${cand#/}"
        dist="$(_levenshtein "$cmd" "$bare")"
        if (( dist <= max_d )); then
            results+="${dist}|${cand}"$'\n'
        fi
    done < <(_cmd_known)

    # Sort by distance, take top N.
    if [[ -n "$results" ]]; then
        # Strip trailing newline so the trailing "\n" from `results+="..."$'\n'`
        # doesn't produce an extra blank line after `cut -d'|' -f2`.
        printf "%s" "$results" | sort -t'|' -k1,1n | head -n "$max_results" | cut -d'|' -f2
    fi
}
