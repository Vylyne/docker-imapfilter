#!/usr/bin/env sh

vcs_token() {
    if [ -n "$GIT_TOKEN_RAW" ]; then
        # NEW: Clean the token variable
        echo "$GIT_TOKEN_RAW" | tr -d '[:space:]'
        return
    fi

    if [ -n "$GIT_TOKEN" ]; then
        # NEW: Read the secret file, pipe to tr to strip ALL whitespace (including newlines)
        cat "${GIT_TOKEN}" | tr -d '[:space:]'
        return
    fi

    return 1
}

vcs_uri() {
    s="https://" # Default protocol prefix

    # 1. Add Auth details to $s: [https://] + [user:token@]
    if [ -n "$GIT_USER" ]; then
        # Clean GIT_USER of any possible whitespace before adding to URI and append it to 's'.
        s="${s}$(echo "$GIT_USER" | tr -d '[:space:]'):"
    fi

    # Token is cleaned here (in vcs_token)
    token="$(vcs_token)"
    if [ -n "$token" ]; then
        s="${s}${token}@"
    fi

    # 2. Strip protocol from $GIT_TARGET if one exists
    local target_clean="$GIT_TARGET"
    
    # Check if $GIT_TARGET starts with any protocol followed by '://'
    case "$GIT_TARGET" in
        *://*)
            # Remove the protocol prefix from the target
            target_clean="${GIT_TARGET#*://}"
            ;;
    esac

    # 3. Final URI is returned
    # [https://user:token@] + [clean target]
    echo "${s}${target_clean}"
}

config_in_vcs() {
    [ -n "$(vcs_token)" ] && [ -n "$GIT_TARGET" ]
}

config_target_base="${IMAPFILTER_CONFIG_BASE:-/opt/imapfilter/config}"
config_target="${IMAPFILTER_CONFIG}"

# If config_target is an absolute path strip the base.
# Originally IMAPFILTER_CONFIG was allowed to be absolute and relative,
# this handles the former absolute path (as long as
# IMAPFILTER_CONFIG_BASE is correctly used).
case "$config_target" in
    (/*) config_target="${config_target#${config_target_base}/}";;
esac

pull_config() {
    config_in_vcs || return 1 # No VCS setup, no change.
    
    local vcs_url="$(vcs_uri)"
    local pull_output # Variable to hold Git output
    local pull_status # Variable to hold Git exit code

    printf ">>> INFO: Checking for config updates...\n" >&2
    
    # 1. Attempt pull, capturing all output (STDOUT and STDERR)
    pull_output=$(git -C "$config_target_base" pull --ff-only --verbose "$vcs_url" 2>&1)
    pull_status=$?

    if [ "$pull_status" -eq 0 ]; then
        # Git command succeeded (exit code 0). Now check *why* it succeeded.
        
        # Check if the output contains "Already up to date."
        if echo "$pull_output" | grep -q "Already up to date."; then
            printf ">>> INFO: Config is already up to date.\n" >&2
            return 1 # Success, but NO CHANGE (loop_daemon will ignore)
        else
            printf ">>> INFO: Configuration changes applied. Output:\n%s\n" "$pull_output" >&2
            return 0 # Success, CHANGE APPLIED (loop_daemon will restart)
        fi
    else
        # 2. Pull failed (non-zero exit code), print error
        printf ">>> ERROR: Configuration pull failed! Output:\n%s\n" "$pull_output" >&2
        
        # 3. Try initial clone if it's not a git repo
        if ! [ -d "$config_target_base/.git" ]; then
            printf ">>> INFO: Directory is not a git repo. Attempting initial clone...\n" >&2
            
            local clone_output=$(git clone --verbose "$vcs_url" "$config_target_base" 2>&1)
            local clone_status=$?

            if [ "$clone_status" -eq 0 ]; then
                printf ">>> INFO: Initial clone succeeded. Output:\n%s\n" "$clone_output" >&2
                return 0 # Initial clone counts as an update
            else
                printf ">>> FATAL: Initial clone failed! Check credentials, URL, and permissions. Output:\n%s\n" "$clone_output" >&2
                exit 1 # Fatal error, terminate container
            fi
        fi
        
        return 1 # Error, no change applied
    fi
}

start_imapfilter() {
    # enter a subshell to not affect the pwd of the running process
    (
        if ! [ -d "$config_target_base" ]; then
            echo ">>> The directory '$config_target_base' does not exist, exiting"
            echo ">>> Please validate IMAPFILTER_CONFIG_BASE"
            exit 1
        fi

        # Enter the basedir of the config. Required to allow relative
        # includes in the lua scripts.
        cd "$config_target_base"

        log_parameter=
        if [ -n "$IMAPFILTER_LOGFILE" ]; then
                log_parameter="-l $IMAPFILTER_LOGFILE"
        fi

        if ! [ -f "$config_target" ]; then
            echo ">>> The file '$config_target' does not exist relative to '$config_target_base', exiting"
            echo ">>> Please validate IMAPFILTER_CONFIG"
            exit 1
        fi

        imapfilter -c "$config_target" $log_parameter
    )
}

imapfilter_pid=
imapfilter_restart_daemon() {
    if [ -n "$imapfilter_pid" ]; then
        kill -TERM "$imapfilter_pid"
        wait "$imapfilter_pid"
    fi
    start_imapfilter &
    imapfilter_pid="$(jobs -p)"
}

loop_no_daemon() {
    while true; do
        pull_config

        printf ">>> Running imapfilter\n"
        if ! start_imapfilter; then
            printf ">>> imapfilter failed\n"
            exit 1
        fi

        printf ">>> Sleeping\n"
        sleep "${IMAPFILTER_SLEEP:-30}"
    done
}

loop_daemon() {
    imapfilter_restart_daemon
    while true; do
        if pull_config; then
            printf ">>> Update in VCS, restarting imapfilter daemon\n"
            imapfilter_restart_daemon
        fi

        printf ">>> Sleeping\n"
        sleep "${IMAPFILTER_SLEEP:-30}"

        if ! kill -0 "$imapfilter_pid" 2>/dev/null; then
            printf ">>> imapfilter daemon died, exiting\n"
            exit 1
        fi
    done
}

pull_config
if [ "$IMAPFILTER_DAEMON" = "yes" ]; then
    loop_daemon
else
    loop_no_daemon
fi
