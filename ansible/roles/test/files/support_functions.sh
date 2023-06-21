#!/bin/bash

ERROR() {
	echo "[ERROR]: $1" >&2
	exit 1
}

show_CI_hosts() {
	test -z "${NODE_NAME}" && ERROR "Variable NODE_NAME not defined"
	test -z "${COMPUTE_HOSTS}" && ERROR "Variable COMPUTE_HOSTS not defined"
	test -z "${CI_CLUSTER}" && ERROR "Variable CI_CLUSTER not defined"

	echo "--> Cluster submaster host = ${NODE_NAME}"
	NUM_EXPECTED=$(echo "${COMPUTE_HOSTS}" | awk 'END{print NF}')
	echo "--> Num compute hosts      = ${NUM_EXPECTED}"
	echo "--> Assigned hosts         = ${COMPUTE_HOSTS}"

	SMS_HOST=$(echo "${COMPUTE_HOSTS}" | awk -F , '{print $1}' | sed s/node/sms/)
}

show_git_versions() {
	rev=$(git rev-parse HEAD)
	branch=$(git show -s --pretty=%d HEAD)
	echo "   --> branch =  $branch"
	echo "   --> sha1   =  $rev"
	echo " "
}

show_booted_os() {

	echo "Provisioned OS:"

	local osLocal=""

	if [ -e /etc/centos-release ]; then
		osLocal=$(cat /etc/centos-release)
	elif [ -e /etc/SuSE-release ]; then
		osLocal=$(cat /etc/os-release | grep VERSION= | awk -F = '{print $2}' | tr -d '"')
		osLocal="SLES $osLocal"
	elif [ -e /etc/redhat-release ]; then
		osLocal=$(cat /etc/redhat-release)
	elif [ -e /usr/share/licenses/openSUSE-release ]; then
		osLocal=$(cat /etc/os-release | grep PRETTY_NAME= | awk -F = '{print $2}' | tr -d '"')
	elif [ -e /etc/openEuler-release ]; then
		osLocal=$(cat /etc/openEuler-release)
	else
		ERROR "Unknown baseOS distribution"
	fi

	echo "--> $osLocal"
	echo " "
}

show_pwd() {
	echo "Launching jenkins test from $(pwd)"
	echo "--> OpenHPC revision       = $Version"
}

show_runtime_config() {
	test -z "${BaseOS}" && ERROR "Variable BaseOS not defined"

	echo " "
	echo "Requested runtime configuration parameters:"
	echo "--> BaseOS                 = ${BaseOS}"
	echo "--> os_major               = ${os_major}"

	test -z "${Repo}" && ERROR "Variable Repo not defined"
	echo "--> Repo config            = ${Repo}"

	echo "--> SMS nodename           = ${SMS}"

	test -z "${Interactive}" && ERROR "Variable Interactive not defined"

	if [ "${Interactive}" != "true" -a "${Interactive}" != "false" ]; then
		ERROR "Variable Interactive must be set to either true or false"
	fi

	echo "--> Interactive run        = ${Interactive}"
	echo "--> Enable long tests      = ${EnableLongTests}"
	echo "--> Num computes nodes     = ${NUM_EXPECTED}"
	echo "--> Root level tests       = ${RootLevelTests}"
	echo "--> User level tests       = ${UserLevelTests}"
	export num_computes=${NUM_EXPECTED}

	if [ "${InstallCluster}" != "true" -a "${InstallCluster}" != "false" ]; then
		ERROR "Variable InstallCluster must be set to either true or false"
	fi

	echo "--> Install Cluster        = ${InstallCluster}"
	echo "--> Upgrade Test           = ${Upgrade}"

}

run_root_level_tests() {
	echo
	echo "Running Root-Level CMT tests"
	echo
	export PATH=/opt/ohpc/pub/utils/autotools/bin:$PATH

	cd ${TESTDIR} || ERROR "Unable to access top level CMT test dir"

	export BATS_JUNIT_FORMAT=1
	export BATS_ENABLE_TIMING=1
	export BATS_JUNIT_GROUP="RootLevelTests"
	export AUTOMAKE_JUNIT_FILE=1

	# expose input vars to test env
	if [ -s ${inputFile} ]; then
		. ${inputFile}
	fi

	localOptions=""

	if [ "$CI_CLUSTER" == "zeus" ]; then
		localOptions="--enable-lustre"
	fi

	if [ "$CI_CLUSTER" == "moontower" ]; then
		echo $BaseOS | grep -q centos
		if [ $? -eq 0 ]; then
			localOptions="--enable-lustre"
		fi
	fi

	if [ "x${USER_TEST_OPTIONS}" != "x" ]; then
		echo " "
		echo "adding ${USER_TEST_OPTIONS} to root tests"
		echo " "
		localOptions="${USER_TEST_OPTIONS} $localOptions"
	fi

	# using set here to be careful for argument quoting
	eval set -- $localOptions
	./configure "$@" || ERROR "Unable to configure root-level tests"

	make -k check
	ROOT_STATUS=$?

	cd - >&/dev/null
	return $ROOT_STATUS
}

run_user_level_tests() {
	echo " "
	echo "Running User-Level CMT tests"
	echo " "

	TOPDIR=$(pwd)
	export TEST_USER="ohpc-test"

	chown -R $TEST_USER: /home/${TEST_USER}/tests || ERROR "Unable to update perms for $TEST_USER"
	cd $TESTDIR || ERROR "Unable to access top level test dir ($TESTDIR)"

	local config_opts=""

	if [ "${EnableLongTests}" == "true" ]; then
		config_opts="--enable-long"
	fi

	if [ "x${EnablePXSE}" == "xtrue" ]; then
		config_opts="--enable-psxe $config_opts"
	fi

	if [ "x${EnableOneAPI}" == "xtrue" ]; then
		config_opts="--enable-psxe $config_opts"
	fi

	if [ "x${USER_TEST_OPTIONS}" != "x" ]; then
		echo " "
		echo "adding ${USER_TEST_OPTIONS} to user tests"
		echo " "
		config_opts="${USER_TEST_OPTIONS} $config_opts"
	fi

	# Build test-script for execution

	cat <<EOF >/tmp/user_integration_tests
#!/bin/bash
export BATS_ENABLE_TIMING=1
export BATS_JUNIT_FORMAT=1
export BATS_JUNIT_GROUP="UserLevelTests"
export AUTOMAKE_JUNIT_FILE=1
export CI_CLUSTER="$CI_CLUSTER"
# needed for singularity as /tmp is mounted with 'nodev'
export SINGULARITY_TMPDIR=/var/tmp

# needed for impi 2019.x to allow singleton execution on head node
export FI_PROVIDER=sockets
EOF

	if [[ ${CI_CLUSTER} == "linaro" ]]; then
		echo "export FI_PROVIDER=\"tcp;ofi_rxm\"" >>/tmp/user_integration_tests
		echo "export UCX_TLS=\"tcp\"" >>/tmp/user_integration_tests
		#    echo "export UCX_NET_DEVICES=eth0,eth3" >> /tmp/user_integration_tests
		# update network setting after linaro data center re-location
		echo "export UCX_NET_DEVICES=eth3" >>/tmp/user_integration_tests
	fi
	if [[ ${CI_CLUSTER} == "huawei" ]]; then
		echo "export UCX_NET_DEVICES=enp189s0f0" >>/tmp/user_integration_tests
	fi

	cat <<EOF >>/tmp/user_integration_tests

cd "$TESTDIR/" || exit 1
./configure $config_opts || exit 1
time make -k VERBOSE=1 check
EOF

	chmod 755 /tmp/user_integration_tests
	sudo -u $TEST_USER -i /tmp/user_integration_tests

	USER_STATUS=$?
	cd - >&/dev/null
	return $USER_STATUS
}

install_openHPC_cluster() {

	if [ ! -x $recipeFile ]; then
		echo "Installation recipe not available locally ($recipeFile)"
		exit 1
	fi

	# Special CI modifications

	# SLES does not accept alias interfaces for dhcp (e.g. eth2:0). Ammend
	# recipe to use underlying physical interface(s).

	if [[ $CI_CLUSTER == "hera" ]]; then

		if [[ $BaseOS == "sles12" || $BaseOS == "sles12sp1" || $BaseOS == "sles12sp2" ]]; then
			echo "CI Customization: setting DHCPD_INTERFACE=eth2 for sles on Hera"
			perl -pi -e 's/DHCPD_INTERFACE=\${sms_eth_internal}/DHCPD_INTERFACE=eth2/' $recipeFile
		fi
	elif [[ $CI_CLUSTER == "moontower" ]]; then
		if [[ $BaseOS == "sles12" || $BaseOS == "sles12sp1" || $BaseOS == "sles12sp2" || $BaseOS == "sles12sp3" || $BaseOS == "sles12sp4" ]]; then
			echo "CI Customization: setting DHCPD_INTERFACE=eth2 for sles on Moontower"
			perl -pi -e 's/DHCPD_INTERFACE=\${sms_eth_internal}/DHCPD_INTERFACE=eth0/' $recipeFile
		fi
	else
		echo "No CI specialization"
		echo "BaseOS = $BaseOS"
		echo "CI_CLUSTER = $CI_CLUSTER"
	fi

	# -------------------
	# Run install recipe
	# -------------------

	export OHPC_INPUT_LOCAL=$inputFile

	bash -x $recipeFile

	# Verify we have all the expected hosts available

	export BATS_JUNIT_FORMAT=1
	export BATS_JUNIT_GROUP="RootLevelTests"

	# needed for computes_installed.py
	pip install xmlrunner

	cp /var/cache/jenkins-agent/computes_installed.py .
	python3 computes_installed.py
	if [ $? -ne 0 ]; then
		status=1
	fi
}

post_install_cmds() {
	# expose input vars to test env
	if [ -s ${inputFile} ]; then
		. ${inputFile}
	fi

	echo "Installing test-ohpc RPM"
	dnf -y install test-suite-ohpc

	echo "Syncing user credentials"
	if [ "${Provisioner}" == "warewulf" ]; then
		wwsh file sync
		sleep 10
	elif [ "${Provisioner}" == "xcat" ]; then
		sleep 1
		/opt/xcat/bin/updatenode compute -F
	else
		ERROR "Unknown provisioner type -> ${Provisioner}"
	fi

	# confirm we have the ohpc-test user...the wwgetfiles above could
	# potentially have failed if it was already spawned from crontab. So,
	# we retry if the test account is not available.
	#
	# wwgetfiles from default crontab entry should be no more than ~180
	# secs

	waittime=10

	for i in $(seq 1 20); do
		echo "Check #$i for ohpc-test account"
		koomie_cf -x "$compute_prefix\d+" id ohpc-test | grep "no such user"
		if [ $? -eq 0 ]; then
			echo "----> sleeping for ${waittime} secs"
			sleep ${waittime}
			if [ "${Provisioner}" == "warewulf" ]; then
				koomie_cf -x "$compute_prefix\d+" /warewulf/bin/wwgetfiles
			elif [ "${Provisioner}" == "xcat" ]; then
				/opt/xcat/bin/updatenode compute -F
			fi
		else
			echo "--> ohpc-test account present"
			break
		fi
	done

	if [[ "${BaseOS}" == "openEuler_22.03" ]]; then
		# Point to newer version of the java binary.
		# Without this Jenkins does not work.
		update-alternatives --set java \
			"$(rpm -ql java-11-openjdk-headless | grep -E 'bin/java$')"
		# needed to make valgrind work
		dnf -y install glibc-debuginfo
	fi
	if [ "${RMS}" == "slurm" ]; then
		dnf -y install slurm-sview-ohpc
	fi
	dnf -y install perl-CPAN
	# needed for the test-suite as long as openEuler
	# does not have the RPM.
	cpan -fi XML::Generator
}

gen_localized_inputs() {
	local MAPFILE
	local GEN_INPUTS
	MAPFILE="/var/cache/jenkins-agent/$CI_CLUSTER.mapping"

	echo "bmc_password=${IPMI_PASSWORD}" >>"${MAPFILE}"

	# shellcheck disable=SC2154
	GEN_INPUTS="perl /var/cache/jenkins-agent/gen_inputs.pl \
		-i $inputTemplate \
		-o $inputFile \
		${MAPFILE}"
	if ! ${GEN_INPUTS}; then
		ERROR "Unable to generate localized input file"
	fi
}

pre_install_cmds() {
	if [ -e /usr/bin/dnf ]; then
		dnf -y upgrade
	fi
	# shellcheck disable=SC2154
	if [[ "${BaseOS}" == "rocky"* ]] && [[ "${Architecture}" == "aarch64" ]]; then
		# On Rocky 9.2 on aarch64 there were errors like
		# "(Got a packet bigger than 'max_allowed_packet' bytes)".
		# This tries to fix that error:
		mkdir -p /etc/my.cnf.d/
		echo -e "[mysqld]\nmax_allowed_packet=1G\n" \
			>/etc/my.cnf.d/max-allowed-packet.cnf
	fi

	setenforce 0
}

install_doc_rpm() {
	if [ -e /usr/bin/dnf ]; then
		dnf -y install docs-ohpc || ERROR "Unable to install docs-ohpc"
	else
		zypper -n install docs-ohpc || ERROR "Unable to install docs-ohpc"
	fi
}
