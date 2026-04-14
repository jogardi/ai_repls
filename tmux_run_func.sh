# tmux_run: Execute shell commands in tmux panes and capture output
# py_run: Execute Python code in tmux panes running Python REPLs
# julia_run: Execute Julia code in tmux panes running Julia REPLs
#
# Usage:
#   tmux_run <target> <shell_command>   # For shell commands
#   py_run <target> <python_code>       # For Python REPLs
#   julia_run <target> <julia_code>     # For Julia REPLs
#
# Example with SSH and Python:
#   tmux new-session -d -s ssh_repl
#   tmux send-keys -t ssh_repl "ssh lattitude" C-m
#   tmux send-keys -t ssh_repl "python3" C-m
#   py_repl ssh_repl "print('hello, world!')"  # Use py_repl for Python

# TODO fix this case
#tmux_run calc_session "print('\\nhi')"
#Traceback (most recent call last):
#  File "<stdin>", line 2, in <module>
#  File "<string>", line 1
#    print('
#          ^
#SyntaxError: unterminated string literal (detected at line 1)

# there is testing of this code in test_tmux_run.sh


# Description: Like `tmux send-keys` but synchronous. Meaning it waits for the command to finish running while 
# `tmux send-keys` is asynchronous. It can be much more convenient since it 
# returns the output of the command and waits for the command to finish running.
# But don't use it to start an interactive command (e.g. a repl or ssh session).
# Usage: tmux_run <target> <command>
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    # bash
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [[ -n "${(%):-%x}" ]]; then
    # zsh
    SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
else
    # fallback - assume script is in the expected location
    SCRIPT_DIR="$HOME/Documents/workspace/ai_repls"
fi
source "$SCRIPT_DIR/advice.sh"

lazyqueue() {
    python3 "$SCRIPT_DIR/lazyqueue.py" "$@"
}


tmux_run() {
    local target=$1
    shift

    local tmp=$(mktemp)

    # Get the current command running in the pane
    local current_cmd=$(tmux display-message -p -t "$target" '#{pane_current_command}')
    
    local SENT="__TMUX_DONE_$$"
    
    # Detect what kind of environment we're in and send appropriate commands
    case "$current_cmd" in
        python*|ipython*)
            # For Python REPL, wrap exec in try/except to handle errors
            tmux send-keys -t "$target" "try:" C-m
            tmux send-keys -t "$target" "    exec('''$*''')" C-m
            tmux send-keys -t "$target" "except Exception as e:" C-m
            tmux send-keys -t "$target" "    import traceback; traceback.print_exc()" C-m
            tmux send-keys -t "$target" "finally:" C-m
            tmux send-keys -t "$target" "    print('$SENT')" C-m
            
            # Start piping after sending the structure but before executing
            tmux pipe-pane -o -t "$target" "cat >'$tmp'"
            
            tmux send-keys -t "$target" "" C-m  # Empty line to complete compound statement
            ;;
        node|nodejs)
            # For Node.js REPL
            tmux pipe-pane -o -t "$target" "cat >'$tmp'"
            tmux send-keys -t "$target" "$*" C-m
            tmux send-keys -t "$target" "console.log('$SENT')" C-m
            ;;
        *)
            # Default: assume shell
            tmux pipe-pane -o -t "$target" "cat >'$tmp'"
            tmux send-keys -t "$target" "$*; st=\$?; echo $SENT \$st" C-m
            ;;
    esac

    # Stream output while waiting for sentinel
    local lines_printed=0
    local sentinel_count=0
    # For Python, we only expect 1 sentinel since we start piping after sending the code
    local expected_sentinels=2
    if [[ "$current_cmd" =~ ^(python|ipython) ]]; then
        expected_sentinels=1
        # Skip the first line (empty line from completing the compound statement)
        lines_printed=1
    fi
    
    while [[ $sentinel_count -lt $expected_sentinels ]]; do 
        sentinel_count=$(grep -c "$SENT" "$tmp" 2>/dev/null || echo 0)
        sentinel_count=$(echo "$sentinel_count" | tr '\n' ' ' | awk '{print $NF}')
        
        # Validate sentinel_count is numeric
        if ! [[ "$sentinel_count" =~ ^[0-9]+$ ]]; then
            echo "tmux_run error: Unexpected output in tmux session. The session may have had pending input. Try again." >&2
            tmux pipe-pane -t "$target"
            rm -f "$tmp"
            return 1
        fi
        
        # Print any new lines that have appeared
        local current_lines=$(wc -l < "$tmp" | tr -d ' ')
        if [[ $current_lines -gt $lines_printed ]]; then
            tail -n +$((lines_printed + 1)) "$tmp" | head -n $((current_lines - lines_printed)) | perl -pe 's/\e\[[0-9;?]*[[:alpha:]]//g; s/\e[>=]//g; s/\r//g' | grep -Ev '^(\.\.\.|>>>)[[:space:]]' | grep -v "$SENT" || true
            lines_printed=$current_lines
        fi
        sleep 0.05
    done

    # Stop piping
    tmux pipe-pane -t "$target"

    # Print any remaining lines (excluding sentinel line)
    local total_lines=$(wc -l < "$tmp" | tr -d ' ')
    if [[ $total_lines -gt $lines_printed ]]; then
        tail -n +$((lines_printed + 1)) "$tmp" | perl -pe 's/\e\[[0-9;?]*[[:alpha:]]//g; s/\e[>=]//g; s/\r//g' | grep -Ev '^(\.\.\.|>>>)[[:space:]]' | grep -v "$SENT" || true
    fi

    # Handle exit status based on environment
    local exit_status=0
    if [[ ! "$current_cmd" =~ ^(python|ipython|node|nodejs) ]]; then
        # For shell, extract exit status
        exit_status=$(grep "$SENT" "$tmp" | sed "s/.*$SENT //" | grep -o '^[0-9]*' | head -1)
    fi

    rm -f "$tmp" "${wrapper_file:-}"
    return "$exit_status"
}

_wait_for_python_prompt() {
    local target=$1
    local timeout_seconds=${2:-10}
    local max_attempts=$((timeout_seconds * 20))
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        local pane_content
        pane_content=$(tmux capture-pane -t "$target" -p -S -30 2>/dev/null || true)
        local last_nonempty_line
        last_nonempty_line=$(echo "$pane_content" | sed '/^[[:space:]]*$/d' | tail -1)

        if echo "$last_nonempty_line" | grep -Eq '^[[:space:]]*>>>[[:space:]]*$'; then
            return 0
        fi

        sleep 0.05
        ((attempt++))
    done

    return 1
}

# Description: Creates a tmux session with a Python REPL. This is helpful 
# since tmux_run doesn't work launching an interactive commands and python repl is an interactive command.
# If the tmux session with the given name already exists, it will start a python repl in that session. Otherwise, it will create a new session.
# Usage: start_tmux_repl <session_name> [python_command]
start_tmux_repl() {
    local session_name=$1
    local python_cmd=${2:-python3}  # Default to python3 if not specified
    
    if [ -z "$session_name" ]; then
        echo "Error: Session name required" >&2
        echo "Usage: tmux_python_session <session_name> [python_command]" >&2
        return 1
    fi
    
    # Check if session already exists
    if tmux has-session -t "$session_name" 2>/dev/null; then
        echo "Using existing session '$session_name'"
        # Check if Python is already running in the session
        local current_cmd=$(tmux display-message -p -t "$session_name" '#{pane_current_command}')
        if [[ "$current_cmd" =~ ^(python|ipython) ]]; then
            echo "Python REPL already running in session '$session_name'"
            return 0
        else
            # Start Python in the existing session
            tmux send-keys -t "$session_name" "$python_cmd" C-m
        fi
    else
        # Create new session and start Python
        tmux new-session -d -s "$session_name"
        tmux send-keys -t "$session_name" "$python_cmd" C-m
        echo "Created new session '$session_name'"
    fi
    
    if _wait_for_python_prompt "$session_name" 30; then
        echo "Python session '$session_name' is ready"
        return 0
    fi

    echo "Error: Python prompt not ready in session '$session_name' after 30s" >&2
    return 1
}
TMUX_RUN_DEBUG=0

# Description: Like tmux_run but for when there is a python repl running within the tmux session
# Usage: py_run <target> <python_code>
py_run() {
    local target=$1
    shift
    
    local tmp=$(mktemp)
    local START_MARKER="__PY_START_$$"
    local SENT="__PY_DONE_$$"
    
    # Debug output only if TMUX_RUN_DEBUG is set
    if [ "${TMUX_RUN_DEBUG:-0}" = "1" ]; then
        echo "python code: $*" >&2
    fi

    if ! _wait_for_python_prompt "$target" 10; then
        echo "py_run error: Python prompt is not ready in tmux target '$target'" >&2
        return 1
    fi
    
    # Base64 encode the Python code to avoid any escaping issues. Ensure the
    # encoded string does not contain newlines because GNU coreutils' `base64`
    # inserts line-wraps by default which breaks the single-line string we send
    # to the Python REPL. Strip any newlines to make the output consistent
    # across platforms (macOS, Linux, etc.).
    local encoded_code=$(printf '%s' "$*" | base64 | tr -d '\n')
    
    # # Clear the scrollback buffer to ensure clean output
    # tmux send-keys -t "$target" C-l
    
    # # Send a marker before our actual command to help identify where output starts
    # local START_MARKER="__PY_START_$$"
    # tmux send-keys -t "$target" "print('$START_MARKER')" C-m
    # sleep 0.1  # Give time for the marker to be printed
    
    # Build and send a wrapper script as base64 to avoid local temp file paths.
    # This keeps execution in-band within the active REPL process, so it works
    # for REPLs running over SSH inside tmux.
    local wrapper_code
    wrapper_code=$(cat <<PY
import base64, traceback, sys
encoded_code = "$encoded_code"
user_code = base64.b64decode(encoded_code).decode('utf-8')
_py_run_old_ps1 = getattr(sys, 'ps1', None)
_py_run_old_ps2 = getattr(sys, 'ps2', None)
try:
    if hasattr(sys, 'ps1'):
        sys.ps1 = ''
    if hasattr(sys, 'ps2'):
        sys.ps2 = ''
    print("$START_MARKER")
    exec(user_code, globals(), locals())
except Exception:
    traceback.print_exc()
finally:
    if _py_run_old_ps1 is not None:
        sys.ps1 = _py_run_old_ps1
    elif hasattr(sys, 'ps1'):
        del sys.ps1
    if _py_run_old_ps2 is not None:
        sys.ps2 = _py_run_old_ps2
    elif hasattr(sys, 'ps2'):
        del sys.ps2
    print("$SENT")
PY
)
    local encoded_wrapper=$(printf '%s' "$wrapper_code" | base64 | tr -d '\n')
    
    local wrapper_exec_cmd="import base64; exec(compile(base64.b64decode('$encoded_wrapper').decode('utf-8'), '<py_run_wrapper>', 'exec'))"
    
    # Type the command before enabling piping so command echo is not captured.
    tmux send-keys -t "$target" "$wrapper_exec_cmd"
    tmux pipe-pane -o -t "$target" "cat >'$tmp'"
    tmux send-keys -t "$target" C-m
    
    # Wait for sentinel
    local sentinel_count=0
    while [[ $sentinel_count -lt 1 ]]; do 
        sentinel_count=$(grep -c "$SENT" "$tmp" 2>/dev/null || echo 0)
        sentinel_count=$(echo "$sentinel_count" | tr '\n' ' ' | awk '{print $NF}')
        
        # Validate sentinel_count is numeric
        if ! [[ "$sentinel_count" =~ ^[0-9]+$ ]]; then
            echo "py_repl error: Unexpected output. The REPL may have had pending input. Try again." >&2
            tmux pipe-pane -t "$target"
            rm -f "$tmp"
            return 1
        fi
        
        sleep 0.05
    done
    
    # Stop piping
    tmux pipe-pane -t "$target"
    
    # Keep only content between explicit start/end markers and strip REPL noise.
    perl -pe 's/\e\[1@.//g; s/\e\[[0-9;?]*[@[:alpha:]]//g; s/\e[>=]//g; s/\r//g' "$tmp" \
        | awk -v start="$START_MARKER" -v sent="$SENT" '
            $0 ~ start {capture=1; next}
            $0 ~ sent {exit}
            capture && $0 !~ /^(\.{3}|>>>)[[:space:]]/ {print}
        ' || true
    
    rm -f "$tmp"
    
    # Debug output only if TMUX_RUN_DEBUG is set
    if [ "${TMUX_RUN_DEBUG:-0}" = "1" ]; then
        echo "finished running python code on repl" >&2
    fi
    
    return 0
}

# Description: Like tmux_run but for when there is a julia repl running within the tmux session
# Usage: julia_run <target> <julia_code>
julia_run() {
    local target=$1
    shift
    
    local tmp=$(mktemp)
    local completion_file=$(mktemp)
    
    # Debug output only if TMUX_RUN_DEBUG is set
    if [ "$TMUX_RUN_DEBUG" = "1" ]; then
        echo "julia code: $*" >&2
        echo "completion file: $completion_file" >&2
    fi
    
    # Base64 encode the Julia code to avoid any escaping issues. Ensure the
    # encoded string does not contain newlines because GNU coreutils' `base64`
    # inserts line-wraps by default which breaks the single-line string we send
    # to the Julia REPL. Strip any newlines to make the output consistent
    # across platforms (macOS, Linux, etc.).
    local encoded_code=$(printf '%s' "$*" | base64 | tr -d '\n')
    
    # For Julia REPL, decode and execute the base64 encoded code, then write completion marker to file
    tmux send-keys -t "$target" "try" C-m
    tmux send-keys -t "$target" "    import Base64" C-m
    tmux send-keys -t "$target" "    encoded_code = \"$encoded_code\"" C-m
    tmux send-keys -t "$target" "    code = String(Base64.base64decode(encoded_code))" C-m
    tmux send-keys -t "$target" "    eval(Meta.parse(code))" C-m
    tmux send-keys -t "$target" "catch e" C-m
    tmux send-keys -t "$target" "    println(\"Error: \", e)" C-m
    tmux send-keys -t "$target" "    showerror(stdout, e, catch_backtrace())" C-m
    tmux send-keys -t "$target" "finally" C-m
    tmux send-keys -t "$target" "    open(\"$completion_file\", \"w\") do f; write(f, \"DONE\"); end end"
    # tmux send-keys -t "$target" "end" C-m
    
    # Start piping after sending the structure but before executing
    tmux pipe-pane -o -t "$target" "cat >'$tmp'"
    
    # # Execute the try block
    tmux send-keys -t "$target" "" C-m
    
    # Stream output while waiting for completion file
    local lines_printed=10
    
    while [[ ! -f "$completion_file" || ! -s "$completion_file" ]]; do 
        # Print any new lines that have appeared
        local current_lines=$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')
        if [[ $current_lines -gt $lines_printed ]]; then
            tail -n +$((lines_printed + 1)) "$tmp" | head -n $((current_lines - lines_printed)) 2>/dev/null || true
            lines_printed=$current_lines
        fi
        sleep 0.05
    done
    
    # Stop piping
    tmux pipe-pane -t "$target"
    
    # Print any remaining lines
    local total_lines=$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')
    if [[ $total_lines -gt $lines_printed ]]; then
        tail -n +$((lines_printed + 1)) "$tmp" 2>/dev/null || true
    fi
    
    # Clean up
    rm -f "$tmp" "$completion_file"
    
    # Debug output only if TMUX_RUN_DEBUG is set
    if [ "$TMUX_RUN_DEBUG" = "1" ]; then
        echo "finished running julia code on repl" >&2
    fi
    
    return 0
}

search_symbol() {
   if [ $# -lt 2 ]; then
        echo "Usage: search_symbol <symbol> <file_or_directory> [additional_grep_options]"
        echo "Example: search_symbol my_variable src/"
        echo "Example: search_symbol user_name *.py -n"
        return 1
    fi

    local symbol="$1"
    shift  # Remove first argument, rest are files/options

    # Convert symbol to regex pattern
    # Replace underscores with _? (optional underscore)
    # Add word boundaries and case-insensitive flag
    local pattern=$(echo "$symbol" | sed 's/_/_?/g')
    pattern="\\b${pattern}\\b"

    # Use grep with extended regex and case-insensitive
    grep -iE "$pattern" "$@"
}

# Description: Wait for the active pane in a tmux target to return to an interactive shell.
# Useful after sending an async command via `tmux send-keys` to block until it finishes.
# Usage: twait <tmux-target> [poll_seconds]
twait() {
    if [[ "${1-}" == "-h" || "${1-}" == "--help" || $# -lt 1 || $# -gt 2 ]]; then
        echo "Usage: twait <tmux-target> [poll_seconds]" >&2
        echo "Wait for the active pane in <tmux-target> to return to an interactive shell." >&2
        [[ $# -ge 1 && $# -le 2 ]] || return 2
    fi

    local target="$1"
    local poll_seconds="${2:-1}"
    local signal_root="${TWAIT_SIGNAL_DIR:-$HOME/.expand/tmp/twait-codex-signals}"
    local waiters_dir="$signal_root/waiters"

    if ! [[ "$poll_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "poll_seconds must be a non-negative number, got: $poll_seconds" >&2
        return 2
    fi

    _twait_find_active_pane() {
        local target_name="$1"
        local pane_rows pane

        if ! pane_rows="$(tmux list-panes -t "$target_name" -F '#{pane_id} #{pane_active}' 2>/dev/null)"; then
            return 1
        fi

        pane="$(awk '$2 == "1" { print $1; exit }' <<<"$pane_rows")"
        if [[ -z "$pane" ]]; then
            pane="$(awk 'NR == 1 { print $1; exit }' <<<"$pane_rows")"
        fi

        [[ -n "$pane" ]] || return 1
        printf '%s\n' "$pane"
    }

    _twait_get_pane_state() {
        local pane="$1"
        local state

        if ! state="$(tmux list-panes -t "$pane" -F '#{pane_dead} #{pane_current_command} #{pane_dead_status}' 2>/dev/null | head -n1)"; then
            return 1
        fi

        [[ -n "$state" ]] || return 1
        printf '%s\n' "$state"
    }

    _twait_is_codex_running_in_pane() {
        local pane="$1"
        local initial_cmd="$2"
        local pane_start_cmd="$3"
        local pane_tty processes

        case "$initial_cmd" in
            codex|codex.exe)
                return 0 ;;
        esac

        if [[ "$pane_start_cmd" == codex* || "$pane_start_cmd" == */codex* ]]; then
            return 0
        fi

        if [[ "$initial_cmd" != "node" ]]; then
            return 1
        fi

        pane_tty="$(tmux display-message -p -t "$pane" '#{pane_tty}' 2>/dev/null || true)"
        if [[ -z "$pane_tty" ]]; then
            return 1
        fi

        if ! processes="$(ps -o command= -t "$pane_tty" 2>/dev/null)"; then
            return 1
        fi

        if grep -Eq '[@]openai\+codex|/codex/bin/codex\.js|/codex/vendor/.*/codex/codex' <<<"$processes"; then
            return 0
        fi

        return 1
    }

    _twait_codex_appears_idle() {
        local pane="$1"
        local pane_content nonempty_lines recent_nonempty last_nonempty

        pane_content="$(tmux capture-pane -pt "$pane" -S -400 2>/dev/null)"
        if [[ -z "$pane_content" ]]; then
            return 1
        fi

        nonempty_lines="$(sed '/^[[:space:]]*$/d' <<<"$pane_content")"
        if [[ -z "$nonempty_lines" ]]; then
            return 1
        fi

        recent_nonempty="$(tail -n 25 <<<"$nonempty_lines")"

        # Active Codex turns render an interrupt hint in the recent footer area.
        # Treat those panes as busy even though they also show the composer prompt
        # and model status footer that idle panes have.
        if grep -Eq 'esc to interrupt' <<<"$recent_nonempty"; then
            return 1
        fi

        # Idle Codex panes typically show a composer prompt line ("› ...")
        # and end with the model/rate status line ("... · NN% left · ...").
        if ! grep -Eq '^[[:space:]]*›[[:space:]].+' <<<"$recent_nonempty"; then
            return 1
        fi

        last_nonempty="$(tail -n1 <<<"$nonempty_lines")"
        if [[ -z "$last_nonempty" ]]; then
            return 1
        fi

        if grep -Eq '·[[:space:]]+[0-9]+% left[[:space:]]+·' <<<"$last_nonempty"; then
            return 0
        fi

        return 1
    }

    local pane_id
    if ! pane_id="$(_twait_find_active_pane "$target")"; then
        echo "tmux target not found or has no panes: $target" >&2
        return 1
    fi

    local codex_waiter_file=""
    local codex_done_file=""
    local codex_thread_waiter_file=""
    local codex_thread_done_file=""
    local codex_waiter_active=0

    _twait_cleanup_codex_waiter() {
        if [[ "$codex_waiter_active" != "1" ]]; then
            return 0
        fi

        rm -f "$codex_waiter_file" "$codex_done_file"
        rm -f "$codex_thread_waiter_file" "$codex_thread_done_file"
        codex_waiter_active=0
    }

    _twait_extract_codex_thread_id() {
        local pane="$1"
        local pane_content thread_id

        pane_content="$(tmux capture-pane -pt "$pane" -S -200 2>/dev/null || true)"
        if [[ -z "$pane_content" ]]; then
            return 1
        fi

        thread_id="$(sed -nE 's/.*session id:[[:space:]]*([0-9a-fA-F-]{20,}).*/\1/p' <<<"$pane_content" | tail -n1)"
        if [[ -z "$thread_id" ]]; then
            return 1
        fi

        printf '%s\n' "$thread_id"
    }

    _twait_register_codex_thread_waiter() {
        local pane="$1"
        local thread_id nonce

        if [[ -n "$codex_thread_waiter_file" ]]; then
            return 0
        fi

        if ! thread_id="$(_twait_extract_codex_thread_id "$pane")"; then
            return 1
        fi

        nonce="$(date +%s)_${RANDOM:-0}_$$"
        codex_thread_waiter_file="$waiters_dir/thread-${thread_id}.${nonce}.wait"
        codex_thread_done_file="$waiters_dir/thread-${thread_id}.${nonce}.done"

        if ! : > "$codex_thread_waiter_file"; then
            echo "Failed to create codex thread waiter marker: $codex_thread_waiter_file" >&2
            return 1
        fi

        return 0
    }

    _twait_register_codex_waiter() {
        local pane="$1"
        local pane_key nonce
        pane_key="${pane#%}"

        if ! [[ "$pane_key" =~ ^[0-9]+$ ]]; then
            echo "Invalid tmux pane id for codex waiter registration: $pane" >&2
            return 1
        fi

        if ! mkdir -p "$waiters_dir"; then
            echo "Failed to create twait signal directory: $waiters_dir" >&2
            return 1
        fi

        nonce="$(date +%s)_${RANDOM:-0}_$$"
        codex_waiter_file="$waiters_dir/${pane_key}.${nonce}.wait"
        codex_done_file="$waiters_dir/${pane_key}.${nonce}.done"

        if ! : > "$codex_waiter_file"; then
            echo "Failed to create codex waiter marker: $codex_waiter_file" >&2
            return 1
        fi

        codex_waiter_active=1
    }

    local default_shell env_shell default_shell_name env_shell_name
    default_shell="$(tmux show-options -gqv default-shell 2>/dev/null || true)"
    env_shell="${SHELL:-}"
    default_shell_name="$(basename "${default_shell%% *}")"
    env_shell_name="$(basename "${env_shell%% *}")"

    _twait_is_shell_command() {
        local cmd="$1"
        case "$cmd" in
            "$default_shell_name"|"$env_shell_name"|bash|zsh|sh|dash|ksh|fish|tcsh|csh|nu)
                return 0 ;;
            *)
                return 1 ;;
        esac
    }

    local initial_state initial_dead initial_command
    if ! initial_state="$(_twait_get_pane_state "$pane_id")"; then
        echo "Pane $pane_id no longer exists." >&2
        return 1
    fi
    read -r initial_dead initial_command _ <<<"$initial_state"

    if [[ "$initial_dead" == "1" ]]; then
        echo "Pane $pane_id is already dead; no running command to wait for." >&2
        return 0
    fi

    if _twait_is_shell_command "$initial_command"; then
        echo "No foreground command is running in pane $pane_id." >&2
        return 0
    fi

    local pane_start_command=""
    pane_start_command="$(tmux display-message -p -t "$pane_id" '#{pane_start_command}' 2>/dev/null || true)"

    if _twait_is_codex_running_in_pane "$pane_id" "$initial_command" "$pane_start_command"; then
        # If Codex is interactive but currently idle, there is no turn to wait for.
        if _twait_codex_appears_idle "$pane_id"; then
            sleep 0.4
            if _twait_codex_appears_idle "$pane_id"; then
                echo "No active Codex turn is running in pane $pane_id." >&2
                return 0
            fi
        fi

        if ! _twait_register_codex_waiter "$pane_id"; then
            return 1
        fi

        # Best effort: register a thread-id keyed waiter so notify hooks can
        # release twait even if TMUX_PANE is not present in notify env.
        _twait_register_codex_thread_waiter "$pane_id" || true
    fi

    local current_state pane_dead current_command pane_dead_status
    while true; do
        if [[ "$codex_waiter_active" == "1" && ( -f "$codex_done_file" || ( -n "$codex_thread_done_file" && -f "$codex_thread_done_file" ) ) ]]; then
            echo "Codex turn completion signal received for pane $pane_id."
            break
        fi

        if [[ "$codex_waiter_active" == "1" && -z "$codex_thread_waiter_file" ]]; then
            _twait_register_codex_thread_waiter "$pane_id" || true
        fi

        if ! current_state="$(_twait_get_pane_state "$pane_id")"; then
            _twait_cleanup_codex_waiter
            echo "Pane $pane_id no longer exists while waiting for '$initial_command'." >&2
            return 1
        fi
        read -r pane_dead current_command pane_dead_status <<<"$current_state"

        if [[ "$pane_dead" == "1" ]]; then
            echo "Command '$initial_command' finished in pane $pane_id (dead pane, status ${pane_dead_status:-unknown})."
            break
        fi

        if _twait_is_shell_command "$current_command"; then
            echo "Command '$initial_command' finished in pane $pane_id."
            break
        fi

        sleep "$poll_seconds"
    done

    _twait_cleanup_codex_waiter
}

_codex_exec_fork_find_new_session_id() {
    if [[ $# -ne 3 ]]; then
        echo "Usage: _codex_exec_fork_find_new_session_id <sessions_dir> <original_session_id> <marker_file>" >&2
        return 2
    fi

    local sessions_dir="$1"
    local original_session_id="$2"
    local marker_file="$3"

    python3 - "$sessions_dir" "$original_session_id" "$marker_file" <<'PY'
import json
import sys
from datetime import datetime
from pathlib import Path

try:
    sessions_dir = Path(sys.argv[1]).expanduser()
    original_session_id = sys.argv[2]
    marker_file = Path(sys.argv[3])

    marker_ns = marker_file.stat().st_mtime_ns
    candidates = []
    for path in sessions_dir.rglob("rollout-*.jsonl"):
        try:
            with path.open() as handle:
                first_line = handle.readline()
            if first_line == "":
                continue
            record = json.loads(first_line)
        except (OSError, json.JSONDecodeError):
            # A rollout file can appear before the first JSONL line is fully flushed.
            continue

        if record["type"] != "session_meta":
            continue

        payload = record["payload"]
        record_ns = int(datetime.fromisoformat(payload["timestamp"].replace("Z", "+00:00")).timestamp() * 1_000_000_000)
        if record_ns <= marker_ns:
            continue

        candidates.append((record_ns, payload["id"], payload))

    candidates.sort(key=lambda item: item[0])

    for _, _, payload in candidates:
        if payload.get("forked_from_id") != original_session_id:
            continue

        print(payload["id"])
        raise SystemExit(0)

    raise SystemExit(1)
except SystemExit:
    raise
except Exception as exc:
    print(f"_codex_exec_fork_find_new_session_id failed: {exc}", file=sys.stderr)
    raise SystemExit(2)
PY
}

_codex_exec_fork_launch_in_pty() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: _codex_exec_fork_launch_in_pty <original_session_id>" >&2
        return 2
    fi

    local original_session_id="$1"
    if ! command -v tmux >/dev/null 2>&1; then
        echo "\`tmux\` is required to launch codex fork in a PTY." >&2
        return 1
    fi

    local session_name="codex_exec_fork_${RANDOM:-0}_${RANDOM:-0}_$$"
    if ! tmux new-session -d -s "$session_name"; then
        echo "Failed to create tmux session $session_name for codex fork." >&2
        return 1
    fi

    local fork_cmd
    fork_cmd="$(python3 - "$PWD" "$original_session_id" <<'PY'
import shlex
import sys

cwd, session_id = sys.argv[1:3]
print(f"cd {shlex.quote(cwd)} && codex fork {shlex.quote(session_id)}")
PY
)"
    tmux send-keys -t "$session_name" "$fork_cmd" C-m
    printf '%s\n' "$session_name"
}

_codex_exec_fork_stop_pty_launcher() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: _codex_exec_fork_stop_pty_launcher <launcher_session_name>" >&2
        return 2
    fi

    local launcher_session_name="$1"
    tmux kill-session -t "$launcher_session_name" 2>/dev/null || true
}

_codex_exec_fork_capture_pty_output() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: _codex_exec_fork_capture_pty_output <launcher_session_name>" >&2
        return 2
    fi

    local launcher_session_name="$1"
    tmux capture-pane -pt "$launcher_session_name" -S -200 2>/dev/null || true
}

_codex_exec_fork_pty_has_returned_to_shell() {
    if [[ $# -ne 1 ]]; then
        echo "Usage: _codex_exec_fork_pty_has_returned_to_shell <launcher_session_name>" >&2
        return 2
    fi

    local launcher_session_name="$1"
    local current_cmd
    current_cmd="$(tmux display-message -p -t "$launcher_session_name" '#{pane_current_command}' 2>/dev/null || true)"

    case "$current_cmd" in
        bash|zsh|sh|dash|ksh|fish|tcsh|csh|nu)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# Description: Mimic the missing non-interactive `codex exec fork` flow by
# creating the fork via an interactive PTY first, then resuming it with
# `codex exec resume --json`.
# Usage: codex_exec_fork <session_id> [prompt]
codex_exec_fork() {
    if [[ "${1-}" == "-h" || "${1-}" == "--help" || $# -lt 1 || $# -gt 2 ]]; then
        echo "Usage: codex_exec_fork <session_id> [prompt]" >&2
        echo "Fork a Codex session through a PTY, then continue via \`codex exec resume --json\`." >&2
        [[ $# -ge 1 && $# -le 2 ]] || return 2
    fi

    local original_session_id="$1"
    local prompt="${2-}"
    local sessions_dir="${CODEX_HOME:-$HOME/.codex}/sessions"
    local timeout_seconds="${CODEX_EXEC_FORK_TIMEOUT_SECONDS:-15}"

    if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || [[ "$timeout_seconds" -le 0 ]]; then
        echo "CODEX_EXEC_FORK_TIMEOUT_SECONDS must be a positive integer, got: $timeout_seconds" >&2
        return 2
    fi

    if ! command -v codex >/dev/null 2>&1; then
        echo "\`codex\` command not found in PATH." >&2
        return 1
    fi

    if ! [[ -d "$sessions_dir" ]]; then
        echo "Codex sessions directory not found: $sessions_dir" >&2
        return 1
    fi

    local marker_file
    marker_file="$(mktemp)"
    local find_output_file
    find_output_file="$(mktemp)"
    local launcher_session_name
    if ! launcher_session_name="$(_codex_exec_fork_launch_in_pty "$original_session_id")"; then
        rm -f "$marker_file" "$find_output_file"
        return 1
    fi

    local new_session_id=""
    local find_status=1
    local attempts=$((timeout_seconds * 10))
    local saw_non_shell_command=0
    while [[ "$attempts" -gt 0 ]]; do
        _codex_exec_fork_find_new_session_id "$sessions_dir" "$original_session_id" "$marker_file" >"$find_output_file"
        find_status=$?
        if [[ "$find_status" -eq 0 ]]; then
            new_session_id="$(<"$find_output_file")"
            break
        fi

        if [[ "$find_status" -ne 1 ]]; then
            _codex_exec_fork_capture_pty_output "$launcher_session_name" | tail -n 40 >&2
            _codex_exec_fork_stop_pty_launcher "$launcher_session_name"
            rm -f "$marker_file" "$find_output_file"
            return "$find_status"
        fi

        if ! tmux has-session -t "$launcher_session_name" 2>/dev/null; then
            _codex_exec_fork_find_new_session_id "$sessions_dir" "$original_session_id" "$marker_file" >"$find_output_file"
            find_status=$?
            if [[ "$find_status" -eq 0 ]]; then
                new_session_id="$(<"$find_output_file")"
                break
            fi

            rm -f "$marker_file" "$find_output_file"
            echo "codex fork tmux session disappeared before creating a forked session for $original_session_id." >&2
            return 1
        fi

        if _codex_exec_fork_pty_has_returned_to_shell "$launcher_session_name"; then
            if [[ "$saw_non_shell_command" -ne 1 ]]; then
                sleep 0.1
                attempts=$((attempts - 1))
                continue
            fi

            _codex_exec_fork_find_new_session_id "$sessions_dir" "$original_session_id" "$marker_file" >"$find_output_file"
            find_status=$?
            if [[ "$find_status" -eq 0 ]]; then
                new_session_id="$(<"$find_output_file")"
                break
            fi

            _codex_exec_fork_capture_pty_output "$launcher_session_name" | tail -n 40 >&2
            _codex_exec_fork_stop_pty_launcher "$launcher_session_name"
            rm -f "$marker_file" "$find_output_file"
            echo "codex fork returned to the shell before creating a forked session for $original_session_id." >&2
            return 1
        fi

        saw_non_shell_command=1

        sleep 0.1
        attempts=$((attempts - 1))
    done

    _codex_exec_fork_stop_pty_launcher "$launcher_session_name"
    rm -f "$marker_file" "$find_output_file"

    if [[ -z "$new_session_id" ]]; then
        echo "Timed out waiting for a forked session rollout from $original_session_id." >&2
        return 1
    fi

    local -a resume_cmd=(codex exec resume --skip-git-repo-check --json "$new_session_id")
    if [[ $# -eq 2 ]]; then
        resume_cmd+=("$prompt")
    fi
    "${resume_cmd[@]}"
}

_agent_memory_watch_session_name() {
    printf '%s\n' "${AGENT_MEMORY_WATCH_SESSION:-agent-memory-mgrep}"
}

_agent_memory_root_dir() {
    python3 - "${AGENT_MEMORY_ROOT:-$HOME/agent-mems/mems}" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).expanduser().resolve())
PY
}

_agent_memory_start_watch_session() {
    if [[ $# -ne 2 ]]; then
        echo "Usage: _agent_memory_start_watch_session <tmux-session> <root-dir>" >&2
        return 2
    fi

    local session_name="$1"
    local root_dir="$2"
    local quoted_root
    quoted_root="$(printf '%q' "$root_dir")"
    local watch_cmd="cd $quoted_root && exec mgrep watch"

    if tmux has-session -t "$session_name" 2>/dev/null; then
        tmux send-keys -t "$session_name" C-c
        tmux send-keys -t "$session_name" "$watch_cmd" C-m
    else
        tmux new-session -d -s "$session_name" "$watch_cmd"
    fi
}

_agent_memory_ensure_watcher() {
    local root_dir
    root_dir="$(_agent_memory_root_dir)"
    local session_name
    session_name="$(_agent_memory_watch_session_name)"

    mkdir -p "$root_dir" || {
        echo "Failed to create agent memory root: $root_dir" >&2
        return 1
    }

    if ! command -v tmux >/dev/null 2>&1; then
        echo "\`tmux\` is required for agent-memory." >&2
        return 1
    fi
    if ! command -v mgrep >/dev/null 2>&1; then
        echo "\`mgrep\` is required for agent-memory." >&2
        return 1
    fi

    if tmux has-session -t "$session_name" 2>/dev/null; then
        local current_cmd current_path pane_start_command
        current_cmd="$(tmux display-message -p -t "$session_name" '#{pane_current_command}' 2>/dev/null || true)"
        current_path="$(tmux display-message -p -t "$session_name" '#{pane_current_path}' 2>/dev/null || true)"
        pane_start_command="$(tmux display-message -p -t "$session_name" '#{pane_start_command}' 2>/dev/null || true)"
        if [[ "$current_path" == "$root_dir" ]] && { [[ "$current_cmd" == "mgrep" ]] || [[ "$pane_start_command" == *"mgrep watch"* ]]; }; then
            return 0
        fi
    fi

    _agent_memory_start_watch_session "$session_name" "$root_dir" || return 1
    sleep 1

    local started_cmd started_path started_start_command
    started_cmd="$(tmux display-message -p -t "$session_name" '#{pane_current_command}' 2>/dev/null || true)"
    started_path="$(tmux display-message -p -t "$session_name" '#{pane_current_path}' 2>/dev/null || true)"
    started_start_command="$(tmux display-message -p -t "$session_name" '#{pane_start_command}' 2>/dev/null || true)"
    if [[ "$started_path" == "$root_dir" ]] && { [[ "$started_cmd" == "mgrep" ]] || [[ "$started_start_command" == *"mgrep watch"* ]]; }; then
        return 0
    fi

    echo "agent-memory watcher session '$session_name' failed to start mgrep watch in $root_dir" >&2
    tmux capture-pane -pt "$session_name" -S -40 >&2 || true
    return 1
}

agent-memory() {
    if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then
        python3 "$SCRIPT_DIR/agent_memory.py" --help
        return $?
    fi

    _agent_memory_ensure_watcher || return 1
    AGENT_MEMORY_ROOT="$(_agent_memory_root_dir)" \
    CODEX_THREAD_ID="${CODEX_THREAD_ID-}" \
    python3 "$SCRIPT_DIR/agent_memory.py" "$@"
}
