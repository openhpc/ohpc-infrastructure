#!/bin/bash

set -o pipefail
set -e

DISTROS=("EL_9" "Leap_15" "openEuler_22.03")
ARCHES=("x86_64" "aarch64")

BASE_REPO_PATH="/repos/.staging/OpenHPC"
DEST_DIR="/repos/dist/"
TMPDIR="/repos/.staging/.tmp"
MAKE_REPO_SH="/home/ohpc/bin/make_repo.sh"
PUBLIC_KEY="/home/ohpc/RPM-GPG-KEY-OpenHPC-3"

show_usage() {
	echo "$0: script to create distribution tarballs"
	echo "Usage:"
	echo "  $0 [<options>]"
	echo
	echo "Options:"
	echo "  -v <VERSION>   Create distribution tarballs for version <VERSRION>"
	echo "  -h             Show this help"
}

while getopts "v:h" OPTION; do
	case $OPTION in
	v)
		VERSION=$OPTARG
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

if [ -z "$VERSION" ]; then
	show_usage
	exit 1
fi

DEST_DIR="${DEST_DIR}/${VERSION}"

VERSION_MAJOR=$(echo "${VERSION}" | awk -F. '{print $1}')
VERSION_MINOR=$(echo "${VERSION}" | awk -F. '{print $2}')

if [ ! -d "${DEST_DIR}" ]; then
	mkdir "${DEST_DIR}"
fi

if [ ! -d "${TMPDIR}" ]; then
	echo "ERROR: specified temporary directory (${TMPDIR}) does not exists. Exiting"
	exit 1
fi
export TMPDIR
TMP_DIR=$(mktemp -d)
trap 'echo "--> Deleting temporary directory ${TMP_DIR}"; rm -rf ${TMP_DIR}' EXIT QUIT HUP TERM

echo "OpenHPC dist creation utility"
echo "--> Requested release version = $VERSION"
echo "--> Staging dist creation in ${TMP_DIR}"
for DISTRO in "${DISTROS[@]}"; do
	SRC="${BASE_REPO_PATH}/${VERSION_MAJOR}/${DISTRO}"
	echo "--> Copying base repo contents from ${SRC}"
	cp -aLl --reflink=auto "${SRC}" "${TMP_DIR}"
	cat <<EOF >>"${TMP_DIR}/OpenHPC.local.repo"
[OpenHPC-local]
name=OpenHPC-${VERSION_MAJOR} - Base
baseurl=file://@PATH@/${DISTRO}
gpgcheck=1
gpgkey=file://@PATH@/RPM-GPG-KEY-OpenHPC-3
EOF

	if [[ "${VERSION_MINOR}" != "0" ]]; then
		SRC="${BASE_REPO_PATH}/${VERSION_MAJOR}/update.${VERSION}/${DISTRO}"
		DEST="${TMP_DIR}/${DISTRO}/updates"
		echo "--> Copying updates from ${SRC} to ${DEST}"
		cat <<EOF >>"${TMP_DIR}/OpenHPC.local.repo"
[OpenHPC-local-updates]
name=OpenHPC-${VERSION} - Updates
baseurl=file://@PATH@/${DISTRO}/updates
gpgcheck=1
gpgkey=file://@PATH@/RPM-GPG-KEY-OpenHPC-3
EOF
		cp -aLl --reflink=auto "${SRC}" "${DEST}"
	fi

	for ARCH in "${ARCHES[@]}"; do
		DIST_FILENAME="${DEST_DIR}/OpenHPC-${VERSION}.${DISTRO}.${ARCH}.tar"
		TAR_ARGS=("-cf" "${DIST_FILENAME}")
		for EXCLUDE_ARCH in "${ARCHES[@]}"; do
			if [ "${EXCLUDE_ARCH}" == "${ARCH}" ]; then
				continue
			fi
			TAR_ARGS+=("--exclude=${DISTRO}/${EXCLUDE_ARCH}")
			if [[ "${VERSION_MINOR}" != "0" ]]; then
				TAR_ARGS+=("--exclude=${DISTRO}/updates/${EXCLUDE_ARCH}")
			fi
		done

		TAR_ARGS+=("--exclude=${DISTRO}/iso")
		TAR_ARGS+=("--exclude=${DISTRO}/src")

		if [[ "${VERSION_MINOR}" != "0" ]]; then
			for EXCLUDE_DISTRO in "${DISTROS[@]}"; do
				if [ "${EXCLUDE_DISTRO}" == "${DISTRO}" ]; then
					continue
				fi
				TAR_ARGS+=("--exclude=${DISTRO}/updates/${EXCLUDE_DISTRO}")
			done
			TAR_ARGS+=("--exclude=${DISTRO}/updates/src")
		fi

		# exclude any OBS created .repo files
		TAR_ARGS+=("--exclude=${DISTRO}/OpenHPC*.repo")
		TAR_ARGS+=("--exclude=${DISTRO}/updates/OpenHPC*.repo")

		# exclude repocache
		TAR_ARGS+=("--exclude=${DISTRO}/repocache")
		TAR_ARGS+=("--exclude=${DISTRO}/updates/repocache")

		TAR_ARGS+=("-C" "${TMP_DIR}")

		if [[ "${DISTRO}" == "Leap"* ]]; then
			PACKAGE_MANAGER="zypper"
			PACKAGE_MANAGER_DIRECTORY="/etc/zypp/repos.d"
		else
			PACKAGE_MANAGER="dnf"
			PACKAGE_MANAGER_DIRECTORY="/etc/yum.repos.d"
		fi

		# add README
		cat <<EOF >>"${TMP_DIR}/README"
Many sites may find it useful or necessary to maintain a local copy of the
OpenHPC repositories. To facilitate this need, we provide downloadable tar
archives -- one containing a repository of binary packages as well as any
available updates, and one containing a repository of source RPMS. The tar file
also contains a small bash script to configure ${PACKAGE_MANAGER} to use the
local repository after download. To use, simply unpack the tarball where you
would like to host the local repository and execute the make_repo.sh script.

# ls /opt/ohpc/repos
${DISTRO} make_repo.sh OpenHPC-${VERSION}.${DISTRO}.${ARCH}.tar OpenHPC.local.repo README

# ./make_repo.sh
--> Creating OpenHPC.local.repo file in ${PACKAGE_MANAGER_DIRECTORY}
--> Local repodata stored in /opt/ohpc/repos

# cat ${PACKAGE_MANAGER_DIRECTORY}/OpenHPC.local.repo
EOF
		# add make_repo.sh
		cp -f "${MAKE_REPO_SH}" "${TMP_DIR}"
		cp -f "${PUBLIC_KEY}" "${TMP_DIR}"

		# Create tarball
		TAR_ARGS+=("${DISTRO}" "OpenHPC.local.repo" "make_repo.sh" "README" "${PUBLIC_KEY##*/}")
		echo "--> Creating dist tarball for ${DISTRO}:${ARCH}"
		echo "--> tar command -> tar " "${TAR_ARGS[@]}"

		tar "${TAR_ARGS[@]}"
	done
done

echo "--> Generating sha512 checksums"
cd "${DEST_DIR}"
sha512sum --tag -- *tar >"OpenHPC-${VERSION}.checksums"
gpg --yes --clearsign "OpenHPC-${VERSION}.checksums"
mv "OpenHPC-${VERSION}.checksums".asc "OpenHPC-${VERSION}.checksums"
echo "--> Dist tarballs available in ${DEST_DIR}"
