#!/bin/bash

set -ex

# Function to add appropriate closing HTML based on page type
add_html_footer() {
	local current_path="$1"
	local major_version="$2"
	local full_version="$3"
	local stats_script="$4"
	local is_detailed_view=false

	# Check if we're in a specific version directory (has both major and full version)
	if [ -n "$full_version" ] && [ "$current_path" = "/results/$major_version/$full_version" ]; then
		is_detailed_view=true
	fi

	if [ "$is_detailed_view" = true ]; then
		# Detailed view: close table but keep container open for directory listing
		{
			echo "                                </tbody>"
			echo "                        </table>"
			echo "                </div>"
			echo ""
			echo "        <!-- Directory listing will be inserted here by Apache -->"
			echo ""
		} >>HEADER.html

		# Create FOOTER.html to close container and add JavaScript
		{
			echo "        </div>"
			echo ""
			if [ -n "$stats_script" ]; then
				echo "        <!-- Update statistics -->"
				echo "${stats_script}"
				echo ""
			fi
			echo "        <!-- JavaScript for interactive features -->"
			echo "        <script src=\"/.files/test-results.js\"></script>"
			echo "</body>"
			echo "</html>"
		} >FOOTER.html
	else
		# Overview: leave container open for directory listing
		{
			echo ""
			echo "        <!-- Directory listing will be inserted here by Apache -->"
			echo ""
		} >>HEADER.html

		# Create FOOTER.html to close the container
		{
			echo "        </div>"
			echo "</body>"
			echo "</html>"
		} >FOOTER.html
	fi
}

cd "/results/$1/$2"

if [ ! -e HEADER.html ]; then
	cp /home/ohpc/HEADER.tmpl HEADER.html
	sed -e "s,@@VERSION@@,$2,g" -i HEADER.html
	sed -e "s,@@MAJOR_VERSION@@,$1,g" -i HEADER.html
fi

for i in *OHPC*; do
	if [ -e "$i/FAIL" ]; then
		echo "AddDescription \"<img src=\\\"/.files/test_error.png\\\"/>\" $i" >>.htaccess.new
	else
		echo "AddDescription \"<img src=\\\"/.files/test_ok.png\\\"/>\" $i" >>.htaccess.new
	fi
done
mv .htaccess.new .htaccess

# Reset HEADER.html to just the header portion
sed '1,/<!-- END HEADER MARKER -->/!d' -i HEADER.html

# For specific version pages, show detailed view; remove markers
sed -e '/<!-- DETAILED_VIEW_START -->/d' -e '/<!-- DETAILED_VIEW_END -->/d' -i HEADER.html

# Initialize variables with default values
TOTAL_RUNTIME=0
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0

# First pass: calculate totals for summary statistics from actual test directories
for i in 20*; do
	if [ -d "$i" ] && [ -e "$i/INFO" ]; then
		# Reset variables before sourcing each INFO file
		DURATION=0
		PASSED=0
		FAILED=0
		SKIPPED=0

		# shellcheck disable=SC1091
		. "$i/INFO"

		# Add to totals with safe arithmetic
		TOTAL_RUNTIME=$((TOTAL_RUNTIME + DURATION))
		TOTAL_PASSED=$((TOTAL_PASSED + PASSED))
		TOTAL_FAILED=$((TOTAL_FAILED + FAILED))
		TOTAL_SKIPPED=$((TOTAL_SKIPPED + SKIPPED))
	fi
done

# Count LATEST symlinks (these are the current test configurations)
LATEST_COUNT=0
for latest_link in 0-LATEST*; do
	if [ -L "$latest_link" ]; then
		LATEST_COUNT=$((LATEST_COUNT + 1))
	fi
done

# Calculate hours and pass rate safely
TOTAL_HOURS=0
PASS_RATE=0
if [ "$TOTAL_RUNTIME" -gt 0 ]; then
	TOTAL_HOURS=$((TOTAL_RUNTIME / 3600))
fi
if [ $((TOTAL_PASSED + TOTAL_FAILED)) -gt 0 ]; then
	PASS_RATE=$(((TOTAL_PASSED * 100) / (TOTAL_PASSED + TOTAL_FAILED)))
fi

# Store statistics for FOOTER.html generation
STATS_SCRIPT="<script>
document.addEventListener('DOMContentLoaded', function() {
  document.getElementById('total-tests').textContent = '${LATEST_COUNT}';
  document.getElementById('total-runtime').textContent = '${TOTAL_HOURS}h';
  document.getElementById('pass-rate').textContent = '${PASS_RATE}%';
  document.getElementById('latest-tests').textContent = '${LATEST_COUNT}';
});
</script>"

# Generate detailed table rows for each test configuration
for latest_link in 0-LATEST*; do
	if [ -L "$latest_link" ]; then
		# Get the actual directory name that the symlink points to
		actual_dir=$(readlink "$latest_link")

		# Skip if symlink is broken or target doesn't exist
		if [ ! -d "$actual_dir" ]; then
			continue
		fi

		# Extract test configuration from directory name
		config_name=${latest_link#0-LATEST-}
		# Remove OHPC prefix as it's redundant (all tests are OHPC)
		config_name=${config_name#OHPC-}

		# Initialize variables with defaults
		DURATION=0
		PASSED=0
		FAILED=0
		SKIPPED=0

		# Read test results from INFO file in the actual directory
		if [ -e "$actual_dir/INFO" ]; then
			# shellcheck disable=SC1091
			. "$actual_dir/INFO"
		fi

		# Determine test status based on PASS/FAIL files and test counts
		test_status="unknown"
		status_class="status-unknown"
		status_icon="/.files/test_error.png"

		if [ -e "$actual_dir/FAIL" ]; then
			test_status="fail"
			status_class="status-fail"
			status_icon="/.files/test_error.png"
		elif [ -e "$actual_dir/PASS" ]; then
			if [ "$FAILED" -gt 0 ]; then
				test_status="warning"
				status_class="status-warning"
				status_icon="/.files/test_warning.png"
			else
				test_status="pass"
				status_class="status-pass"
				status_icon="/.files/test_ok.png"
			fi
		fi

		# Format duration in human-readable format
		duration_formatted="0m"
		if [ "$DURATION" -gt 0 ]; then
			hours=$((DURATION / 3600))
			minutes=$(((DURATION % 3600) / 60))
			if [ "$hours" -gt 0 ]; then
				duration_formatted="${hours}h ${minutes}m"
			else
				duration_formatted="${minutes}m"
			fi
		fi

		# Extract timestamp from actual directory name for sorting
		timestamp=$(echo "$actual_dir" | grep -o '20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]' | head -1)
		if [ -z "$timestamp" ]; then
			timestamp="unknown"
		fi

		# Add emoji for status display using HTML entities
		status_emoji="&#10067;" # ❓
		case "$test_status" in
		"pass") status_emoji="&#9989;" ;;    # ✅
		"fail") status_emoji="&#10060;" ;;   # ❌
		"warning") status_emoji="&#9888;" ;; # ⚠️
		esac

		# Generate table row with enhanced data
		{
			echo "<tr data-config=\"$config_name\" data-status=\"$test_status\" data-timestamp=\"$timestamp\">"
			echo "  <td><a href=\"$latest_link/\">$config_name</a></td>"
			echo "  <td><span class=\"status-icon $status_class\">$status_emoji <img src=\"$status_icon\" alt=\"$test_status\"/> $test_status</span></td>"
			echo "  <td data-duration=\"$DURATION\">$duration_formatted</td>"
			echo "  <td data-passed=\"$PASSED\">$PASSED</td>"
			echo "  <td data-failed=\"$FAILED\">$FAILED</td>"
			echo "  <td data-timestamp=\"$timestamp\">$timestamp</td>"
			echo "</tr>"
		} >>HEADER.html
	fi
done

# Add appropriate footer for specific version page (detailed view)
add_html_footer "/results/$1/$2" "$1" "$2" "$STATS_SCRIPT"

cd "/results/$1"

FAIL=0
PASS=0

if [ ! -e HEADER.html ]; then
	cp /home/ohpc/HEADER.tmpl HEADER.html
	sed -e "s,@@VERSION@@,$1,g" -i HEADER.html
	# Reset to header portion and remove detailed view sections for overview
	sed '1,/<!-- END HEADER MARKER -->/!d' -i HEADER.html
	sed '/<!-- DETAILED_VIEW_START -->/,/<!-- DETAILED_VIEW_END -->/d' -i HEADER.html
fi

for i in "${1}"*; do
	if [ ! -d "$i" ]; then
		continue
	fi
	for l in "$i"/*LATEST*; do
		if [ -e "$l/FAIL" ]; then
			FAIL=$((FAIL + 1))
		else
			PASS=$((PASS + 1))
		fi
	done
	if [ "$FAIL" -eq 0 ]; then
		echo "AddDescription \"<img src=\\\"/.files/test_ok.png\\\"/>\" $i" >>.htaccess.new
	elif [ "$PASS" -eq 0 ]; then
		echo "AddDescription \"<img src=\\\"/.files/test_error.png\\\"/>\" $i" >>.htaccess.new
	else
		echo "AddDescription \"<img src=\\\"/.files/test_warning.png\\\"/>\" $i" >>.htaccess.new
	fi
	FAIL=0
	PASS=0
done
mv .htaccess.new .htaccess

# Add appropriate footer for major version overview page
add_html_footer "/results/$1" "$1" "" ""

cd /results/

if [ ! -e HEADER.html ]; then
	cp /home/ohpc/HEADER.tmpl HEADER.html
	sed -e "s,@@VERSION@@,Overall,g" -i HEADER.html
	# Reset to header portion and remove detailed view sections for overview
	sed '1,/<!-- END HEADER MARKER -->/!d' -i HEADER.html
	sed '/<!-- DETAILED_VIEW_START -->/,/<!-- DETAILED_VIEW_END -->/d' -i HEADER.html
fi

for i in *; do
	if [ ! -d "$i" ]; then
		continue
	fi
	ERRORS=$(grep -c test_error "$i/.htaccess" || true)
	WARNINGS=$(grep -c test_warning "$i/.htaccess" || true)
	if [ "$ERRORS" -gt 0 ] && [ "$WARNINGS" -eq 0 ]; then
		echo "AddDescription \"<img src=\\\"/.files/test_error.png\\\"/>\" $i" >>.htaccess.new
	elif [ "$WARNINGS" -gt 0 ] && [ "$ERRORS" -eq 0 ]; then
		echo "AddDescription \"<img src=\\\"/.files/test_warning.png\\\"/>\" $i" >>.htaccess.new
	else
		echo "AddDescription \"<img src=\\\"/.files/test_ok.png\\\"/>\" $i" >>.htaccess.new
	fi
done
mv .htaccess.new .htaccess

# Add appropriate footer for overall results overview page
add_html_footer "/results" "" "" ""
