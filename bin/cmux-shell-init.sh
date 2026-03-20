#!/usr/bin/env bash
# cmux shell integration — source this from .bashrc or via --rcfile.
#
# Sets up:
#   1. Process history tracking (DEBUG trap → report_process socket command)
#   2. PATH prepend so bin/claude wrapper is found before the real binary
#
# The claude wrapper (bin/claude) handles hook injection separately —
# no bash function needed.

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
