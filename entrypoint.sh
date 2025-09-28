#!/usr/bin/env sh

vcs_token() {
    # Returns the cleaned Git token if found, otherwise returns 1.
    
    if [ -n "$GIT_TOKEN_RAW" ]; then
        # Removes all whitespace (including newlines) from the token value. This prevents
        # common authentication failures caused by trailing hidden characters.
        echo "$GIT_TOKEN_RAW" | tr -d '[:space:]'
        return
    fi

    if [ -n "$GIT_TOKEN" ]; then
        # Reads the secret file and strips all whitespace to prevent token invalidation.
        cat "${GIT_TOKEN}" | tr -d '[:space:]'
        return
    fi

    return 1
}

vcs_uri() {
    # returns authenticated git target url.
    
    local s # This variable holds the final protocol and authentication prefix.
    # Clean whitespace from the target first.
    local target="$(echo "$GIT_TARGET" | tr -d '[:space:]')"

    # 1. Harvests the protocol from GIT_TARGET, or defaults to HTTPS.    
    case "$target" in
        # Match pattern: Checks if any protocol prefix is included (e.g., 'ssh://', 'http://')
        *://*)
            # Harvests the full protocol using parameter expansion: 
            # ${target%%://*} leaves the protocol name, to which we append the '://'.
            s="${target%%://*}://"

            # Strips the protocol prefix from the target using parameter expansion:
            # ${target#*://} removes the shortest match of 'anything://' from the front.
            target="${target#*://}"
            ;; # break
        *)
            # Default protocol if none was specified in GIT_TARGET
            s="https://"
            ;; # break
    esac

    # 2. Add Auth details to s: [protocol://] + [user:token@]
    if [ -n "$GIT_USER" ]; then
        # Cleans and prepends the GIT_USER, formatted as 'user:' for the URI.
        s="${s}$(echo "$GIT_USER" | tr -d '[:space:]'):"
    fi

    token="$(vcs_token)"
    if [ -n "$token" ]; then
        # Appends the cleaned token and the required '@' separator.
        s="${s}${token}@"
    fi

    # 3. Final URI is returned: [protocol://user:token@] + [target path]
    echo "${s}${target}"
}

config_in_vcs() {
    # Checks if both a token/secret and a target repository URL are provided.
    [ -n "$(vcs_token)" ] && [ -n "$GIT_TARGET" ]
}

config_target_base="${IMAPFILTER_CONFIG_BASE:-/opt/imapfilter/config}"
config_target="${IMAPFILTER_CONFIG}"

# If config_target is an absolute path strip the base.
# This handles legacy configurations where IMAPFILTER_CONFIG was an absolute path
# while still respecting IMAPFILTER_CONFIG_BASE as the working directory.
case "$config_target" in
    (/*) config_target="${config_target#${config_target_base}/}";;
esac

pull_config() {
    config_in_vcs || return 1 # Exit if VCS is not configured.
    
    local vcs_url="$(vcs_uri)"
    local pull_output # Captures all output (stdout/stderr) for diagnosis.
    local pull_status # Holds the Git exit code.

    printf ">>> INFO: Checking for config updates...\n" >&2
    
    # 1. Attempt pull, capturing all output (STDOUT and STDERR)
    pull_output=$(git -C "$config_target_base" pull --ff-only --verbose "$vcs_url" 2>&1)
    pull_status=$?

    if [ "$pull_status" -eq 0 ]; then
        # Command succeeded (exit code 0). Check the output to determine if changes were applied.
        
        # Check if the pull resulted in actual changes or was merely up to date.
        if echo "$pull_output" | grep -q "Already up to date."; then
            printf ">>> INFO: Config is already up to date.\n" >&2
            return 1 # Success, but NO CHANGE (loop_daemon will ignore restart)
        else
            printf ">>> INFO: Configuration changes applied. Output:\n%s\n" "$pull_output" >&2
            return 0 # Success, CHANGE APPLIED (trigger daemon restart)
        fi
    else
        # 2. Pull failed (non-zero exit code), print error
        printf ">>> ERROR: Configuration pull failed! Output:\n%s\n" "$pull_output" >&2
        
        # 3. Try initial clone if the directory is empty or not a git repo
        if ! [ -d "$config_target_base/.git" ]; then
            printf ">>> INFO: Directory is not a git repo. Attempting initial clone...\n" >&2
            
            local clone_output=$(git clone --verbose "$vcs_url" "$config_target_base" 2>&1)
            local clone_status=$?

            if [ "$clone_status" -eq 0 ]; then
                printf ">>> INFO: Initial clone succeeded. Output:\n%s\n" "$clone_output" >&2
                return 0 # Initial clone is treated as a successful update to trigger first daemon start
            else
                printf ">>> FATAL: Initial clone failed! Check credentials, URL, and permissions. Output:\n%s\n" "$clone_output" >&2
                exit 1 # Fatal error, terminate container
            fi
        fi
        
        return 1 # Error, no change applied
    fi
}

start_imapfilter() {
    # Execute in a subshell to isolate directory changes (cd) from the main process.
    (
        if ! [ -d "$config_target_base" ]; then
            echo ">>> The directory '$config_target_base' does not exist, exiting"
            echo ">>> Please validate IMAPFILTER_CONFIG_BASE"
            exit 1
        fi

        # Enter the basedir of the config. Required to allow relative
        # includes in the lua scripts to work correctly.
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
    # Gracefully stops the existing daemon process if running, waits for it, and starts a new one.
    if [ -n "$imapfilter_pid" ]; then
        kill -TERM "$imapfilter_pid"
        wait "$imapfilter_pid"
    fi
    start_imapfilter &
    imapfilter_pid="$(jobs -p)"
}

loop_no_daemon() {
    # Executes imapfilter in a simple loop without backgrounding the process.
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
    # Executes imapfilter as a background daemon and restarts it only when a config change is pulled.
    imapfilter_restart_daemon
    while true; do
        if pull_config; then
            printf ">>> Update in VCS, restarting imapfilter daemon\n"
            imapfilter_restart_daemon
        fi

        printf ">>> Sleeping\n"
        sleep "${IMAPFILTER_SLEEP:-30}"

        # Check if the daemon process is still alive.
        if ! kill -0 "$imapfilter_pid" 2>/dev/null; then
            printf ">>> imapfilter daemon died, exiting\n"
            exit 1
        fi
    done
}

# Initial pull before entering the main loop.
pull_config
if [ "$IMAPFILTER_DAEMON" = "yes" ]; then
    loop_daemon
else
    loop_no_daemon
fi