# tmux_run: Execute shell commands in tmux panes and capture output
# py_repl: Execute Python code in tmux panes running Python REPLs
#
# Usage:
#   tmux_run <target> <shell_command>  # For shell commands
#   py_repl <target> <python_code>     # For Python REPLs
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
            tail -n +$((lines_printed + 1)) "$tmp" | head -n $((current_lines - lines_printed)) | grep -v "$SENT" || true
            lines_printed=$current_lines
        fi
        sleep 0.05
    done

    # Stop piping
    tmux pipe-pane -t "$target"

    # Print any remaining lines (excluding sentinel line)
    local total_lines=$(wc -l < "$tmp" | tr -d ' ')
    if [[ $total_lines -gt $lines_printed ]]; then
        tail -n +$((lines_printed + 1)) "$tmp" | grep -v "$SENT" || true
    fi

    # Handle exit status based on environment
    local exit_status=0
    if [[ ! "$current_cmd" =~ ^(python|ipython|node|nodejs) ]]; then
        # For shell, extract exit status
        exit_status=$(grep "$SENT" "$tmp" | sed "s/.*$SENT //" | grep -o '^[0-9]*' | head -1)
    fi

    rm -f "$tmp"
    return "$exit_status"
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
    
    # Wait for Python REPL to be ready
    local max_attempts=20  # 2 seconds max wait
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        # Check if Python prompt is ready by looking for '>>>'
        local pane_content=$(tmux capture-pane -t "$session_name" -p 2>/dev/null | tail -5)
        
        if echo "$pane_content" | grep -q '>>>'; then
            echo "Python session '$session_name' is ready"
            return 0
        fi
        
        sleep 0.05
        ((attempt++))
    done
    
    return 0  # Still return success since session was created
}
TMUX_RUN_DEBUG=0

# Description: Like tmux_run but for when there is a python repl running within the tmux session
# Usage: py_run <target> <python_code>
py_run() {
    local target=$1
    shift
    
    local tmp=$(mktemp)
    local SENT="__PY_DONE_$$"
    
    # Debug output only if TMUX_RUN_DEBUG is set
    if [ "$TMUX_RUN_DEBUG" = "1" ]; then
        echo "python code: $*" >&2
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
    
    # For Python REPL, decode and execute the base64 encoded code
    tmux send-keys -t "$target" "import base64" C-m
    tmux send-keys -t "$target" "try:" C-m
    tmux send-keys -t "$target" "    encoded_code = '$encoded_code'" C-m
    tmux send-keys -t "$target" "    code = base64.b64decode(encoded_code).decode('utf-8')" C-m
    tmux send-keys -t "$target" "    exec(code)" C-m
    tmux send-keys -t "$target" "except Exception as e:" C-m
    tmux send-keys -t "$target" "    import traceback; traceback.print_exc()" C-m
    tmux send-keys -t "$target" "finally:" C-m
    tmux send-keys -t "$target" "    print('$SENT')" C-m
    
    # Start piping after sending the structure but before executing
    tmux pipe-pane -o -t "$target" "cat >'$tmp'"
    
    # Empty line to complete compound statement and execute
    tmux send-keys -t "$target" "" C-m
    
    # Stream output while waiting for sentinel
    local lines_printed=1
    local sentinel_count=0
    local found_start=0
    
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
        
        # Print any new lines that have appeared
        local current_lines=$(wc -l < "$tmp" | tr -d ' ')
        if [[ $current_lines -gt $lines_printed ]]; then
            tail -n +$((lines_printed + 1)) "$tmp" | head -n $((current_lines - lines_printed)) | grep -v "$SENT" || true
            lines_printed=$current_lines
        fi
        sleep 0.05
    done
    
    # Stop piping
    tmux pipe-pane -t "$target"
    
    # Print any remaining lines (excluding sentinel line)
    local total_lines=$(wc -l < "$tmp" | tr -d ' ')
    if [[ $total_lines -gt $lines_printed ]]; then
        tail -n +$((lines_printed + 1)) "$tmp" | grep -v "$SENT" || true
    fi
    
    rm -f "$tmp"
    
    # Debug output only if TMUX_RUN_DEBUG is set
    if [ "$TMUX_RUN_DEBUG" = "1" ]; then
        echo "finished running python code on repl" >&2
    fi
    
    return 0
}
