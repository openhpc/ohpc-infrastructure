#!/bin/bash

# Watch /results for changes and run update_results.sh for the affected version.
# Events are batched: after detecting a change, wait BATCH_DELAY seconds and
# coalesce multiple events for the same version into a single update call.

set -euo pipefail

WATCH_DIR="/results"
BATCH_DELAY=5
QUEUE_DIR=$(mktemp -d)

cleanup() {
	rm -rf "$QUEUE_DIR"
}
trap cleanup EXIT

while read -r path; do
	# Strip the watch directory prefix and leading slash
	rel="${path#"$WATCH_DIR"}"
	rel="${rel#/}"

	# Split into components: major/full/rest...
	IFS='/' read -r major full rest <<<"$rel"

	echo "$(date '+%Y-%m-%d %H:%M:%S') inotify: $path"

	# Ignore changes that are not at least 3 levels deep
	# (i.e., must have major, full, and something underneath)
	if [ -z "$major" ] || [ -z "$full" ] || [ -z "$rest" ]; then
		continue
	fi

	marker="$QUEUE_DIR/${major}_${full}"

	# If no pending update for this version, schedule one
	if [ ! -e "$marker" ]; then
		touch "$marker"
		(
			sleep "$BATCH_DELAY"
			rm -f "$marker"
			echo "$(date '+%Y-%m-%d %H:%M:%S') Running update_results.sh $major $full"
			runuser -u ohpc -- /home/ohpc/bin/update_results.sh "$major" "$full" || true
		) &
	fi
done < <(inotifywait -m -r -e create,modify,delete,moved_to \
	--exclude '\.(htaccess|htaccess\.new)|HEADER\.html|FOOTER\.html|/sed[a-zA-Z0-9]+$' \
	--format '%w%f' "$WATCH_DIR")
