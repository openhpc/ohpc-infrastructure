#!/bin/bash

# Pull the CI results from a test cluster that cannot reach this server.
#
# Started by pull-results@<host>.timer as user ohpc. The host is defined
# in /home/ohpc/.ssh/config and only accepts the results-sync key with a
# forced "rrsync -ro /results" command. rrsync runs rsync in /results,
# so "." is the remote /results and the only path it accepts unchanged.
#
# No --delete: /results is the union of the results of all test
# clusters, deleting with the view of one cluster would remove the
# results of the others.
#
# run-ci.sh collects a run in /results/.incoming and renames it into
# place when it is done, so that directory is skipped.
#
# The update-results-watcher service notices the new files and
# regenerates the result pages.

set -euo pipefail

if [ $# -ne 1 ]; then
	echo "Usage: $0 <host>" >&2
	exit 1
fi

HOST="$1"
RESULTS="/results"

echo "Pulling results from ${HOST}"
rsync -a --stats --exclude=.incoming "${HOST}:." "${RESULTS}/"
