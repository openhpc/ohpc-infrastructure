#!/bin/bash

set -o pipefail
set -e
set -u # Error on undefined variables

# Enable extended pattern matching and null globbing for better file handling
shopt -s extglob nullglob

# Error trap for better debugging
trap 'echo "ERROR: Command failed at line $LINENO: $BASH_COMMAND" >&2; exit 1' ERR

# Function to log with timestamps
log_msg() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

EXEC_CMDS=false
DEPS_ONLY=false
START=$(date +%s)

show_usage() {
	echo "Usage"
	echo "  $0 [<options>]"
	echo
	echo "Script to sync RPMs from OBS to repository server"
	echo
	echo "Options:"
	echo "  -e                    Enable commands (disable dry-run)"
	echo "  -n <VERSION>          Sync repository for upcoming <VERSION>"
	echo "  -p <VERSION>          Use <VERSION> as previous version"
	echo "  -d                    Dependencies only - sync only from Dep:Release, skip Factory"
	echo "  -h                    Show this help"
}

while getopts "hedn:p:" OPTION; do
	case ${OPTION} in
	e)
		EXEC_CMDS=true
		;;
	d)
		DEPS_ONLY=true
		;;
	n)
		NEXT_VERSION=$OPTARG
		;;
	p)
		PREVIOUS_VERSION=$OPTARG
		;;
	h)
		show_usage
		exit 0
		;;
	*)
		echo "Incorrect options provided"
		show_usage
		exit 1
		;;
	esac
done

if [ -z "${NEXT_VERSION}" ] || [ -z "${PREVIOUS_VERSION}" ]; then
	show_usage
	exit 0
fi

REPO_DIR="/repos/.staging"
REPO=obs.openhpc.community
# This currently requires an SSH tunnel
REPO=localhost:1873

do_cmd() {
	echo "------> raw command = $1"

	# Extract command name safely without awk subprocess
	local cmd_string="$1"
	local command="${cmd_string%% *}" # Get first word using parameter expansion

	local mystatus=0
	if ${EXEC_CMDS}; then
		local output
		# Execute command directly instead of using eval for security
		output=$(bash -c "$cmd_string" 2>&1)
		mystatus=$?
		echo "$output"
		if [[ "$command" == "rsync" ]] && [[ -n $output ]]; then
			mystatus=1
		fi
	else
		echo "[skipping command]"
	fi

	echo "return status = $mystatus"
	return "${mystatus}"
}

FACTORY='Factory/'

# Common rsync parameters
RSYNC_COMMON_FLAGS="-avHKL --exclude OpenHPC*.repo --exclude repocache --exclude repodata --exclude updates --delay-updates"
RSYNC_FACTORY_FLAGS="--delete --exclude ohpc-release*rpm"

MAJOR_VERSION=$(echo "${NEXT_VERSION}" | cut -d '.' -f1)
MINOR_VERSION=$(echo "${NEXT_VERSION}" | cut -d '.' -f1,2)
MINOR_DIGIT=$(echo "${NEXT_VERSION}" | cut -d '.' -f2)
MICRO_VERSION=$(echo "${NEXT_VERSION}" | cut -d '.' -f3)

# Set version-specific signing key
PUBKEY="/home/ohpc/RPM-GPG-KEY-OpenHPC-${MAJOR_VERSION}"

log_msg "Starting reposync.sh with the following configuration:"
log_msg "  REPO: $REPO"
log_msg "  MAJOR_VERSION: $MAJOR_VERSION"
log_msg "  MINOR_VERSION: $MINOR_VERSION"
log_msg "  MICRO_VERSION: $MICRO_VERSION"
log_msg "  PREVIOUS_VERSION: $PREVIOUS_VERSION"
log_msg "  PUBKEY: $PUBKEY"
log_msg "  EXEC_CMDS: $EXEC_CMDS"
log_msg "  DEPS_ONLY: $DEPS_ONLY"

# Set OBS top-level project directory
PROJECT_TOP="OpenHPC"
if [[ "$MAJOR_VERSION" -ge 3 ]]; then
	PROJECT_TOP="OpenHPC${MAJOR_VERSION}"
fi

# First, sync from Dep:Release repository
log_msg "Starting Dep:Release repository sync..."
DEP_RELEASE_PATH="${PROJECT_TOP}/4.x:/Dep:/Release/"

# Determine destination for Dep:Release sync
if [[ "$MINOR_DIGIT" == "0" ]] && [ -z "${MICRO_VERSION}" ]; then
	DEP_DESTINATION="$REPO_DIR/OpenHPC/$MAJOR_VERSION/"
else
	DEP_DESTINATION="$REPO_DIR/OpenHPC/$MAJOR_VERSION/update.${NEXT_VERSION}"
fi

if [ ! -d "$DEP_DESTINATION" ]; then
	mkdir -p "$DEP_DESTINATION"
fi

echo "----> syncing Dep:Release files to $DEP_DESTINATION"

cmd="rsync ${RSYNC_COMMON_FLAGS} rsync://${REPO}/${DEP_RELEASE_PATH} $DEP_DESTINATION"

if do_cmd "$cmd"; then
	dep_change=0
else
	dep_change=1
fi

log_msg "Dep:Release sync completed (status: $dep_change)"

# base version
if [[ "$MINOR_DIGIT" == "0" ]] && [ -z "${MICRO_VERSION}" ]; then

	if ${DEPS_ONLY}; then
		echo "--> Dependencies only mode: skipping Factory sync for base version"
		DESTINATION="$DEP_DESTINATION"
		change=$dep_change
	else
		echo "--> pulling initial base version release."
		DESTINATION="$REPO_DIR/OpenHPC/$MAJOR_VERSION/"

		if [ ! -d "$DESTINATION" ]; then
			mkdir -p "$DESTINATION"
		fi

		echo "----> staging files in $DESTINATION"

		cmd="rsync ${RSYNC_COMMON_FLAGS} ${RSYNC_FACTORY_FLAGS} rsync://${REPO}/${PROJECT_TOP}/${MINOR_VERSION}:/${FACTORY} $DESTINATION"

		if do_cmd "$cmd"; then
			factory_change=0
		else
			factory_change=1
		fi

		# Combine changes from both Dep:Release and Factory syncs
		change=$((dep_change || factory_change))
	fi

else
	if ${DEPS_ONLY}; then
		echo "--> Dependencies only mode: skipping Factory sync for update version"
		DESTINATION="$DEP_DESTINATION"
		change=$dep_change
	else
		echo "--> pulling update version..."
		DESTINATION="$REPO_DIR/OpenHPC/$MAJOR_VERSION/update.${NEXT_VERSION}"
		if [ ! -d "$DESTINATION" ]; then
			mkdir -p "$DESTINATION"
		fi

		echo "----> staging files in $DESTINATION"

		cmd="rsync ${RSYNC_COMMON_FLAGS} ${RSYNC_FACTORY_FLAGS} rsync://${REPO}/${PROJECT_TOP}/${NEXT_VERSION}:/${FACTORY} $DESTINATION"
		if do_cmd "$cmd"; then
			factory_change=0
		else
			factory_change=1
		fi

		# Combine changes from both Dep:Release and Factory syncs
		change=$((dep_change || factory_change))
	fi

	if ! ${DEPS_ONLY}; then
		echo "----> merge of update repository"

		echo "----> creating hard links for packages in current production update repo (v$PREVIOUS_VERSION)..."
		pushd "$DESTINATION" >/dev/null

		# make sure all arch directories exist in order to preserve
		# packages from previous minor releases

		ARCHES="x86_64 aarch64 noarch src"

		OSES=$(find . -maxdepth 1 ! -path .)

		for os in $OSES; do
			for arch in $ARCHES; do
				if [ ! -d "$os/$arch" ]; then
					echo "----> creating $os/$arch directory..."
					mkdir -p "$os/$arch"
				fi
			done
		done

		for arch in $ARCHES; do
			echo "----> setting up links for $arch packages..."

			for dir in **/"$arch"; do
				if ! ls "$dir"/*rpm* >/dev/null 2>&1; then
					continue
				fi
				pushd "$dir" >/dev/null
				# cache list of newly updated packages using array instead of string
				PREVIOUS_RPMS=(*.rpm)

				echo "------> ln /repos/OpenHPC/$MAJOR_VERSION/update.${PREVIOUS_VERSION}/$dir/*.rpm ."
				for oldrpm in /repos/OpenHPC/"${MAJOR_VERSION}"/update."${PREVIOUS_VERSION}"/"${dir}"/*.rpm; do
					if [[ "${oldrpm}" == *"*.rpm" ]]; then
						continue
					fi
					# Use parameter expansion instead of basename subprocess
					pkg="${oldrpm##*/}"
					if [ ! -e "${pkg}" ]; then
						ln "${oldrpm}" .
					fi
				done

				# Pre-cache RPM package names to avoid repeated rpm command calls
				echo "------> caching package names for performance..."
				declare -A rpm_to_name
				for rpm in *.rpm; do
					[[ -e "${rpm}" ]] || continue
					rpm_name=$(rpm --queryformat='%{Name}\n' -qp "${rpm}" 2>/dev/null || echo "unknown")
					rpm_to_name["${rpm}"]="${rpm_name}"
				done

				# remove any older packages that are superseded by current release
				for rpm in "${PREVIOUS_RPMS[@]}"; do
					[[ -e "${rpm}" ]] || continue

					found=0
					pkg="${rpm_to_name[${rpm}]}"
					[[ -n "${pkg}" && "${pkg}" != "unknown" ]] || continue

					for file in "${pkg}"*.rpm; do
						[[ -e "${file}" ]] || continue
						if [ "./${file}" == "./${rpm}" ]; then
							continue
						fi
						PKG_NAME="${rpm_to_name[${file}]}"
						if [ "${pkg}" == "${PKG_NAME}" ]; then
							echo "------> ${file} -> replaced by ${rpm}; removing ${file}"
							rm "${file}"
							found=1
						fi
					done
					if [[ $found -eq 0 ]]; then
						echo "------> warning: did not detect previous version for ${rpm}."
						echo "                 please verify this is a new package (or included in original .0 release)"
						echo "                 $dir"
					fi
				done
				popd >/dev/null
			done

		done

		popd >/dev/null
	fi

fi

if [ "${change}" -eq 1 ]; then
	log_msg "Changes detected - starting RPM repository metadata generation"

	pushd "${DESTINATION}" >/dev/null

	# Use native bash glob instead of find subprocess
	shopt -s nullglob
	localDirs=(*/.)
	localDirs=("${localDirs[@]%/.}")
	shopt -u nullglob

	echo "--> found ${#localDirs[@]} OS directories to process"
	createrepo_c --version

	# Parallel createrepo processing with controlled concurrency
	max_parallel=4
	active_jobs=0
	declare -a job_pids=()

	for dir in "${localDirs[@]}"; do
		echo "--> starting repo data generation for ${dir}..."

		{
			echo "  --> generating repo data in ${dir}..."
			createrepo_c -v --outputdir "${dir}" --update "${dir}" --workers 6

			echo "  --> copying public key for ${dir}..."
			cp "${PUBKEY}" "${dir}/repodata/repomd.xml.key"
			chmod 644 "${dir}/repodata/repomd.xml.key"

			echo "  --> signing repomd.xml for ${dir}..."
			gpg --batch --no-tty -ba --yes --pinentry-mode loopback \
				--output "${dir}/repodata/repomd.xml.asc" \
				"${dir}/repodata/repomd.xml"

			echo "  --> completed repo data generation for ${dir}"
		} &

		job_pid=$!
		job_pids+=("${job_pid}")
		active_jobs=$((active_jobs + 1))

		echo "--> launched job ${job_pid} for ${dir} (${active_jobs}/${max_parallel} active)"

		# Wait for some jobs to complete if we hit the concurrency limit
		if [[ ${active_jobs} -ge ${max_parallel} ]]; then
			echo "--> waiting for a job to complete (${active_jobs}/${max_parallel} active)..."
			wait -n # Wait for any job to complete
			active_jobs=$((active_jobs - 1))
			echo "--> job completed, now ${active_jobs}/${max_parallel} active"
		fi
	done

	# Wait for all remaining jobs to complete
	echo "--> waiting for all remaining createrepo jobs to complete..."
	for pid in "${job_pids[@]}"; do
		if kill -0 "${pid}" 2>/dev/null; then
			echo "--> waiting for job ${pid} to complete..."
			wait "${pid}"
			echo "--> job ${pid} completed successfully"
		fi
	done
	echo "--> all createrepo operations completed successfully"

	popd >/dev/null
else
	log_msg "No repository changes detected - skipping metadata generation"
fi

if [ "${MAJOR_VERSION}" -eq 2 ]; then
	ln -snf EL_8 "${DESTINATION}/CentOS_8"
fi

# Final safety check - wait for any remaining background jobs
jobs_count=$(jobs -r | wc -l)
if [[ ${jobs_count} -gt 0 ]]; then
	log_msg "Waiting for ${jobs_count} remaining background jobs to complete..."
	wait
fi

END=$(date +%s)
((DURATION = END - START))

log_msg "Script $0 finished successfully after $(date -d@"${DURATION}" -u +%H:%M:%S)"
