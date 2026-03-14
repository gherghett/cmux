#!/usr/bin/env bash
# cmux shell integration — source this from .bashrc or run automatically.
# Wraps the `claude` command to inject hooks when inside cmux.

if [[ -n "$CMUX_SURFACE_ID" && "$CMUX_CLAUDE_HOOKS_DISABLED" != "1" ]]; then
    claude() {
        local real_claude
        real_claude="$(command -v claude)" || { echo "Error: claude not found" >&2; return 127; }

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
