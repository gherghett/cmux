#!/usr/bin/env bash
# cmux shell integration — source this from .bashrc or run automatically.
# Reports process history + wraps the `claude` command to inject hooks.

if [[ -n "$CMUX_SURFACE_ID" ]]; then
    # Report each command to cmux for process history tracking.
    # Uses DEBUG trap (fires before each command) to capture the process name.
    # The socket command is shell-agnostic — only this hook is bash-specific.
    # For zsh: use preexec hook. For fish: use fish_preexec.
    __cmux_preexec() {
        # $BASH_COMMAND is the command about to run
        local cmd="${BASH_COMMAND%% *}"  # first word = process name
        # Skip internal/background stuff, prompt hooks, completions
        [[ "$cmd" == __cmux_* ]] && return
        [[ "$cmd" == _* ]] && return
        [[ "$cmd" == cmux-cli ]] && return
        [[ "$cmd" == starship* ]] && return
        [[ "$cmd" == "" ]] && return
        cmux-cli report_process "$cmd" "--tab=$CMUX_WORKSPACE_ID" "--surface=$CMUX_SURFACE_ID" &>/dev/null &
        disown
    }
    trap '__cmux_preexec' DEBUG
fi

if [[ -n "$CMUX_SURFACE_ID" && "$CMUX_CLAUDE_HOOKS_DISABLED" != "1" ]]; then
    # Cache the real claude binary path BEFORE defining our wrapper function.
    __cmux_real_claude="$(command -v claude 2>/dev/null)"

    claude() {
        local real_claude="${__cmux_real_claude}"
        [[ -z "$real_claude" || ! -x "$real_claude" ]] && { echo "Error: claude not found" >&2; return 127; }

        # Pass through non-interactive subcommands
        case "${1:-}" in
            mcp|config|api-key) "$real_claude" "$@"; return $?; ;;
        esac

        unset CLAUDECODE

        local skip_session_id=false
        for arg in "$@"; do
            case "$arg" in
                --resume|--resume=*|--session-id|--session-id=*|--continue|-c)
                    skip_session_id=true; break ;;
            esac
        done

        local hooks_json='{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"cmux-cli claude-hook session-start","timeout":10}]}],"Stop":[{"matcher":"","hooks":[{"type":"command","command":"cmux-cli claude-hook stop","timeout":10}]}],"Notification":[{"matcher":"","hooks":[{"type":"command","command":"cmux-cli claude-hook notification","timeout":10}]}]}}'

        if [[ "$skip_session_id" == true ]]; then
            "$real_claude" --settings "$hooks_json" "$@"
        else
            local session_id
            session_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')"
            "$real_claude" --session-id "$session_id" --settings "$hooks_json" "$@"
        fi
    }
fi
