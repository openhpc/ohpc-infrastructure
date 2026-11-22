#!/bin/bash

trap '/usr/sbin/obsworker stop; exit 0' TERM INT

# "obsworker start" exits with an error if it cannot download the worker
# code from the OBS server.
/usr/sbin/obsworker start || exit 1

# "obsworker start" runs the bs_worker processes in a detached screen
# session. screen keeps running after bs_worker exits, so the loop checks
# for bs_worker processes. bs_worker needs a few seconds to appear after
# the start, so the container exits only after three failed checks.
missing=0
while [ "${missing}" -lt 3 ]; do
	if pgrep -x bs_worker >/dev/null; then
		missing=0
	else
		missing=$((missing + 1))
	fi
	# bash runs the trap only between commands, so sleep in the background.
	sleep 10 &
	wait "$!"
done

echo "No bs_worker process is running. Exiting." >&2
exit 1
