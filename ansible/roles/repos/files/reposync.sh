#!/bin/bash

set -o pipefail
set -e

EXEC_CMDS=false
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
	echo "  -h                    Show this help"
}

while getopts "hen:p:" OPTION; do
	case ${OPTION} in
	e)
		EXEC_CMDS=true
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
PUBKEY=/home/ohpc/ohpc.key

do_cmd() {
	echo "------> raw command = $1"
	command=$(echo "$1" | awk '{print $1}')

	mystatus=0
	if ${EXEC_CMDS}; then
		output=$($cmd)
		mystatus=$?
		echo "$output"
		if [[ "$command" == "rsync" ]]; then
			if [[ -n $output ]]; then
				mystatus=1
			fi
		fi

	else
		echo "[skipping command]"
	fi

	echo "return status = $mystatus"
	return "${mystatus}"
}

FACTORY='Factory/'

MAJOR_VERSION=$(echo "${NEXT_VERSION}" | cut -d '.' -f1)
MINOR_VERSION=$(echo "${NEXT_VERSION}" | cut -d '.' -f1,2)
MINOR_DIGIT=$(echo "${NEXT_VERSION}" | cut -d '.' -f2)
MICRO_VERSION=$(echo "${NEXT_VERSION}" | cut -d '.' -f3)

echo "--> Syncing RPMS from $REPO"

echo "--> MAJOR_VERSION = $MAJOR_VERSION"
echo "--> MINOR_VERSION = $MINOR_VERSION"
echo "--> MICRO_VERSION = $MICRO_VERSION"
echo "--> PREVIOUS_VERSION = $PREVIOUS_VERSION"

# Set OBS top-level project directory
PROJECT_TOP="OpenHPC"
if [[ "$MAJOR_VERSION" -ge 3 ]]; then
	PROJECT_TOP="OpenHPC${MAJOR_VERSION}"
fi

# base version
if [[ "$MINOR_DIGIT" == "0" ]] && [ -z "${MICRO_VERSION}" ]; then

	echo "--> pulling initial base version release."
	DESTINATION="$REPO_DIR/OpenHPC/$MAJOR_VERSION/"

	if [ ! -d "$DESTINATION" ]; then
		mkdir -p "$DESTINATION"
	fi

	echo "----> staging files in $DESTINATION"

	cmd="rsync -avHKL --delete --exclude OpenHPC*.repo --exclude repocache --exclude repodata \
           --exclude updates --delay-updates \
         rsync://${REPO}/${PROJECT_TOP}/${MINOR_VERSION}:/${FACTORY} $DESTINATION"

	do_cmd "$cmd" || true
	change=$?

else
	echo "--> pulling update version..."
	DESTINATION="$REPO_DIR/OpenHPC/$MAJOR_VERSION/update.${NEXT_VERSION}"
	if [ ! -d "$DESTINATION" ]; then
		mkdir -p "$DESTINATION"
	fi

	echo "----> staging files in $DESTINATION"

	cmd="rsync -avHKL --delete --exclude OpenHPC*.repo --exclude repocache --exclude repodata \
          --exclude updates --delay-updates \
          rsync://${REPO}/${PROJECT_TOP}/${NEXT_VERSION}:/${FACTORY} $DESTINATION"
	do_cmd "$cmd" || true
	change=$?

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
			# cache list of newly updated packages
			PREVIOUS_RPMS=$(ls ./*rpm*)

			echo "------> ln /repos/OpenHPC/$MAJOR_VERSION/update.${PREVIOUS_VERSION}/$dir/*.rpm ."
			for oldrpm in /repos/OpenHPC/"${MAJOR_VERSION}"/update."${PREVIOUS_VERSION}"/"${dir}"/*.rpm; do
				if [[ "${oldrpm}" == *"*.rpm" ]]; then
					continue
				fi
				pkg=$(basename "${oldrpm}")
				if [ ! -e "${pkg}" ]; then
					ln "${oldrpm}" .
				fi
			done

			# remove any older packages that are superseded by current release
			for rpm in ${PREVIOUS_RPMS}; do
				if [ ! -e "${rpm}" ]; then
					continue
				fi
				found=0
				pkg=$(rpm --queryformat='%{Name}\n' -qp "${rpm}" 2>/dev/null)
				for file in "${pkg}"*.rpm; do
					if [ "./$file" == "$rpm" ]; then
						continue
					fi
					PKG_NAME=$(rpm --queryformat='%{Name}\n' -qp "${file}" 2>/dev/null)
					if [ "$pkg" == "$PKG_NAME" ]; then
						echo "------> $file -> replaced by $rpm; removing $file"
						rm "${file}"
						found=1
					fi
				done
				if [[ $found -eq 0 ]]; then
					echo "------> warning: did not detect previous version for $rpm."
					echo "                 please verify this is a new package (or included in original .0 release)"
					echo "                 $dir"
				fi
			done
			popd >/dev/null
		done

	done

	popd >/dev/null

	change=1

fi

if [ "${change}" -eq 1 ]; then
	echo "--> change detected. Generating RPM repodata"

	pushd "${DESTINATION}" >/dev/null

	localDirs=$(find . -maxdepth 1 -mindepth 1 -type d)

	for dir in $localDirs; do
		echo "--> generating repo data in $dir..."

		# First, remove repodata from OBS but retain gpg keys
		# find repodata/ -mindepth 1 ! -iname repomd.xml.key -delete
		# Create repository metadata
		# createrepo_c -v -c repocache --no-database --outputdir $dir --update $dir
		createrepo_c --version
		createrepo_c -v --outputdir "${dir}" --update "${dir}" --workers 6
		# Copy public key
		cp "${PUBKEY}" "${dir}/repodata/repomd.xml.key"
		chmod 644 "${dir}/repodata/repomd.xml.key"
		# Finally, sign the repomd.xml file
		gpg -ba --yes --output "${dir}/repodata/repomd.xml.asc" "${dir}/repodata/repomd.xml"
	done

	popd >/dev/null
else
	echo "--> no repository change detected"
fi

if [ "${MAJOR_VERSION}" -eq 2 ]; then
	ln -snf EL_8 "${DESTINATION}/CentOS_8"
fi

END=$(date +%s)
((DURATION = END - START))

echo -n "--> $0 finished after "
date -d@"${DURATION}" -u +%H:%M:%S
