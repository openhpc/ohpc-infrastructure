#!/usr/bin/env bats
# shellcheck disable=SC2086,SC2154

SCRIPT="ansible/roles/obs/files/copr_bridge.py"
COMMON_ARGS="--copr-project test/project --chroot rhel+epel-10-ppc64le"
SUBMITTED='s/.*Would submit //; s/ to .*//'

# mksrpm <release> <distro> <arch> <package> <srpm> <mtime> creates an empty
# SRPM in the layout of the OBS build directory.
mksrpm() {
	local dir="${TEST_DIR}/OpenHPC4:$1:Factory/$2/$3/$4"
	mkdir -p "${dir}"
	touch -t "$6" "${dir}/$5"
}

setup() {
	TEST_DIR=$(mktemp -d)
	STATE_FILE="${TEST_DIR}/state.json"

	# Create fake SRPMs with distinct mtimes (oldest first)
	mksrpm 4.2 EL_10 aarch64 ohpc-filesystem ohpc-filesystem-4.2-420.ohpc.1.1.src.rpm 202506260000
	mksrpm 4.2 EL_10 aarch64 docs docs-ohpc-4.1.0-420.ohpc.2.2.src.rpm 202506261500
	mksrpm 4.2 EL_10 aarch64 hwloc hwloc-ohpc-2.14.0-420.ohpc.2.1.src.rpm 202506270900
	mksrpm 4.2 EL_10 aarch64 R-gnu15 R-gnu15-ohpc-4.6.1-420.ohpc.1.1.src.rpm 202506271600
	mksrpm 4.2 EL_10 aarch64 otf2-gnu15-mpich otf2-gnu15-mpich-ohpc-3.2-420.ohpc.3.1.src.rpm 202506280900
	mksrpm 4.2 EL_10 aarch64 otf2-gnu15-openmpi5 otf2-gnu15-openmpi5-ohpc-3.2-420.ohpc.2.1.src.rpm 202506281000

	# Create a binary RPM that should be ignored
	touch "${TEST_DIR}/OpenHPC4:4.2:Factory/EL_10/aarch64/hwloc/hwloc-ohpc-2.14.0-420.ohpc.2.1.aarch64.rpm"

	# Create SRPMs that should be ignored: other arch, other distro, other
	# major release, the dependency project and an OBS internal directory
	mksrpm 4.2 EL_10 x86_64 impi-devel intel-mpi-devel-ohpc-2021.16-420.ohpc.1.1.src.rpm 202506290000
	mksrpm 4.2 openEuler_24.03 aarch64 hwloc hwloc-ohpc-2.14.0-420.ohpc.5.1.src.rpm 202506290000
	mksrpm 4.2 EL_10 aarch64 :repo lmod-ohpc-8.7-420.ohpc.1.1.src.rpm 202506290000
	mksrpm 4.x:Dep EL_10 aarch64 lua lua-ohpc-5.4-1.1.src.rpm 202506290000
	mkdir -p "${TEST_DIR}/OpenHPC3:3.4:Factory/EL_10/aarch64/hwloc"
	touch "${TEST_DIR}/OpenHPC3:3.4:Factory/EL_10/aarch64/hwloc/hwloc-ohpc-2.11.0-340.ohpc.1.1.src.rpm"
}

teardown() {
	rm -rf "${TEST_DIR}"
}

@test "help output works" {
	run python3 "${SCRIPT}" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"Bridge OBS SRPMs to Fedora COPR"* ]]
}

@test "required arguments are enforced" {
	run python3 "${SCRIPT}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"--srpm-dir"* ]]
}

@test "invalid copr-project format is rejected" {
	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		--copr-project "no-slash" \
		--chroot rhel+epel-10-ppc64le \
		--dry-run \
		--state-file "${STATE_FILE}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Invalid --copr-project format"* ]]
}

@test "nonexistent srpm-dir is rejected" {
	run python3 "${SCRIPT}" \
		--srpm-dir /nonexistent/path \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"does not exist"* ]]
}

@test "dry-run scan finds only SRPMs, not binary RPMs" {
	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Found 6 SRPMs for EL_10/aarch64 in 1 releases"* ]]
	# Binary RPM must not appear
	[[ "$output" != *"aarch64.rpm"* ]]
	[[ "$output" != *"intel-mpi-devel"* ]]
	[[ "$output" != *"lmod-ohpc"* ]]
	[[ "$output" != *"lua-ohpc"* ]]
	[[ "$output" != *"340.ohpc"* ]]
	[[ "$output" != *"420.ohpc.5.1"* ]]
}

@test "dry-run scan processes SRPMs in mtime order" {
	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]

	# Extract the order of dry-run submissions
	order=$(echo "$output" | grep '\[dry-run\]' | sed "${SUBMITTED}")
	first=$(echo "$order" | head -1)
	last=$(echo "$order" | tail -1)

	# Oldest mtime should be first
	[ "$first" = "ohpc-filesystem-4.2-420.ohpc.1.1.src.rpm" ]
	# Newest mtime should be last
	[ "$last" = "otf2-gnu15-openmpi5-ohpc-3.2-420.ohpc.2.1.src.rpm" ]
}

@test "dry-run creates a valid state file" {
	python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}"

	# State file must exist and be valid JSON
	[ -f "${STATE_FILE}" ]
	python3 -m json.tool "${STATE_FILE}" >/dev/null

	# Must contain all 6 SRPMs
	count=$(python3 -c "import json; print(len(json.load(open('${STATE_FILE}'))['builds']))")
	[ "$count" -eq 6 ]

	# All entries must have dry-run reason
	dryruns=$(python3 -c "
import json
s = json.load(open('${STATE_FILE}'))
print(sum(1 for b in s['builds'].values() if b.get('reason') == 'dry-run'))
")
	[ "$dryruns" -eq 6 ]
}

@test "skip-pattern filters matching SRPMs" {
	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--skip-pattern 'gnu15' \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]

	# 3 SRPMs have gnu15 in the name, so only 3 should be submitted
	submitted=$(echo "$output" | grep -c '\[dry-run\]')
	[ "$submitted" -eq 3 ]

	# The skipped ones should be in state with reason "filtered"
	filtered=$(python3 -c "
import json
s = json.load(open('${STATE_FILE}'))
print(sum(1 for b in s['builds'].values() if b.get('reason') == 'filtered'))
")
	[ "$filtered" -eq 3 ]
}

@test "include-pattern limits to matching SRPMs only" {
	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--include-pattern 'docs-ohpc' \
		--include-pattern 'hwloc' \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]

	submitted=$(echo "$output" | grep -c '\[dry-run\]')
	[ "$submitted" -eq 2 ]
}

@test "skip-pattern takes precedence over include-pattern" {
	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--include-pattern 'ohpc' \
		--skip-pattern 'docs-ohpc' \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]

	# docs-ohpc should be skipped even though it matches include
	[[ "$output" != *"Would submit docs-ohpc"* ]]
}

@test "re-run after dry-run still processes all SRPMs" {
	# First dry-run
	python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}"

	# Second dry-run should still process everything (dry-run entries do not block)
	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]

	submitted=$(echo "$output" | grep -c '\[dry-run\]')
	[ "$submitted" -eq 6 ]
}

@test "re-run skips filter-skipped SRPMs" {
	# First run with skip pattern
	python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--skip-pattern 'gnu15' \
		--state-file "${STATE_FILE}"

	# Second run without skip pattern: the filter-skipped ones stay skipped
	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}" \
		--debug
	[ "$status" -eq 0 ]

	already=$(echo "$output" | grep -c 'already skipped')
	[ "$already" -eq 3 ]
}

@test "state file records correct metadata" {
	python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}"

	# Verify state file structure
	python3 -c "
import json, sys
s = json.load(open('${STATE_FILE}'))
assert s['version'] == 1, 'version mismatch'
assert s['copr_project'] == 'test/project', 'project mismatch'
assert s['chroot'] == 'rhel+epel-10-ppc64le', 'chroot mismatch'
assert s['blocked_on'] is None, 'should not be blocked'
# Each build must have mtime
for name, b in s['builds'].items():
    assert 'mtime' in b, f'{name} missing mtime'
    assert b['mtime'] > 0, f'{name} mtime not positive'
"
}

@test "blocked_on state is auto-reset on next run" {
	# Create a state file with blocked_on set
	cat >"${STATE_FILE}" <<-'EOF'
		{
		  "version": 1,
		  "srpm_dir": "/tmp",
		  "copr_project": "test/project",
		  "chroot": "rhel+epel-10-ppc64le",
		  "builds": {
		    "broken-ohpc-1.0-1.src.rpm": {
		      "status": "failed",
		      "copr_build_id": 99999,
		      "mtime": 1000000
		    }
		  },
		  "last_succeeded": null,
		  "blocked_on": "broken-ohpc-1.0-1.src.rpm"
		}
	EOF

	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Auto-resetting previously failed SRPM"* ]]
	[[ "$output" == *"Scan complete"* ]]

	# Verify blocked_on is cleared in state
	blocked=$(python3 -c "import json; print(json.load(open('${STATE_FILE}'))['blocked_on'])")
	[ "$blocked" = "None" ]

	# Verify the failed entry was removed from builds
	absent=$(python3 -c "
import json
s = json.load(open('${STATE_FILE}'))
print('broken-ohpc-1.0-1.src.rpm' not in s['builds'])
")
	[ "$absent" = "True" ]
}

@test "reset-failed clears blocked_on and allows continuation" {
	# Create a state file with a failed build
	cat >"${STATE_FILE}" <<-'EOF'
		{
		  "version": 1,
		  "srpm_dir": "/tmp",
		  "copr_project": "test/project",
		  "chroot": "rhel+epel-10-ppc64le",
		  "builds": {
		    "broken-ohpc-1.0-1.src.rpm": {
		      "status": "failed",
		      "copr_build_id": 99999,
		      "mtime": 1000000
		    }
		  },
		  "last_succeeded": null,
		  "blocked_on": "broken-ohpc-1.0-1.src.rpm"
		}
	EOF

	# Reset the failed SRPM
	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}" \
		--reset-failed "broken-ohpc-1.0-1.src.rpm"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Removed"* ]]

	# Verify blocked_on is cleared
	blocked=$(python3 -c "import json; print(json.load(open('${STATE_FILE}'))['blocked_on'])")
	[ "$blocked" = "None" ]

	# Verify the entry is removed from builds
	absent=$(python3 -c "
import json
s = json.load(open('${STATE_FILE}'))
print('broken-ohpc-1.0-1.src.rpm' not in s['builds'])
")
	[ "$absent" = "True" ]

	# Now a scan should work without error
	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Scan complete"* ]]
}

@test "reset-failed rejects non-failed SRPM" {
	# Create state with a succeeded SRPM
	cat >"${STATE_FILE}" <<-'EOF'
		{
		  "version": 1,
		  "srpm_dir": "/tmp",
		  "copr_project": "test/project",
		  "chroot": "rhel+epel-10-ppc64le",
		  "builds": {
		    "good-ohpc-1.0-1.src.rpm": {
		      "status": "succeeded",
		      "copr_build_id": 99999,
		      "mtime": 1000000
		    }
		  },
		  "last_succeeded": "good-ohpc-1.0-1.src.rpm",
		  "blocked_on": null
		}
	EOF

	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}" \
		--reset-failed "good-ohpc-1.0-1.src.rpm"
	[ "$status" -ne 0 ]
	[[ "$output" == *"not failed/canceled"* ]]
}

@test "reset-failed rejects unknown SRPM" {
	# Create empty state
	cat >"${STATE_FILE}" <<-'EOF'
		{
		  "version": 1,
		  "srpm_dir": "/tmp",
		  "copr_project": "test/project",
		  "chroot": "rhel+epel-10-ppc64le",
		  "builds": {},
		  "last_succeeded": null,
		  "blocked_on": null
		}
	EOF

	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}" \
		--reset-failed "nonexistent.src.rpm"
	[ "$status" -ne 0 ]
	[[ "$output" == *"not found in state file"* ]]
}

@test "corrupt state file is handled gracefully" {
	echo "not json" >"${STATE_FILE}"

	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Starting with empty state"* ]]
	[[ "$output" == *"Scan complete"* ]]
}

@test "empty directory produces zero results" {
	empty_dir=$(mktemp -d)

	run python3 "${SCRIPT}" \
		--srpm-dir "${empty_dir}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Found 0 SRPMs for EL_10/aarch64 in 0 releases"* ]]
	[[ "$output" == *"0 succeeded, 0 skipped, 0 failed"* ]]

	rmdir "${empty_dir}"
}

@test "debug flag produces debug output" {
	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}" \
		--skip-pattern 'docs-ohpc' \
		--debug
	[ "$status" -eq 0 ]
	[[ "$output" == *"matched skip pattern"* ]]
}

@test "ignore-errors flag is accepted and documented" {
	run python3 "${SCRIPT}" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--ignore-errors"* ]]
	[[ "$output" == *"skip failed packages"* ]]
}

@test "ignore-errors clears blocked_on and continues processing" {
	# Create a state file with blocked_on set
	cat >"${STATE_FILE}" <<-'EOF'
		{
		  "version": 1,
		  "srpm_dir": "/tmp",
		  "copr_project": "test/project",
		  "chroot": "rhel+epel-10-ppc64le",
		  "builds": {
		    "broken-ohpc-1.0-1.src.rpm": {
		      "status": "failed",
		      "copr_build_id": 99999,
		      "mtime": 1000000
		    }
		  },
		  "last_succeeded": null,
		  "blocked_on": "broken-ohpc-1.0-1.src.rpm"
		}
	EOF

	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--ignore-errors \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Scan complete"* ]]

	# blocked_on must be cleared
	blocked=$(python3 -c "import json; print(json.load(open('${STATE_FILE}'))['blocked_on'])")
	[ "$blocked" = "None" ]
}

@test "scan summary lists SRPM names per category" {
	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--skip-pattern 'gnu15' \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]

	# Succeeded section should list the 3 non-gnu15 SRPMs
	[[ "$output" == *"Succeeded:"* ]]
	[[ "$output" == *"ohpc-filesystem-4.2-420.ohpc.1.1.src.rpm"* ]]
	[[ "$output" == *"docs-ohpc-4.1.0-420.ohpc.2.2.src.rpm"* ]]
	[[ "$output" == *"hwloc-ohpc-2.14.0-420.ohpc.2.1.src.rpm"* ]]

	# Skipped section should list the 3 gnu15 SRPMs
	[[ "$output" == *"Skipped:"* ]]
	[[ "$output" == *"R-gnu15-ohpc-4.6.1-420.ohpc.1.1.src.rpm"* ]]
	[[ "$output" == *"otf2-gnu15-mpich-ohpc-3.2-420.ohpc.3.1.src.rpm"* ]]
	[[ "$output" == *"otf2-gnu15-openmpi5-ohpc-3.2-420.ohpc.2.1.src.rpm"* ]]

	# No failed section expected
	[[ "$output" != *"Failed:"* ]]
}

@test "force-rebuild flag is accepted and documented" {
	run python3 "${SCRIPT}" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--force-rebuild"* ]]
	[[ "$output" == *"rebuild packages even if they already exist"* ]]
}

@test "already-in-copr entries are skipped on re-run" {
	# Simulate a prior run that found a package already in COPR
	cat >"${STATE_FILE}" <<-'EOF'
		{
		  "version": 1,
		  "srpm_dir": "/tmp",
		  "copr_project": "test/project",
		  "chroot": "rhel+epel-10-ppc64le",
		  "builds": {
		    "ohpc-filesystem-4.2-420.ohpc.1.1.src.rpm": {
		      "status": "skipped",
		      "reason": "already-in-copr",
		      "mtime": 1000000
		    }
		  },
		  "last_succeeded": null,
		  "blocked_on": null
		}
	EOF

	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]

	# Only 5 of 6 SRPMs should be submitted (the already-in-copr one is skipped)
	submitted=$(echo "$output" | grep -c '\[dry-run\]')
	[ "$submitted" -eq 5 ]
}

@test "force-rebuild reprocesses already-in-copr entries" {
	# Simulate a prior run that found a package already in COPR
	cat >"${STATE_FILE}" <<-'EOF'
		{
		  "version": 1,
		  "srpm_dir": "/tmp",
		  "copr_project": "test/project",
		  "chroot": "rhel+epel-10-ppc64le",
		  "builds": {
		    "ohpc-filesystem-4.2-420.ohpc.1.1.src.rpm": {
		      "status": "skipped",
		      "reason": "already-in-copr",
		      "mtime": 1000000
		    }
		  },
		  "last_succeeded": null,
		  "blocked_on": null
		}
	EOF

	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--force-rebuild \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]

	# All 6 SRPMs should be submitted
	submitted=$(echo "$output" | grep -c '\[dry-run\]')
	[ "$submitted" -eq 6 ]
}

@test "multiple skip patterns can be combined" {
	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--skip-pattern 'gnu15' \
		--skip-pattern 'docs-ohpc' \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]

	# 3 gnu15 + 1 docs = 4 skipped, 2 remaining
	submitted=$(echo "$output" | grep -c '\[dry-run\]')
	[ "$submitted" -eq 2 ]
}

@test "only the SRPM from the highest release is submitted" {
	mksrpm 4.2.1 EL_10 aarch64 hwloc hwloc-ohpc-2.14.1-421.ohpc.1.1.src.rpm 202507010000
	mksrpm 4.3 EL_10 aarch64 hwloc hwloc-ohpc-2.15.0-430.ohpc.1.1.src.rpm 202508010000
	# A patch release that is built after 4.3 must not win over 4.3.
	mksrpm 4.2.2 EL_10 aarch64 hwloc hwloc-ohpc-2.14.2-422.ohpc.1.1.src.rpm 202509010000
	mksrpm 4.2.1 EL_10 aarch64 docs docs-ohpc-4.2.1-421.ohpc.1.1.src.rpm 202507010000
	# 4.10 is newer than 4.3 although it sorts lower as a string.
	mksrpm 4.10 EL_10 aarch64 ohpc-filesystem ohpc-filesystem-4.10-4100.ohpc.1.1.src.rpm 202601010000
	mksrpm 4.3 EL_10 aarch64 ohpc-filesystem ohpc-filesystem-4.3-430.ohpc.1.1.src.rpm 202508010000

	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Found 12 SRPMs for EL_10/aarch64 in 5 releases, 6 are the newest"* ]]

	submitted=$(echo "$output" | grep '\[dry-run\]' | sed "${SUBMITTED}" | sort)
	expected=$(
		sort <<-'EOF'
			hwloc-ohpc-2.15.0-430.ohpc.1.1.src.rpm
			docs-ohpc-4.2.1-421.ohpc.1.1.src.rpm
			ohpc-filesystem-4.10-4100.ohpc.1.1.src.rpm
			R-gnu15-ohpc-4.6.1-420.ohpc.1.1.src.rpm
			otf2-gnu15-mpich-ohpc-3.2-420.ohpc.3.1.src.rpm
			otf2-gnu15-openmpi5-ohpc-3.2-420.ohpc.2.1.src.rpm
		EOF
	)
	[ "$submitted" = "$expected" ]
}

@test "Update project naming is treated as a patch release" {
	mkdir -p "${TEST_DIR}/OpenHPC4:4.2:Update1:Factory/EL_10/aarch64/hwloc"
	touch "${TEST_DIR}/OpenHPC4:4.2:Update1:Factory/EL_10/aarch64/hwloc/hwloc-ohpc-2.14.1-421.ohpc.1.1.src.rpm"

	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Would submit hwloc-ohpc-2.14.1-421.ohpc.1.1.src.rpm"* ]]
	[[ "$output" != *"Would submit hwloc-ohpc-2.14.0"* ]]
}

@test "arch, distro and major select a different set of SRPMs" {
	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--arch x86_64 \
		--dry-run \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | grep '\[dry-run\]' | sed "${SUBMITTED}")" = "intel-mpi-devel-ohpc-2021.16-420.ohpc.1.1.src.rpm" ]

	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--distro openEuler_24.03 \
		--dry-run \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | grep '\[dry-run\]' | sed "${SUBMITTED}")" = "hwloc-ohpc-2.14.0-420.ohpc.5.1.src.rpm" ]

	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--major 3 \
		--dry-run \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | grep '\[dry-run\]' | sed "${SUBMITTED}")" = "hwloc-ohpc-2.11.0-340.ohpc.1.1.src.rpm" ]
}

@test "copr-project defaults to the OpenHPC group project of the major release" {
	run python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		--dry-run \
		--state-file "${STATE_FILE}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"to @openhpc/openhpc-4.x"* ]]
}

@test "watch mode picks up a new SRPM and does not resubmit old ones" {
	python3 "${SCRIPT}" \
		--srpm-dir "${TEST_DIR}" \
		${COMMON_ARGS} \
		--dry-run \
		--mode watch \
		--scan-interval 1 \
		--state-file "${STATE_FILE}" >"${TEST_DIR}/watch.log" 2>&1 &
	pid=$!

	for _ in $(seq 50); do
		grep -q 'otf2-gnu15-openmpi5' "${TEST_DIR}/watch.log" && break
		sleep 0.2
	done
	mksrpm 4.3 EL_10 aarch64 hwloc hwloc-ohpc-2.15.0-430.ohpc.1.1.src.rpm 202508010000
	for _ in $(seq 50); do
		grep -q 'hwloc-ohpc-2.15.0' "${TEST_DIR}/watch.log" && break
		sleep 0.2
	done
	sleep 2.5

	kill -TERM "${pid}"
	wait "${pid}"

	[ "$(grep -c 'Would submit hwloc-ohpc-2.15.0' "${TEST_DIR}/watch.log")" -eq 1 ]
	[ "$(grep -c 'Would submit' "${TEST_DIR}/watch.log")" -eq 7 ]
	grep -q 'shutting down gracefully' "${TEST_DIR}/watch.log"
}
