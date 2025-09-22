#!/usr/bin/env -S bats --report-formatter junit --formatter tap -j 2
# shellcheck disable=SC1091,SC2154

setup() {
	# Verify num_computes environment variable exists and is a number
	if [ -z "$num_computes" ]; then
		echo "Environment variable 'num_computes' not found"
		return 1
	fi

	if ! [[ "$num_computes" =~ ^[0-9]+$ ]]; then
		echo "Environment variable 'num_computes' is not a number: $num_computes"
		return 1
	fi

	# Create temporary file for storing uptime results
	TEMP_FILE=$(mktemp)
}

teardown() {
	# Clean up temporary file
	[ -f "$TEMP_FILE" ] && rm -f "$TEMP_FILE"
}

@test "num_computes is greater than zero" {
	[ "$num_computes" -gt 0 ]
}

@test "koomie_cf command is available" {
	command -v koomie_cf
}

@test "get uptime from compute nodes produces results" {
	# koomie_cf output format: "hostname uptime_seconds idle_time_seconds"
	# Example: "c001 123.45 456.78"
	run koomie_cf -x "c\\d+" cat /proc/uptime
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	echo "$output" >"$TEMP_FILE"
	[ -s "$TEMP_FILE" ]
}

@test "correct number of compute hosts respond" {
	# Run koomie_cf and count lines
	koomie_cf -x "c\\d+" cat /proc/uptime >"$TEMP_FILE"
	num_lines=$(wc -l <"$TEMP_FILE")
	[ "$num_lines" -eq "$num_computes" ]
}

@test "verify boot times are reasonable" {
	# Maximum uptime expected in seconds (1 hour)
	uptime_threshold=3600
	num_bad=0

	# Get uptime data
	koomie_cf -x "c\\d+" cat /proc/uptime >"$TEMP_FILE"

	# Check that we have entries
	[ -s "$TEMP_FILE" ]

	# Parse each line and check uptime
	while read -r line; do
		if [ -n "$line" ]; then
			# Split line into fields
			read -r host uptime_val _ <<<"$line"
			echo "Checking uptime for $host: $uptime_val"

			# Check if uptime exceeds threshold
			if awk "BEGIN {exit !($uptime_val >= $uptime_threshold)}"; then
				echo "Uptime on $host is $uptime_val and greater than threshold $uptime_threshold"
				((num_bad++))
			fi
		fi
	done <"$TEMP_FILE"

	[ "$num_bad" -eq 0 ]
}
