#!/bin/bash

# Run all CI test combinations of one OpenHPC release on this CI cluster
# and report an overview of the results.
#
# The combinations follow the recipes of the release (see the recipe
# explorer at https://openhpc.github.io/ohpc/4.x/explorer/). The cluster,
# and with it the architecture, is taken from the SMS setting in
# /etc/sysconfig/openhpc-test.config, just like run-ci.sh does.
#
# The state of every combination is tracked in a file below /run, so that
# a later call with --rerun-failed only runs the combinations which failed,
# or which did not run yet because the previous run was interrupted.

set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG=/etc/sysconfig/openhpc-test.config
STATE_DIR=/run/ohpc-ci

show_usage() {
	echo "Usage"
	echo "  $0 -v <VERSION> [<options>] [-- <run-ci.sh options>]"
	echo
	echo "Options:"
	echo "  -v, --version <VERSION>        OpenHPC version to test (e.g. 4.2)"
	echo "  -r, --repository <REPOSITORY>  Repository to test (Factory (default), Staging, Release)"
	echo "      --rerun-failed             Only run the combinations which failed (or did not"
	echo "                                 run yet) in the previous run of the same version"
	echo "                                 and repository, keep the successful ones"
	echo "  -l, --list                     Show all combinations and their current state,"
	echo "                                 do not run anything; without --version show"
	echo "                                 all runs tracked on this cluster"
	echo "  -h, --help                     Show this help"
	echo
	echo "Options after '--' are passed to every run-ci.sh call (e.g. -- --no-upload)."
}

if ! PARSED=$(getopt -o v:r:lh --long version:,repository:,rerun-failed,list,help -n "$0" -- "$@"); then
	show_usage
	exit 1
fi

eval set -- "${PARSED}"

REPO=Factory
RERUN_FAILED=
LIST_ONLY=

while true; do
	case "$1" in
	-v | --version)
		VERSION="$2"
		shift 2
		;;
	-r | --repository)
		REPO="$2"
		shift 2
		;;
	--rerun-failed)
		RERUN_FAILED=true
		shift
		;;
	-l | --list)
		LIST_ONLY=true
		shift
		;;
	-h | --help)
		show_usage
		exit 0
		;;
	--)
		shift
		break
		;;
	*)
		echo "Internal error during option parsing"
		exit 1
		;;
	esac
done

# Everything left is passed on to run-ci.sh
EXTRA_ARGS=("$@")

# --list works without a version, it then shows all tracked runs
if [ -z "${VERSION}" ] && [ -z "${LIST_ONLY}" ]; then
	show_usage
	exit 1
fi

if [ ! -e "${CONFIG}" ]; then
	echo "Input file ${CONFIG} missing"
	exit 1
fi

# shellcheck disable=SC1090
. "${CONFIG}"

if [[ "${SMS}" == "ohpc-lenovo-sms" ]]; then
	CI_CLUSTER=lenovo
	TEST_ARCH=x86_64
elif [[ "${SMS}" == "ohpc-huawei-sms" ]]; then
	CI_CLUSTER=huawei
	TEST_ARCH=aarch64
else
	echo "Unknown system. Exiting"
	exit 1
fi

# Each combination is "<name>|<run-ci.sh arguments>". The distribution,
# version and repository are added when the combination is run.
COMBINATIONS=()
for distro in almalinux rocky; do
	COMBINATIONS+=(
		"${distro}-confluent-slurm|-d ${distro} -p confluent -m slurm"
		"${distro}-openchami-slurm|-d ${distro} -p openchami -m slurm"
		"${distro}-warewulf-flux|-d ${distro} -p warewulf -m flux"
		"${distro}-warewulf-slurm|-d ${distro} -p warewulf -m slurm"
		"${distro}-xcat_stateful-slurm|-d ${distro} -p xcat_stateful -m slurm"
		"${distro}-xcat_stateless-slurm|-d ${distro} -p xcat_stateless -m slurm"
	)
done
COMBINATIONS+=("openeuler-warewulf-slurm|-d openeuler -p warewulf -m slurm")

# Intel oneAPI, the NVIDIA GPUs and InfiniBand are only available on the
# Lenovo cluster.
if [[ "${CI_CLUSTER}" == "lenovo" ]]; then
	COMBINATIONS+=(
		"almalinux-warewulf-slurm-intel|-d almalinux -p warewulf -m slurm --intel"
		"almalinux-warewulf-slurm-gpu-nvidia|-d almalinux -p warewulf -m slurm --gpu nvidia"
		"almalinux-warewulf-slurm-infiniband|-d almalinux -p warewulf -m slurm --infiniband"
	)
fi

mkdir -p "${STATE_DIR}"
STATE="${STATE_DIR}/run-all-ci-${CI_CLUSTER}-${VERSION}-${REPO}.state"

# The state file has one line per combination:
#   <name> <TAB> <PENDING|RUNNING|PASS|FAIL> <TAB> <duration in s> <TAB> <CI logs>

state_get() {
	awk -F'\t' -v n="$1" '$1 == n { print $2 }' "${STATE}"
}

state_set() {
	local tmp
	tmp=$(mktemp -p "${STATE_DIR}")
	awk -F'\t' -v OFS='\t' -v n="$1" -v s="$2" -v d="$3" -v l="$4" \
		'$1 == n { $2 = s; $3 = d; $4 = l } { print }' "${STATE}" >"${tmp}"
	mv "${tmp}" "${STATE}"
}

fmt_duration() {
	if [ -z "$1" ]; then
		return
	fi
	printf '%02d:%02d:%02d' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60))
}

print_overview() {
	local name status duration logs
	local -a passed=() failed=() pending=() running=()

	while IFS=$'\t' read -r name status duration logs; do
		case "${status}" in
		PASS) passed+=("$(printf '  %-40s %8s  %s' "${name}" "$(fmt_duration "${duration}")" "${logs}")") ;;
		FAIL) failed+=("$(printf '  %-40s %8s  %s' "${name}" "$(fmt_duration "${duration}")" "${logs}")") ;;
		RUNNING) running+=("  ${name}") ;;
		*) pending+=("  ${name}") ;;
		esac
	done <"${STATE}"

	echo
	echo "================================================================================"
	echo " OpenHPC ${VERSION} (${REPO}) on ${CI_CLUSTER} (${TEST_ARCH}) at $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
	echo " passed: ${#passed[@]}  failed: ${#failed[@]}  still to run: $((${#pending[@]} + ${#running[@]}))  total: ${#COMBINATIONS[@]}"
	echo "================================================================================"
	if [ ${#passed[@]} -gt 0 ]; then
		echo "Successful:"
		printf '%s\n' "${passed[@]}"
	fi
	if [ ${#failed[@]} -gt 0 ]; then
		echo "Failed:"
		printf '%s\n' "${failed[@]}"
	fi
	if [ ${#running[@]} -gt 0 ]; then
		echo "Running:"
		printf '%s\n' "${running[@]}"
	fi
	if [ ${#pending[@]} -gt 0 ]; then
		echo "Still to run:"
		printf '%s\n' "${pending[@]}"
	fi
	echo "State file: ${STATE}"
	echo "================================================================================"
	echo
}

list_combinations() {
	echo "Combinations on ${CI_CLUSTER} (${TEST_ARCH}):"
	for combination in "${COMBINATIONS[@]}"; do
		echo "  ${combination%%|*}: run-ci.sh ${combination#*|} -v ${VERSION:-<VERSION>} -r ${REPO}"
	done
}

if [ -n "${LIST_ONLY}" ]; then
	if [ -n "${VERSION}" ]; then
		if [ -e "${STATE}" ]; then
			print_overview
		else
			echo "No run of ${VERSION} (${REPO}) found (${STATE} missing)."
			list_combinations
		fi
		exit 0
	fi
	found=
	for STATE in "${STATE_DIR}/run-all-ci-${CI_CLUSTER}-"*.state; do
		[ -e "${STATE}" ] || continue
		found=true
		# run-all-ci-<cluster>-<version>-<repository>.state
		name=$(basename "${STATE}" .state)
		name=${name#run-all-ci-"${CI_CLUSTER}"-}
		VERSION=${name%-*}
		REPO=${name##*-}
		print_overview
	done
	if [ -z "${found}" ]; then
		echo "No runs found in ${STATE_DIR}."
		list_combinations
	fi
	exit 0
fi

# Only one run per cluster at a time, there is only one SMS
exec 9>"${STATE_DIR}/run-all-ci.lock"
if ! flock -n 9; then
	echo "Another run-all-ci.sh is already running on this system. Exiting"
	exit 1
fi

if [ -n "${RERUN_FAILED}" ]; then
	if [ ! -e "${STATE}" ]; then
		echo "No previous run found (${STATE} missing). Nothing to rerun"
		exit 1
	fi
	tmp=$(mktemp -p "${STATE_DIR}")
	awk -F'\t' -v OFS='\t' '$2 == "FAIL" { $2 = "PENDING"; $3 = ""; $4 = "" } { print }' \
		"${STATE}" >"${tmp}"
	mv "${tmp}" "${STATE}"
else
	: >"${STATE}"
	for combination in "${COMBINATIONS[@]}"; do
		printf '%s\tPENDING\t\t\n' "${combination%%|*}" >>"${STATE}"
	done
fi

TO_RUN=()
for combination in "${COMBINATIONS[@]}"; do
	if [[ "$(state_get "${combination%%|*}")" == "PENDING" ]]; then
		TO_RUN+=("${combination}")
	fi
done

if [ ${#TO_RUN[@]} -eq 0 ]; then
	echo "Nothing to run"
	print_overview
	exit 0
fi

CURRENT=
CURRENT_START=

# shellcheck disable=SC2329 # invoked via trap
interrupted() {
	if [ -n "${CURRENT}" ]; then
		state_set "${CURRENT}" FAIL $(($(date +%s) - CURRENT_START)) "interrupted"
	fi
	echo
	echo "Interrupted"
	print_overview
	exit 130
}

trap interrupted INT TERM

print_overview

RUN_LOG=$(mktemp)
for combination in "${TO_RUN[@]}"; do
	CURRENT="${combination%%|*}"
	# shellcheck disable=SC2206
	args=(${combination#*|})

	echo "--> Starting ${CURRENT}: run-ci.sh ${args[*]} -v ${VERSION} -r ${REPO} ${EXTRA_ARGS[*]}"
	CURRENT_START=$(date +%s)
	state_set "${CURRENT}" RUNNING "" ""

	# run-ci.sh expects to be started from its own directory
	(cd "${SCRIPT_DIR}" && ./run-ci.sh "${args[@]}" -v "${VERSION}" -r "${REPO}" "${EXTRA_ARGS[@]}") 2>&1 |
		tee "${RUN_LOG}"
	rc=${PIPESTATUS[0]}

	duration=$(($(date +%s) - CURRENT_START))
	logs=$(sed -n 's/^--> CI logs: *//p' "${RUN_LOG}" | tail -1)
	if [ "${rc}" -eq 0 ] && grep -q '^--> CI run result: *PASS' "${RUN_LOG}"; then
		state_set "${CURRENT}" PASS "${duration}" "${logs}"
	else
		state_set "${CURRENT}" FAIL "${duration}" "${logs}"
	fi
	CURRENT=

	print_overview
done
rm -f "${RUN_LOG}"

trap - INT TERM

if grep -q $'\tFAIL\t' "${STATE}"; then
	echo "Some combinations failed. Run them again with:"
	echo "  $0 -v ${VERSION} -r ${REPO} --rerun-failed${EXTRA_ARGS[*]:+ -- ${EXTRA_ARGS[*]}}"
	exit 1
fi

echo "All combinations passed."
exit 0
