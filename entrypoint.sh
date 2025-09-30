#!/usr/bin/env sh

vcs_token() {
	if [ -n "$GIT_TOKEN_RAW" ]; then
		echo "$GIT_TOKEN_RAW"
		return
	fi

	if [ -n "$GIT_TOKEN" ]; then
		cat "${GIT_TOKEN}"
	fi

	return 1
}

vcs_uri() {
	s="https://"
	if [ -n "$GIT_USER" ]; then
		# https://user:
		s="${s}${GIT_USER}:"
	fi

	# https://user:token@"
	token="$(vcs_token)"
	if [ -n "$token" ]; then
		s="${s}${token}@"
	fi

	# https://user:token@target
	echo "${s}${GIT_TARGET}"
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
/*) config_target="${config_target#${config_target_base}/}" ;;
esac

pull_config() {
	config_in_vcs || return

	printf ">>> Updating config\n"
	if [ ! -d "$config_target_base" ]; then
		printf ">>> Config has not been cloned yet, cloning\n"
		mkdir -p "$config_target_base"
		git clone "$(vcs_uri)" "$config_target_base"
		return
	else
		cd "$config_target_base"
		printf ">>> Pulling config\n"
		git remote update
		if [ "$(git rev-parse HEAD)" != "$(git rev-parse FETCH_HEAD)" ]; then
			git pull
			return
		fi
		cd -
	fi
	return 1
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

get_imapfilter_pids() {
	ps -A -o pid,comm | grep imapfilter | grep -v grep | awk '{print $1}'
}

imapfilter_restart_daemon() {
	pids=$(get_imapfilter_pids)

	if [ -n "$pids" ]; then
		printf ">>> Stopping imapfilter processes: %s\n" "$pids"

		# Send TERM to all
		for pid in $pids; do
			kill -TERM "$pid" 2>/dev/null
		done

		# Wait up to timeout for ALL processes to exit
		timeout=10
		while [ $timeout -gt 0 ]; do
			still_alive=""
			for pid in $pids; do
				if kill -0 "$pid" 2>/dev/null; then
					still_alive="$still_alive $pid"
				fi
			done

			if [ -z "$still_alive" ]; then
				printf ">>> All imapfilter processes stopped gracefully\n"
				break
			fi

			sleep 1
			timeout=$((timeout - 1))
		done

		# Force kill any remaining processes
		if [ -n "$still_alive" ]; then
			remaining=$(get_imapfilter_pids)
			if [ -n "$remaining" ]; then
				printf ">>> Force killing remaining processes: %s\n" "$remaining"
				for pid in $remaining; do
					kill -KILL "$pid" 2>/dev/null
				done
				sleep 1
			fi
		fi
	fi

	start_imapfilter &
	imapfilter_pid=$!
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
		printf ">>> imapfilter processes:\n"
		ps -A | grep 'imapfilter' | grep -v 'grep'

		if pull_config; then
			printf ">>> Update in VCS, restarting imapfilter daemon\n"
			imapfilter_restart_daemon
		fi

		printf ">>> Sleeping\n"
		sleep "${IMAPFILTER_SLEEP:-30}"

		# Check if any imapfilter is still running
		if [ -z "$(get_imapfilter_pids)" ]; then
			printf ">>> No imapfilter processes found, exiting\n"
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
