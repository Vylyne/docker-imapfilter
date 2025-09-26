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
    s="https://"
    
    # Debug: Confirm whether a username is being used
    if [ -n "$GIT_USER" ]; then
        printf ">>> DEBUG: Using username in VCS URI (e.g., for GitHub PATs with user:token).\n"
        s="${s}${GIT_USER}:"
    else
        printf ">>> DEBUG: Excluding username from VCS URI (e.g., for token-only auth).\n"
    fi

    # https://[user]:[token]@
    token="$(vcs_token)"
    if [ -n "$token" ]; then
        s="${s}${token}@"
    fi

    uri="${s}${GIT_TARGET}"
    
    # Debug: Mask the token and print the URI for troubleshooting
    if [ -n "$token" ]; then
        # Safely mask the token in the debug output
        masked_uri=$(echo "$uri" | sed "s/$token/********/")
        printf ">>> DEBUG: Constructed VCS URI (masked): %s\n" "$masked_uri"
    fi
    
    echo "$uri"
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
    # If GIT_TARGET is not defined, we skip VCS operations
    if ! config_in_vcs; then
        return 0
    fi

    vcs_url="$(vcs_uri)"
    
    # ----------------------------------------------------
    # NEW: Run git with verbose output and capture STDOUT/STDERR
    # ----------------------------------------------------
    printf ">>> INFO: Pulling configuration from VCS...\n"
    
    # Run the git command, capture its output and status code
    # NOTE: --verbose will give more details on the connection/authentication
    if git -C "$config_target_base" pull --ff-only --verbose "$vcs_url" 2>&1 ; then
        printf ">>> INFO: Configuration pull succeeded.\n"
        return 0
    else
        # Git failed. The error message is already printed to STDOUT/STDERR 
        # by the command itself because of '2>&1'.
        printf ">>> ERROR: Configuration pull failed! See output above for details.\n"
        
        # If the failure was due to initial clone, try clone instead of pull
        if ! [ -d "$config_target_base/.git" ]; then
            printf ">>> INFO: Directory is not a git repo. Attempting initial clone...\n"
            
            # The clone command, also run with verbose output
            if git clone --verbose "$vcs_url" "$config_target_base" 2>&1 ; then
                printf ">>> INFO: Initial clone succeeded.\n"
                return 0
            else
                printf ">>> FATAL ERROR: Initial clone failed! Check credentials, URL, and permissions.\n"
                # Since the configuration is missing, we must exit the script.
                exit 1
            fi
        fi
        
        # If it failed a pull, and it IS a repo, we just return an error
        return 1
    fi
}

start_imapfilter() {
    # enter a subshell to not affect the pwd of the running process
    (
        if ! [ -d "$config_target_base" ]; then
            echo "The directory '$config_target_base' does not exist, exiting"
            echo "Please validate IMAPFILTER_CONFIG_BASE"
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
            echo "The file '$config_target' does not exist relative to '$config_target_base', exiting"
            echo "Please validate IMAPFILTER_CONFIG"
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
