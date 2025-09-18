#!/bin/bash
# shellcheck disable=SC2154

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
		osLocal=$(grep "VERSION=" /etc/os-release | awk -F = '{print $2}' | tr -d '"')
		osLocal="SLES $osLocal"
	elif [ -e /etc/redhat-release ]; then
		osLocal=$(cat /etc/redhat-release)
	elif [ -e /usr/share/licenses/openSUSE-release ]; then
		osLocal=$(grep "PRETTY_NAME=" /etc/os-release | awk -F = '{print $2}' | tr -d '"')
	elif [ -e /etc/openEuler-release ]; then
		osLocal=$(cat /etc/openEuler-release)
	else
		ERROR "Unknown baseOS distribution"
	fi

	echo "--> $osLocal"
	echo " "
}

loop_command() {
	local retry_counter=0
	local max_retries=5

	while true; do
		((retry_counter += 1))
		if [ "${retry_counter}" -gt "${max_retries}" ]; then
			ERROR "Failed to run: $*"
		fi
		# shellcheck disable=SC2068
		$@ && break

		# In case it is a network error let's wait a bit.
		echo "Retrying attempt ${retry_counter}"
		sleep "${retry_counter}"
	done
}

show_pwd() {
	echo "Launching CI run test from directory $(pwd)"
	echo "--> OpenHPC revision       = $Version"
}

show_runtime_config() {
	test -z "${DISTRIBUTION}" && ERROR "Variable DISTRIBUTION not defined"

	echo " "
	echo "Requested runtime configuration parameters:"
	echo "--> DISTRIBUTION           = ${DISTRIBUTION}"
	echo "--> os_major               = ${os_major}"

	test -z "${Repo}" && ERROR "Variable Repo not defined"
	echo "--> Repo config            = ${Repo}"

	echo "--> SMS nodename           = ${SMS}"

	test -z "${Interactive}" && ERROR "Variable Interactive not defined"

	if [ "${Interactive}" != "true" ] && [ "${Interactive}" != "false" ]; then
		ERROR "Variable Interactive must be set to either true or false"
	fi

	echo "--> Interactive run        = ${Interactive}"
	echo "--> Enable long tests      = ${EnableLongTests}"
	echo "--> Num computes nodes     = ${NUM_EXPECTED}"
	echo "--> Root level tests       = ${RootLevelTests}"
	echo "--> User level tests       = ${UserLevelTests}"
	export num_computes=${NUM_EXPECTED}

	if [ "${InstallCluster}" != "true" ] && [ "${InstallCluster}" != "false" ]; then
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

	cd "${TESTDIR}" || ERROR "Unable to access top level CMT test dir"

	export BATS_JUNIT_FORMAT=1
	export BATS_ENABLE_TIMING=1
	export BATS_JUNIT_GROUP="RootLevelTests"
	export AUTOMAKE_JUNIT_FILE=1

	# expose input vars to test env
	if [ -s "${inputFile}" ]; then
		# shellcheck disable=SC1090
		. "${inputFile}"
	fi

	localOptions=""

	if [ "$CI_CLUSTER" == "zeus" ]; then
		localOptions="--enable-lustre"
	fi

	if [ "$CI_CLUSTER" == "moontower" ]; then
		if echo "${DISTRIBUTION}" | grep -q centos; then
			localOptions="--enable-lustre"
		fi
	fi
	if [[ ${CI_CLUSTER} == "lenovo" ]]; then
		echo "disabling nagios and ipmitool tests on ${CI_CLUSTER} CI cluster"
		echo "ipmitool test already fixed in the git repository"
		sed -e "/TESTS  += nagios/d" -i admin/Makefile.am
		sed -e "/TESTS += ipmitool/d" -i oob/Makefile.am
		if [[ "${DISTRIBUTION}" == "leap15.3" ]]; then
			sed -e "s,-Sg,-Sng,g" -i /home/ohpc-test/tests/admin/clustershell
		fi
	fi

	if [ "x${USER_TEST_OPTIONS}" != "x" ]; then
		echo " "
		echo "adding ${USER_TEST_OPTIONS} to root tests"
		echo " "
		localOptions="${USER_TEST_OPTIONS} $localOptions"
	fi

	# using set here to be careful for argument quoting
	eval set -- "${localOptions}"
	./configure "$@" || ERROR "Unable to configure root-level tests"

	make -k check
	ROOT_STATUS=$?

	cd - >&/dev/null || ERROR "changing directory failed"
	return "${ROOT_STATUS}"
}

run_user_level_tests() {
	echo " "
	echo "Running User-Level CMT tests"
	echo " "

	export TEST_USER="ohpc-test"

	chown -R "$TEST_USER:" "/home/${TEST_USER}/tests" || ERROR "Unable to update perms for $TEST_USER"
	cd "${TESTDIR}" || ERROR "Unable to access top level test dir ($TESTDIR)"

	local config_opts=""

	if [ "${EnableLongTests}" == "true" ]; then
		config_opts="--enable-long"
	fi

	if [ "${EnableOneAPI}" == "true" ]; then
		config_opts="--enable-psxe $config_opts"
	fi

	if [ "${EnableArmCompiler}" == "true" ]; then
		config_opts="$config_opts --with-compiler-families='gnu12 arm1'"
	fi

	if [ "x${USER_TEST_OPTIONS}" != "x" ]; then
		echo " "
		echo "adding ${USER_TEST_OPTIONS} to user tests"
		echo " "
		config_opts="${USER_TEST_OPTIONS} $config_opts"
	fi

	if [[ ${CI_CLUSTER} == "huawei" ]]; then
		# Reduce the number of tests requiring internet access.
		# The network is very unreliable here.
		config_opts="$config_opts --disable-singularity --disable-charliecloud"
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
		{
			echo "export FI_PROVIDER=\"tcp;ofi_rxm\""
			echo "export UCX_TLS=\"tcp\""
			#    echo "export UCX_NET_DEVICES=eth0,eth3" >> /tmp/user_integration_tests
			# update network setting after linaro data center re-location
			echo "export UCX_NET_DEVICES=eth3"
		} >>/tmp/user_integration_tests
	fi
	if [[ ${CI_CLUSTER} == "huawei" ]] && [[ "${DISTRIBUTION}" == "openEuler_22.03" ]]; then
		echo "export UCX_NET_DEVICES=eth0,eth2" >>/tmp/user_integration_tests
	elif [[ ${CI_CLUSTER} == "huawei" ]]; then
		echo "export UCX_NET_DEVICES=enp125s0f0" >>/tmp/user_integration_tests
	fi
	if [ "${CI_CLUSTER}" == "lenovo" ] && [ "${enable_ib}" -eq 1 ]; then
		echo "export UCX_NET_DEVICES=mlx5_0:1" >>/tmp/user_integration_tests
		# Those tests are not working with Open MPI and InfiniBand currently.
		config_opts="$config_opts --disable-opencoarrays --disable-imb"
		config_opts="$config_opts --disable-superlu_dist"
		config_opts="$config_opts --disable-fftw"
		if [ "${RMS}" == "openpbs" ]; then
			config_opts="$config_opts --disable-mpi4py"
		fi
	fi

	if [ "${enable_nvidia_gpu_driver}" == "1" ]; then
		config_opts="$config_opts --enable-cuda"
	fi
	cat <<EOF >>/tmp/user_integration_tests

cd "$TESTDIR/" || exit 1
./configure $config_opts || exit 1
time make -k VERBOSE=1 check
EOF

	chmod 755 /tmp/user_integration_tests
	sudo -u "${TEST_USER}" -i /tmp/user_integration_tests

	USER_STATUS=$?
	cd - >&/dev/null || ERROR "changing directory failed"
	return "${USER_STATUS}"
}

install_openHPC_cluster() {

	if [ ! -x "${recipeFile}" ]; then
		echo "Installation recipe not available locally (${recipeFile})"
		exit 1
	fi

	# Special CI modifications

	# SLES does not accept alias interfaces for dhcp (e.g. eth2:0). Amend
	# recipe to use underlying physical interface(s).

	if [[ $CI_CLUSTER == "hera" ]]; then

		if [[ $DISTRIBUTION == "sles12" || $DISTRIBUTION == "sles12sp1" || $DISTRIBUTION == "sles12sp2" ]]; then
			echo "CI Customization: setting DHCPD_INTERFACE=eth2 for sles on Hera"
			perl -pi -e 's/DHCPD_INTERFACE=\${sms_eth_internal}/DHCPD_INTERFACE=eth2/' "${recipeFile}"
		fi
	elif [[ $CI_CLUSTER == "moontower" ]]; then
		if [[ $DISTRIBUTION == "sles12" || $DISTRIBUTION == "sles12sp1" || $DISTRIBUTION == "sles12sp2" || $DISTRIBUTION == "sles12sp3" || $DISTRIBUTION == "sles12sp4" ]]; then
			echo "CI Customization: setting DHCPD_INTERFACE=eth2 for sles on Moontower"
			perl -pi -e 's/DHCPD_INTERFACE=\${sms_eth_internal}/DHCPD_INTERFACE=eth0/' "${recipeFile}"
		fi
	elif [[ $CI_CLUSTER == "huawei" ]]; then
		if [ "${Provisioner}" == "warewulf" ]; then
			echo "CI Customization: console=tty0 breaks the compute nodes"
			sed '/dnf -y install ohpc-warewulf/a sed -e "s,# \\(database chunk size\\),\\1,g" -i /etc/warewulf/database.conf' -i "${recipeFile}"
			sed '/dnf -y install ohpc-warewulf/a sed -e "s,console=tty0,,g" -i /usr/share/perl5/vendor_perl/Warewulf/Provision/Pxe.pm' -i "${recipeFile}"
		fi
		if [ "${Provisioner}" == "warewulf4" ]; then
			echo "CI Customization: Switch to http in repository definition"
			sed "/export CHROOT/a sed -i '/\\\/metalink?/ s/$/\\\&protocol=http/g' \$CHROOT/etc/yum.repos.d/*repo" -i "${recipeFile}"
			sed "/export CHROOT/a sed -i '/\\\/mirrorlist?/ s/$/\\\&protocol=http/g' \$CHROOT/etc/yum.repos.d/*repo" -i "${recipeFile}"
			echo "CI Customization: switch to local registry"
			sed '/dnf -y install ohpc-warewulf/a sed -e "s,console=tty0,,g" -i /usr/share/perl5/vendor_perl/Warewulf/Provision/Pxe.pm' -i "${recipeFile}"
			sed "s,ghcr.io/warewulf,ohpc-huawei-repo:5000,g" -i "${recipeFile}"
			mkdir -p /root/.config/containers
			echo -e "[registries.insecure]\nregistries = ['ohpc-huawei-repo']" >/root/.config/containers/registries.conf
			echo "CI Customization: Use OpenHPC repository files from host"
			# shellcheck disable=SC2016
			sed '/export CHROOT/a /usr/bin/cp -vf /etc/yum.repos.d/OpenHPC*repo $CHROOT/etc/yum.repos.d' -i "${recipeFile}"
		fi
	elif [[ $CI_CLUSTER == "lenovo" ]]; then
		echo "CI Customization: PXE boot selection is not persistent"
		sed -e 's,ipmitool,ipmitool -E -I lanplus -H ${c_bmc[$i]} -U ${bmc_username} -P ${bmc_password} chassis bootdev pxe options=efiboot; ipmitool,g' -i "${recipeFile}"
		if [ "${PKG_MANAGER}" == "dnf" ]; then
			# shellcheck disable=SC2016
			sed -e 's,/etc/yum.repos.d$,/etc/yum.repos.d; echo -e "[main]\nuser_agent=curl" > $CHROOT/etc/dnf/dnf.conf,g' -i "${recipeFile}"
		fi
		if [ "${Provisioner}" == "confluent" ]; then
			echo "CI Customization: Switch to http in repository definition"
			sed '/excludedocs/a nodersync /etc/yum.repos.d/ compute:/etc/yum.repos.d/' -i "${recipeFile}"
			sed '/excludedocs/a nodersync /etc/dnf/dnf.conf compute:/etc/dnf/dnf.conf' -i "${recipeFile}"
			sed '/excludedocs/a nodersync /etc/profile.d/proxy.sh compute:/etc/profile.d/proxy.sh' -i "${recipeFile}"
			echo "CI Customization: Switch to text mode installer (nouveau crashes otherwise)"
			local PROFILE
			PROFILE=$(grep "nodedeploy -n compute" "${recipeFile}" | cut -d\  -f 5)
			sed "/nodesetboot compute network/a sed -e 's,\\\\(initrd=distribution\\\\),\\\\1 modprobe.blacklist=nouveau,g' -i /var/lib/confluent/public/os/${PROFILE}/boot.ipxe" -i "${recipeFile}"
		fi
		if [ "${Provisioner}" == "openchami" ]; then
			echo "CI Customization: Switch to http in repository definition"
			sed -e "s,https://dl,http://dl,g" -i "${recipeFile}"
		fi
		if [ "${Provisioner}" == "warewulf4" ]; then
			echo "CI Customization: Switch to http in repository definition"
			sed "/export CHROOT/a sed -i '/\\\/metalink?/ s/$/\\\&protocol=http/g' \$CHROOT/etc/yum.repos.d/*repo" -i "${recipeFile}"
			sed "/export CHROOT/a sed -i '/\\\/mirrorlist?/ s/$/\\\&protocol=http/g' \$CHROOT/etc/yum.repos.d/*repo" -i "${recipeFile}"
			echo "CI Customization: Switch to user_agent=curl"
			# shellcheck disable=SC2016
			sed '/export CHROOT/a echo  "user_agent=curl" >> $CHROOT/etc/dnf/dnf.conf' -i "${recipeFile}"
			echo "CI Customization: Use OpenHPC repository files from host"
			# shellcheck disable=SC2016
			sed '/export CHROOT/a /usr/bin/cp -vf /etc/yum.repos.d/OpenHPC*repo $CHROOT/etc/yum.repos.d' -i "${recipeFile}"
		fi
		if [ "${Provisioner}" == "warewulf" ] && [ "${PKG_MANAGER}" == "zypper" ]; then
			sed -e "s,install nhc-ohpc,install nhc-ohpc attr,g" -i "${recipeFile}"
		fi
		if [ "${enable_ib}" -eq 1 ] || [ "${Provisioner}" == "warewulf" ]; then
			echo "CI Customization: Install opensm on compute node"
			# for warewulf stateless provisioning we need a way to install opensm on one of the compute nodes
			sed -e "s,\(dnf -y --installroot=\$CHROOT groupinstall \"InfiniBand Support\"\),\1 ; \
				dnf -y --installroot=\$CHROOT install opensm; chroot \$CHROOT systemctl enable opensm,g" -i "${recipeFile}"
			# switch mellanox cards to InfiniBand mode: mstconfig -d 8a:00.0 set LINK_TYPE_P1=1
		fi
	else
		echo "No CI specialization"
	fi
	echo "DISTRIBUTION = $DISTRIBUTION"
	echo "CI_CLUSTER = $CI_CLUSTER"

	if [ "${EnableArmCompiler}" == "true" ]; then
		# enable local ARM1 repository
		sed -e "s,install arm1-compilers-devel-ohpc,install --enablerepo=ARM1 arm1-compilers-devel-ohpc,g" -i "${recipeFile}"
	fi
	# -------------------
	# Run install recipe
	# -------------------

	export OHPC_INPUT_LOCAL="${inputFile}"

	bash -x "${recipeFile}"

	if [ "${Provisioner}" == "confluent" ]; then
		# Activate latest updates and reboot
		/opt/confluent/bin/nodepower compute boot
	fi

	wait_for_computes

	# Verify we have all the expected hosts available

	export BATS_JUNIT_FORMAT=1
	export BATS_JUNIT_GROUP="RootLevelTests"

	cp "${CWD}/computes_installed.py" .
	if ! python3 computes_installed.py; then
		status=1
	fi
}

post_install_cmds() {
	# expose input vars to test env
	if [ -s "${inputFile}" ]; then
		# shellcheck disable=SC1090
		. "${inputFile}"
	fi

	if [ "${Provisioner}" == "confluent" ]; then
		# MANPATH is not correctly setup and breaks our tests
		sed "/MANPATH/d" -i /etc/profile.d/confluent_env.sh
	fi

	echo "Installing test-ohpc RPM"
	install_package test-suite-ohpc

	echo "Syncing user credentials"
	if [ "${Provisioner}" == "warewulf" ]; then
		wwsh file sync
		local_sleep 10
	elif [ "${Provisioner}" == "xcat" ]; then
		local_sleep 1
		/opt/xcat/bin/updatenode compute -F
	elif [ "${Provisioner}" == "openchami" ]; then
		pdcp -w "${compute_prefix}"[1-"${num_computes}"] /etc/passwd /etc/passwd
	elif [ "${Provisioner}" == "confluent" ]; then
		local_sleep 1
		/opt/confluent/bin/nodeapply -F compute
		# The test to check for same kernel on SMS and compute
		# does not work with confluent.
		# shellcheck disable=SC2016
		sed -e 's,assert_equal $kernel $sms_kernel,/bin/true,g' -i /home/ohpc-test/tests/bos/computes
	elif [ "${Provisioner}" == "warewulf4" ]; then
		wwctl overlay build
		local_sleep 10
		# The test to check for same kernel on SMS and compute
		# does not work with warewulf4 because the image
		# will not automatically boot the latest installed kernel.
		# shellcheck disable=SC2016
		sed -e 's,assert_equal $kernel $sms_kernel,/bin/true,g' -i /home/ohpc-test/tests/bos/computes
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
		# shellcheck disable=SC2181
		if [ $? -eq 0 ]; then
			echo "----> sleeping for ${waittime} secs"
			local_sleep "${waittime}"
			if [ "${Provisioner}" == "warewulf" ]; then
				koomie_cf -x "$compute_prefix\d+" /warewulf/bin/wwgetfiles
			elif [ "${Provisioner}" == "xcat" ]; then
				/opt/xcat/bin/updatenode compute -F
			elif [ "${Provisioner}" == "confluent" ]; then
				/opt/confluent/bin/nodeapply -F compute
			fi
		else
			echo "--> ohpc-test account present"
			break
		fi
	done

	if [[ "${DISTRIBUTION}" == "openEuler_22.03" ]]; then
		# Point to newer version of the java binary.
		# Without this Jenkins does not work.
		update-alternatives --set java \
			"$(rpm -ql java-11-openjdk-headless | grep -E 'bin/java$')"
		# needed to make valgrind work
		install_package glibc-debuginfo
	fi
	if [ "${RMS}" == "slurm" ]; then
		install_package slurm-sview-ohpc
	fi
	if [[ "${os_repo}" == "EL_"* ]]; then
		# Available from EPEL 8 and 9
		install_package perl-XML-Generator
	else
		local CPAN
		if [[ "${DISTRIBUTION}" == "leap"* ]]; then
			CPAN="perl-App-cpanminus"
		else
			CPAN="perl-CPAN"
		fi
		install_package "${CPAN}"
		# needed for the test-suite as long as openEuler and Leap
		# do not have the RPM.
		cpan -Tfi XML::Generator >>/root/cpan.log 2>&1
	fi

	if [[ "${DISTRIBUTION}" == "leap"* ]] && [[ ${CI_CLUSTER} == "huawei" ]]; then
		echo "Syncing time on compute nodes"
		pdsh -w "${compute_prefix}"[1-"${num_computes}"] "chronyc -m 'burst 3/3' 'makestep 0.1 3'"
	fi
}

gen_localized_inputs() {
	local MAPFILE
	local GEN_INPUTS
	MAPFILE="${CWD}/${CI_CLUSTER}.mapping"

	echo "bmc_password=${IPMI_PASSWORD}" >>"${MAPFILE}"

	GEN_INPUTS="perl ${CWD}/gen_inputs.pl \
		-i $inputTemplate \
		-o $inputFile \
		${MAPFILE}"
	if ! ${GEN_INPUTS}; then
		ERROR "Unable to generate localized input file"
	fi
	if [ "${EnableArmCompiler}" == "true" ]; then
		sed -i -e "s/enable_arm1_packages:-0/enable_arm1_packages:-1/" "${inputFile}"
	fi

	if [ "${EnableOneAPI}" == "true" ]; then
		sed -i -e "s/enable_intel_packages:-0/enable_intel_packages:-1/" "${inputFile}"
	fi

	if [[ "${DISTRIBUTION}" == "leap15.3" ]]; then
		# bats on leap 15.3 is too old. Just skip this.
		return
	fi

	echo
	echo "[Running SMS tests]"
	cp "${CWD}/sms_installed.bats" .
	if ! BATS_REPORT_FILENAME=sms_installed.log.xml ./sms_installed.bats; then
		# shellcheck disable=SC2034
		status=1
	fi
	echo
}

pre_install_cmds() {
	if [ -s "${inputFile}" ]; then
		# shellcheck disable=SC1090
		. "${inputFile}"
	fi
	if [ "${Provisioner}" == "confluent" ]; then
		echo "Downloading ISO image for compute nodes installation $(basename "${iso_path}")"
		wget -q http://10.241.58.130/"$(basename "${iso_path}")"
	fi
	if [[ "${DISTRIBUTION}" == "leap"* ]] && [[ ${CI_CLUSTER} == "huawei" ]]; then
		sed -e "s,download.opensuse.org/,mirrors.nju.edu.cn/opensuse/,g" -i /etc/zypp/repos.d/*repo
	fi
	"${PKG_MANAGER}" "${YES}" update

	if [ "${Provisioner}" == "openchami" ]; then
		((n_c = num_computes - 1))
		for j in $(seq 0 "${n_c}"); do
			echo "Updating /etc/hosts to have koomie_cf compatible entries"
			echo "${c_ip[$j]} ${c_name[$j]}.localdomain ${c_name[$j]}" >>/etc/hosts
		done
	fi

	if [ "${Provisioner}" == "warewulf4" ]; then
		# warewulf4 only configures SSH keys if there is no
		# /root/.ssh/cluster and /root/.ssh/config
		# warewulf3, however, expects SSH keys in /root/.ssh/cluster*
		rm -f /root/.ssh/cluster*
	fi

	if [[ ("${DISTRIBUTION}" == "rocky"* || "${DISTRIBUTION}" == "almalinux"*) ]] && [[ "${Architecture}" == "aarch64" ]]; then
		# On Rocky 9.2 on aarch64 there were errors like
		# "(Got a packet bigger than 'max_allowed_packet' bytes)".
		# This tries to fix that error:
		mkdir -p /etc/my.cnf.d/
		echo -e "[mysqld]\nmax_allowed_packet=1G\n" \
			>/etc/my.cnf.d/max-allowed-packet.cnf
	fi

	if command -v setenforce &>/dev/null; then
		setenforce 0
	fi

	if [ -n "${overwrite_rpm}" ]; then
		rpm -Uhv "${overwrite_rpm}" --force
	fi
	# needed for computes_installed.py test runner
	loop_command pip3 install unittest-xml-reporting
}

install_doc_rpm() {
	if [ "${Provisioner}" == "confluent" ] || [ "${Provisioner}" == "warewulf4" ]; then
		# Those packages are needed but pulled in by warewulf.
		# For confluent an extra step is needed. Works only on EL9.
		install_package perl-File-Copy perl-Log-Log4perl perl-Config-IniFiles
	fi
	install_package docs-ohpc
}

install_package() {
	"${PKG_MANAGER}" "${YES}" install "$@" || ERROR "Unable to install $*"
}

local_sleep() {
	local i
	echo -n "Sleeping "
	for i in $(seq "$1" -1 1); do
		echo -n "${i} "
		sleep 1
	done
	echo "done"
}

wait_for_computes() {
	if [ -s "${inputFile}" ]; then
		# shellcheck disable=SC1090
		. "${inputFile}"
	fi
	set -x
	# Sometimes the compute nodes take longer to appear than the
	# waittime specified in the recipe.
	CHECK_COMMAND=(koomie_cf -x "${compute_prefix}\\d+" cat /proc/uptime)
	waittime=20
	local not_ready
	not_ready=1
	local retry_counter
	local retry_counter_max
	retry_counter=0
	retry_counter_max=30

	for i in $(seq 90 -1 1); do
		echo "Waiting for compute nodes to get ready ($i)"
		if ! "${CHECK_COMMAND[@]}" | grep -E '(down|refused|booting|route|closed|disconnect|authenticity)'; then
			echo "All compute nodes are ready"
			not_ready=0
			break
		fi
		((retry_counter += 1))
		if [ "${retry_counter}" -gt "${retry_counter_max}" ]; then
			retry_counter=0
			if [[ $CI_CLUSTER == "lenovo" ]]; then
				((n_c = num_computes - 1))
				for j in $(seq 0 "${n_c}"); do
					echo "Telling BMC ${c_bmc[$j]} to try another reboot"
					ipmitool -E -I lanplus -H "${c_bmc[$j]}" -U "${bmc_username}" -P "${bmc_password}" chassis bootdev pxe options=efiboot
					ipmitool -E -I lanplus -H "${c_bmc[$j]}" -U "${bmc_username}" -P "${bmc_password}" power reset
				done
			fi
		fi
		local_sleep "${waittime}"
	done

	if [ "${not_ready}" -eq 1 ]; then
		ERROR "Not all compute nodes ready"
	fi

	if [[ $CI_CLUSTER == "lenovo" ]]; then
		# This is mainly necessary for confluent statefull provisioning
		pdsh -w "${compute_prefix}"[1-"${num_computes}"] systemctl disable --now firewalld
		if [ "${enable_ib}" -eq 0 ]; then
			# Disable IB
			pdsh -w "${compute_prefix}"[1-"${num_computes}"] rmmod mlx5_ib mlx5_core
		fi
	fi

	if [ "${Provisioner}" == "warewulf4" ]; then
		wwctl overlay build
		local_sleep 10
		# Mount all NFS. That sometimes fails.
		pdsh -w "${compute_prefix}"[1-"${num_computes}"] mount -t nfs -a
	fi

	if [ "${RMS}" == "slurm" ]; then
		pdsh -w "${compute_prefix}"[1-"${num_computes}"] systemctl restart munge
		pdsh -w "${compute_prefix}"[1-"${num_computes}"] systemctl restart slurmd
		scontrol update nodename="${compute_prefix}"[1-"${num_computes}"] state=idle
	fi

	if [ "${Provisioner}" == "warewulf" ]; then
		wwsh file sync
		local_sleep 10
	fi

	if [ "${Provisioner}" == "xcat" ]; then
		/opt/xcat/bin/updatenode compute -F
	fi
	set +x
}

enable_repo() {
	local VERSION_MAJOR_MINOR RELEASE_REPO STAGING_REPO RELEASE_RPM
	local VERSION_MAJOR_MINOR
	# is this an update (micro) release?
	VERSION_MINOR=$(echo "${Version}" | awk -F. '{print $2}')
	VERSION_MICRO=$(echo "${Version}" | awk -F. '{print $3}')
	VERSION_MAJOR_MINOR=$(echo "${Version}" | awk -F. '{print $1"."$2}')

	# shellcheck disable=SC2153
	echo "VERSION_MAJOR=${VERSION_MAJOR}"
	echo "VERSION_MINOR=${VERSION_MINOR}"
	if [ -n "${VERSION_MICRO}" ]; then
		echo "VERSION_MICRO=${VERSION_MICRO}"
	fi
	echo "VERSION_MAJOR_MINOR=${VERSION_MAJOR_MINOR}"

	RELEASE_REPO="http://repos.openhpc.community/OpenHPC/${VERSION_MAJOR}"
	STAGING_REPO="http://repos.openhpc.community/.staging/OpenHPC/${VERSION_MAJOR}"
	if [[ "${VERSION_MAJOR}" == "2" ]]; then
		OBS_KEY="https://obs.openhpc.community/projects/OpenHPC/public_key"
	else
		if [[ "${VERSION_MINOR}" != "0" ]]; then
			OBS_KEY="https://obs.openhpc.community/projects/OpenHPC${VERSION_MAJOR}/public_key"
		else
			OBS_KEY="http://obs.openhpc.community:82/OpenHPC${VERSION_MAJOR}:/${VERSION_MAJOR}.0:/Factory/${os_repo}/repodata/repomd.xml.key"
		fi
	fi
	STAGING_REPO_KEY="${STAGING_REPO}/${os_repo}/repodata/repomd.xml.key"
	RELEASE_REPO_KEY="${RELEASE_REPO}/${os_repo}/repodata/repomd.xml.key"

	rpm --import "${OBS_KEY}"
	rpm --import "${STAGING_REPO_KEY}"
	rpm --import "${RELEASE_REPO_KEY}"

	if [[ "${Repo}" != "Factory" ]]; then
		# The "Factory" repository is setup via ansible.
		# Remove the "Factory" repository if not testing "Factory"
		rm -vf /etc/yum.repos.d/OpenHPC-obs-factory.repo /etc/zypp/repos.d/OpenHPC-obs-factory.repo
	fi

	if [[ "${VERSION_MINOR}" != "0" ]] || [ -n "${VERSION_MICRO}" ]; then
		# If not testing the initial release we always want to install
		# the release RPM.
		RELEASE_RPM="${RELEASE_REPO}/${os_repo}/${Architecture}/ohpc-release-${VERSION_MAJOR}-1${os_dist}.${Architecture}.rpm"
	fi
	if [[ "${Repo}" == "Release" ]]; then
		RELEASE_RPM="${RELEASE_REPO}/${os_repo}/${Architecture}/ohpc-release-${VERSION_MAJOR}-1${os_dist}.${Architecture}.rpm"
	fi
	if [[ "${Repo}" == "Staging" ]]; then
		# need staging repo if this is first release in the series...
		if [[ "${VERSION_MINOR}" == "0" ]] && [ -z "${VERSION_MICRO}" ]; then
			RELEASE_RPM="${STAGING_REPO}/${os_repo}/${Architecture}/ohpc-release-${VERSION_MAJOR}-1${os_dist}.${Architecture}.rpm"
		else
			RELEASE_RPM="${RELEASE_REPO}/${os_repo}/${Architecture}/ohpc-release-${VERSION_MAJOR}-1${os_dist}.${Architecture}.rpm"
		fi
	fi

	if [ -n "${RELEASE_RPM}" ]; then
		echo "RELEASE_RPM = ${RELEASE_RPM}"

		install_package "${RELEASE_RPM}"
	fi

	# Use .staging area for final release testing (assuming this is not an upgrade test)
	if [ "${Upgrade}" == "false" ]; then
		if [[ "${Repo}" == "Staging" ]]; then
			sed -e 's|community/OpenHPC/|community/.staging/OpenHPC/|' \
				-i "${repo_file}" || ERROR "Unable to use staging repo"
			if [[ "${DISTRIBUTION}" =~ "leap" ]]; then
				"${PKG_MANAGER}" clean -a
			fi
		fi
	fi
}

switch_repo_to_http() {
	if [[ "${os_repo}" == "EL_"* ]]; then
		sed -i '/\/metalink?/ s/$/\&protocol=http/g' "${repo_dir}/"*repo
		sed -i '/\/mirrorlist?/ s/$/\&protocol=http/g' "${repo_dir}/"*repo
	fi
}
