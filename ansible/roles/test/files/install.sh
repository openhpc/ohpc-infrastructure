#!/bin/bash
# shellcheck disable=SC2154

echo
echo -----------------------------------------
echo 'OpenHPC Cluster Install / Jenkins wrapper'
echo -----------------------------------------
echo

for env in InstallCluster \
	COMPUTE_HOSTS \
	RMS \
	EnableLongTests \
	BUILD_CAUSE \
	SMS \
	Upgrade \
	BUILD_CAUSE_UPSTREAMTRIGGER \
	IPMI_PASSWORD \
	BUILD_NUMBER \
	CI_CLUSTER \
	enable_ipoib \
	Interactive \
	BUILD_DISPLAY_NAME \
	Version \
	EnableOneAPI \
	JOB_BASE_NAME \
	JOB_NAME \
	enable_ib \
	BaseOS \
	provision_wait \
	Architecture \
	UserLevelTests \
	NODE_NAME \
	YUM_MIRROR_BASE \
	LocalRepoFromDist \
	USER_TEST_OPTIONS \
	ohpc_tree \
	EXECUTOR_NUMBER \
	EnablePXSE \
	UseExternalRepo \
	RootLevelTests \
	NODE_LABELS \
	EnableArmCompiler \
	CI \
	DisableDefaultRepo \
	DefaultRepoConfig \
	Provisioner \
	RunLimit \
	BUILD_ID \
	Repo; do
	echo '--> ' ${env}=${!env}

done

case ${BaseOS} in
openEuler_22.03)
	os_major=openeuler22.03
	os_repo=openEuler_22.03
	os_dist=".oe2203"
	repo_dir=/etc/yum.repos.d
	;;
rocky9.2)
	os_major=rocky9
	os_repo=EL_9
	os_dist=".el9"
	repo_dir=/etc/yum.repos.d
	;;
rocky8.8)
	os_major=rocky8
	os_repo=EL_8
	os_dist=".el8"
	repo_dir=/etc/yum.repos.d
	;;
almalinux9.2)
	os_major=almalinux9
	os_repo=EL_9
	os_dist=".el9"
	repo_dir=/etc/yum.repos.d
	;;
leap15.5)
	os_major=leap15
	os_repo=Leap_15
	os_dist=".leap15"
	repo_dir=/etc/zypp/repos.d
	;;
leap15.3)
	os_major=leap15
	os_repo=Leap_15
	os_dist=".leap15"
	repo_dir=/etc/zypp/repos.d
	;;
*)
	echo "Unkown BaseOS ${BaseOS}. Exiting!"
	exit 1
	;;
esac

repo_file="${repo_dir}/OpenHPC.repo"
export os_major os_repo os_dist repo_file

if [[ "${BaseOS}" == "leap"* ]]; then
	PKG_MANAGER="zypper"
	YES="-n"
else
	PKG_MANAGER="dnf"
	YES="-y"
fi

echo "Using \"${PKG_MANAGER} ${YES}\" as package manager"

# load support functions
if [ ! -e /var/cache/jenkins-agent/support_functions.sh ]; then
	echo "ERROR: Support file support_functions.sh is missing"
	exit 1
fi

# shellcheck disable=SC1091
. /var/cache/jenkins-agent/support_functions.sh

if [ -e /etc/profile.d/proxy.sh ]; then
	# shellcheck disable=SC1091
	. /etc/profile.d/proxy.sh
fi

# Due to the network setup of the huawei test cluster
# there is not nameserver and no /etc/resolv.conf is
# created. Some tools fail if there is not resolv.conf.
# Let's just give them an empty file.
touch /etc/resolv.conf

show_booted_os
show_pwd
show_CI_hosts
show_runtime_config

export OHPC_INPUT_LOCAL=${inputFile}
echo "$IPMI_PASSWORD" >/root/password
export HOME=/root
export USER=root
export LOGNAME=root
export TESTDIR="${TESTDIR:-/home/ohpc-test/tests}"
export IPMI_PASSWORD

# shellcheck disable=SC2034
recipeFile=/opt/ohpc/pub/doc/recipes/${os_major}/${Architecture}/${Provisioner}/${RMS}/recipe.sh
# shellcheck disable=SC2034
inputTemplate=/opt/ohpc/pub/doc/recipes/${os_major}/input.local
inputFile=/root/ci_ohpc_inputs
status=0

enable_repo

install_doc_rpm

gen_localized_inputs

pre_install_cmds

if [ "${InstallCluster}" == "true" ]; then
	install_openHPC_cluster
	post_install_cmds
fi

if [ "${RootLevelTests}" == "true" ]; then
	if ! run_root_level_tests; then
		status=1
	fi
fi

if [ "${UserLevelTests}" == "true" ]; then
	if ! run_user_level_tests; then
		status=1
	fi
fi

exit "${status}"
