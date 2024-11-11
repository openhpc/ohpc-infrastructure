#!/bin/bash

# determine standard repodir
repodir=""

if [ -s "/etc/os-release" ]; then
	grep -q "CentOS" /etc/os-release && repodir=/etc/yum.repos.d
	grep -q "el8" /etc/os-release && repodir=/etc/yum.repos.d
	grep -q "el9" /etc/os-release && repodir=/etc/yum.repos.d
	grep -q "openEuler" /etc/os-release && repodir=/etc/yum.repos.d
	grep -q "Red Hat" /etc/os-release && repodir=/etc/yum.repos.d
	grep -q "SLES" /etc/os-release && repodir=/etc/zypp/repos.d
	grep -q "Leap" /etc/os-release && repodir=/etc/zypp/repos.d
else
	echo "Error: no /etc/os-release file found"
	exit 1
fi

if [ -z "${repodir}" ]; then
	echo "Error: unknown or unsupported OS distro."
	echo "Please confirm local host matches an OpenHPC supported distro."
	exit 1
fi

if [ ! -d "${repodir}" ]; then
	echo "Error: unable to find local repodir (expected ${repodir})"
	exit 1
fi

# sufficient credentials?
if [ "$EUID" -ne 0 ]; then
	echo "Error: Elevated credentials required to create files in ${repodir}"
	exit 1
fi

# setup local OpenHPC repo using downloaded repodata
localRepoDir=$(dirname "$(readlink -f "$0")")
localRepoFile=OpenHPC.local.repo

echo "--> Creating $localRepoFile file in $repodir"
echo "--> Local repodata stored in $localRepoDir"

pushd "${localRepoDir}" >&/dev/null || exit 1

if [ -s "${localRepoFile}" ]; then
	cp -p "${localRepoFile}" "$repodir"
	# Update file path(s)
	sed -i "s,@PATH@,${localRepoDir},g" "${repodir}/${localRepoFile}"
else
	echo "Error: expected ${localRepoFile} missing"
	exit 1
fi

popd >&/dev/null || exit 1
