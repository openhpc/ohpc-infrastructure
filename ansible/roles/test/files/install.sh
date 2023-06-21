#!/bin/bash

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
	;;
rocky9.2)
	os_major=rocky9
	;;
*)
	echo "Unkown BaseOS ${BaseOS}. Exiting!"
	exit 1
	;;
esac

# load support functions
if [ ! -e /var/cache/jenkins-agent/support_functions.sh ]; then
	echo "ERROR: Support file support_functions.sh is missing"
	exit 1
fi

# shellcheck disable=SC1091
. /var/cache/jenkins-agent/support_functions.sh

if [ -e /etc/profile.d/proxy.sh ]; then
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

recipeFile=/opt/ohpc/pub/doc/recipes/${os_major}/${Architecture}/${Provisioner}/${RMS}/recipe.sh
inputTemplate=/opt/ohpc/pub/doc/recipes/${os_major}/input.local
inputFile=/root/ci_ohpc_inputs

install_doc_rpm

gen_localized_inputs

pre_install_cmds

if [ "${InstallCluster}" == "true" ]; then
	install_openHPC_cluster
	post_install_cmds
fi

if [ "${RootLevelTests}" == "true" ]; then
	run_root_level_tests
	if [ $? -ne 0 ]; then
		status=1
	fi
fi

if [ "${UserLevelTests}" == "true" ]; then
	run_user_level_tests
	if [ $? -ne 0 ]; then
		status=1
	fi
fi

exit $status
