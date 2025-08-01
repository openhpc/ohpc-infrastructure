#!/bin/bash

set -o pipefail

START=$(date +%s)

show_usage() {
	echo "Usage"
	echo "  $0 [<options>]"
	echo
	echo "Options:"
	echo "  -d <DISTRIBUTION>     Run the CI test on the specified distribution"
	echo "  -v <VERSION>          Run the CI test on the specified version of OpenHPC"
	echo "  -r <REPOSITORY>       Run the CI test using the specified repository"
	echo "                        (Factory, Staging, Release)"
	echo "  -m <RMS>              Run the CI test using the specified resource manager"
	echo "                        (openpbs, slurm (default))"
	echo "  -p <PROVISIONER>      Run the CI test using the specified provisioner"
	echo "                        (confluent, warewulf (default))"
	echo "  -i                    Install and run tests using packages built with the"
	echo "                        Intel compiler"
	echo "  -g <GPU>              Run the CI test with GPU installation and tests enabled"
	echo "                        (nvidia, none (default))"
	echo "  -o <RPM>              Use this RPM to overwrite the default docs-ohpc RPM"
	echo "  -b                    Use InfiniBand"
	echo "  -n                    Don't upload test results"
	echo "  -h                    Show this help"
}

TIMEOUT="100"

while getopts "d:v:r:m:p:ig:nbo:h" OPTION; do
	case $OPTION in
	d)
		DISTRIBUTION=$OPTARG
		;;
	v)
		VERSION=$OPTARG
		;;
	r)
		REPO=$OPTARG
		;;
	m)
		RMS=$OPTARG
		;;
	p)
		PROVISIONER=$OPTARG
		;;
	i)
		WITH_INTEL="true"
		((TIMEOUT += 50))
		;;
	b)
		USE_IB="true"
		;;
	o)
		RPM=$OPTARG
		;;
	n)
		UPLOAD="false"
		;;
	g)
		WITH_GPU=$OPTARG
		((TIMEOUT += 50))
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

if [ -z "${RMS}" ]; then
	RMS=slurm
fi

if [ -z "${WITH_GPU}" ]; then
	WITH_GPU=none
fi

if [ -z "${PROVISIONER}" ]; then
	PROVISIONER=warewulf
fi

if [ -z "${DISTRIBUTION}" ] || [ -z "${VERSION}" ] || [ -z "${REPO}" ]; then
	show_usage
	exit 0
fi

if [ ! -e /etc/sysconfig/openhpc-test.config ]; then
	echo "Input file /etc/sysconfig/openhpc-test.config missing"
	exit 1
fi

# shellcheck disable=SC1091
. /etc/sysconfig/openhpc-test.config

if [[ "${SMS}" == "ohpc-lenovo-sms" ]]; then
	LAUNCHER="lenovo_launch_sms.sh"
elif [[ "${SMS}" == "ohpc-huawei-sms" ]]; then
	LAUNCHER="huawei_launch_sms.sh"
else
	echo "Unknown system. Exiting"
	exit 1
fi

cd ../../../../

LOG=$(mktemp)
OUT=$(mktemp -d)
RESULT=FAIL
RESULTS="/results"

VERSION_MAJOR=$(echo "${VERSION}" | awk -F. '{print $1}')

if [[ "${VERSION_MAJOR}" == "3" ]]; then
	case "${DISTRIBUTION}" in
	rocky)
		DISTRIBUTION=rocky9
		;;
	almalinux)
		DISTRIBUTION=almalinux9
		;;
	leap)
		DISTRIBUTION=leap15.5
		;;
	openEuler)
		DISTRIBUTION=openEuler_22.03
		;;
	*)
		echo "Unknown distribution ${DISTRIBUTION}. Exiting!"
		exit 1
		;;
	esac
fi

if [[ "${VERSION_MAJOR}" == "2" ]]; then
	case "${DISTRIBUTION}" in
	rocky)
		DISTRIBUTION=rocky8
		;;
	leap)
		DISTRIBUTION=leap15.3
		((TIMEOUT += 50))
		;;
	*)
		echo "Unknown distribution ${DISTRIBUTION}. Exiting!"
		exit 1
		;;
	esac
fi

if [[ "${SMS}" == "ohpc-huawei-sms" ]]; then
	TEST_ARCH="aarch64"
	CI_CLUSTER=huawei
	COMPUTE_HOSTS="ohpc-huawei-c1, ohpc-huawei-c2"
	((TIMEOUT += 100))
	GATEWAY="192.168.243.4"
	SMS_INTERNAL="${SMS}-internal"
else
	TEST_ARCH=$(uname -m)
	CI_CLUSTER=lenovo
	COMPUTE_HOSTS="ohpc-lenovo-c1, ohpc-lenovo-c2"
	GATEWAY="10.241.58.129"
	SMS_INTERNAL="${SMS}"
fi

if [ ! -d "${RESULTS}" ]; then
	echo "Results directory (${RESULTS}) missing. Exiting"
	exit 1
fi

print_overview() {
	echo
	echo "--> distribution:      ${DISTRIBUTION}"
	echo "--> version:           ${VERSION}"
	echo "--> repository:        ${REPO}"
	echo "--> CI cluster:        ${CI_CLUSTER}"
	echo "--> SMS:               ${SMS}"
	echo "--> test architecture: ${TEST_ARCH}"
	echo "--> enable intel:      ${WITH_INTEL:-false}"
	echo "--> infiniband:        ${USE_IB:-false}"
	echo "--> node names:        ${COMPUTE_HOSTS}"
	echo "--> launcher:          ${LAUNCHER}"
	echo "--> test timeout:      ${TIMEOUT}m"
	echo "--> resource manager:  ${RMS}"
	echo "--> provisioner:       ${PROVISIONER}"
	echo "--> test options:      ${USER_TEST_OPTIONS}"
	echo "--> gateway:           ${GATEWAY}"
	echo "--> gpu:               ${WITH_GPU}"
	echo "--> upload:            ${UPLOAD:-true}"
}

cleanup() {
	set +e
	if [ -s "${OUT}"/test-results.tar ]; then
		cd "${OUT}"
		tar xf test-results.tar
		/usr/local/junit2html/bin/junit2html --merge results tests
		/usr/local/junit2html/bin/junit2html results --summary-matrix | tee -a "${LOG}"
		/usr/local/junit2html/bin/junit2html results --report-matrix junit.html
		rm -rf tests
		cd - >/dev/null
	fi
	echo "Finished at $(date -u +"%Y-%m-%d-%H-%M-%S")" >>"${LOG}"
	FAILED=$(grep "Failed       :" "${LOG}" | cut -d: -f2 | xargs)
	PASSED=$(grep "Passed       :" "${LOG}" | cut -d: -f2 | xargs)
	SKIPPED=$(grep "Skipped      :" "${LOG}" | cut -d: -f2 | xargs)
	mv "${LOG}" "${OUT}"/console.out
	chmod 644 "${OUT}"/console.out
	sed -e "s,${SMS_IPMI_PASSWORD//\$/\\$},****,g" -i "${OUT}"/console.out
	touch "${OUT}/${RESULT}"
	END=$(date +%s)
	((DURATION = END - START))
	{
		echo "DURATION=${DURATION}"
		echo "FAILED=${FAILED:-0}"
		echo "PASSED=${PASSED:-0}"
		echo "SKIPPED=${SKIPPED:-0}"
	} >>"$OUT/INFO"
	if [ -z "${UPLOAD}" ]; then
		if [ ! -d "${RESULTS}/${VERSION_MAJOR}" ]; then
			mkdir "${RESULTS}/${VERSION_MAJOR}"
		fi
		if [ ! -d "${RESULTS}/${VERSION_MAJOR}/${VERSION}" ]; then
			mkdir "${RESULTS}/${VERSION_MAJOR}/${VERSION}"
		fi
		DEST_DIR="${RESULTS}/${VERSION_MAJOR}/${VERSION}"
		NAME="OHPC-${VERSION}-${DISTRIBUTION}-${PROVISIONER}"
		if [ -n "${USE_IB}" ]; then
			NAME="${NAME}-infiniband"
		else
			NAME="${NAME}-ethernet"
		fi
		if [ -n "${WITH_INTEL}" ]; then
			NAME="${NAME}-INTEL"
		fi
		NAME="${NAME}-gpu-${WITH_GPU}-${TEST_ARCH}-${RMS}"
		DEST_NAME="$(date -u +"%Y-%m-%d-%H-%M-%S")-${RESULT}-${NAME}-${RANDOM}"
		mv "${OUT}" "${DEST_DIR}/${DEST_NAME}"
		chmod 755 "${DEST_DIR}/${DEST_NAME}"
		cd "${DEST_DIR}"
		ln -sfn "${DEST_NAME}" "0-LATEST-${NAME}"
		cd - >/dev/null
		echo rsync -a /results/ ohpc@repos.ohpc.io:/results
		# shellcheck disable=SC2029
		echo ssh ohpc@repos.ohpc.io /home/ohpc/bin/update_results.sh "${VERSION_MAJOR}" "${VERSION}"
	fi
	# save CPAN cache
	if [[ "${SMS}" == "ohpc-huawei-sms" ]]; then
		# shellcheck disable=SC2029
		ssh "${BOOT_SERVER}" "bash -c \"rsync -az --info=progress2 --zl 9 --exclude=CPAN/MyConfig.pm ${SMS}:/root/.cpan/ /root/.cache/cpan-backup/\""
	fi
	print_overview
	echo "--> Last job ID:       ${LAST_JOB}"
	echo -n "--> CI run time:       "
	date -d@"${DURATION}" -u +%H:%M:%S
	echo -n "--> CI run result:     "
	if [ "${RESULT}" == "PASS" ]; then
		echo "PASS"
		exit 0
	else
		echo "FAIL"
		exit 1
	fi
}

echo "Started at $(date -u +"%Y-%m-%d-%H-%M-%S")" >"${LOG}"

USER_TEST_OPTIONS="--with-fabric=none"
USER_TEST_OPTIONS="${USER_TEST_OPTIONS} --disable-likwid"
USER_TEST_OPTIONS="${USER_TEST_OPTIONS} --disable-papi"
USER_TEST_OPTIONS="${USER_TEST_OPTIONS} --disable-geopm"
USER_TEST_OPTIONS="${USER_TEST_OPTIONS} --disable-tau"
USER_TEST_OPTIONS="${USER_TEST_OPTIONS} --disable-extrae"
USER_TEST_OPTIONS="${USER_TEST_OPTIONS} --disable-mfem"

if [[ "${VERSION}" == "3."* ]]; then
	USER_TEST_OPTIONS="${USER_TEST_OPTIONS} --with-mpi-families='mpich openmpi5'"
else
	USER_TEST_OPTIONS="${USER_TEST_OPTIONS} --with-mpi-families='mpich openmpi4'"
fi

if [[ "${CI_CLUSTER}" == "huawei" ]]; then
	USER_TEST_OPTIONS="${USER_TEST_OPTIONS} --disable-spack --disable-easybuild"
fi

print_overview

if ! "ansible/roles/test/files/${LAUNCHER}" "${SMS}" "${DISTRIBUTION}" "${VERSION}" "${ROOT_PASSWORD}" | tee -a "${LOG}"; then
	cd - >/dev/null
	echo "Provisioning ${SMS} failed. Exiting" | tee -a "${LOG}"
	cleanup
fi

cd - >/dev/null

set -e

VARS=$(mktemp)

cat vars >"${VARS}"
echo "export IPMI_PASSWORD=${SMS_IPMI_PASSWORD}" >>"${VARS}"

set -x

{
	echo "export DISTRIBUTION=${DISTRIBUTION}"
	echo "export Version=${VERSION}"
	echo "export Architecture=${TEST_ARCH}"
	echo "export SMS=${SMS}"
	echo "export NODE_NAME=${SMS_INTERNAL}"
	echo "export RMS=${RMS}"
	echo "export Provisioner=${PROVISIONER}"
	echo "export Repo=${REPO}"
	echo "export CI_CLUSTER=${CI_CLUSTER}"
	echo "export COMPUTE_HOSTS=\"${COMPUTE_HOSTS}\""
	echo "export EnableOneAPI=${WITH_INTEL:-false}"
	echo "export USER_TEST_OPTIONS=\"${USER_TEST_OPTIONS}\""
	echo "export dns_servers=1.1.1.1"
	echo "export ipv4_gateway=${GATEWAY}"
} >>"${VARS}"

if [[ "${PROVISIONER}" == "confluent" ]]; then
	{
		echo "export initialize_options=usklpta"
		echo "export deployment_protocols=firmware"
		echo "export dns_domain=local"
	} >>"${VARS}"

	if [[ "${DISTRIBUTION}" == "rocky"* ]]; then
		echo "export iso_path=/root/Rocky-9.4-x86_64-dvd.iso" >>"${VARS}"
	fi
	if [[ "${DISTRIBUTION}" == "almalinux"* ]]; then
		echo "export iso_path=/root/AlmaLinux-9.5-x86_64-dvd.iso" >>"${VARS}"
	fi
fi

if [[ "${DISTRIBUTION}" == "almalinux"* ]] && [[ "${SMS}" == "ohpc-huawei-sms" ]]; then
	echo "export YUM_MIRROR_BASE=http://mirrors.nju.edu.cn/almalinux/" >>"${VARS}"
fi
if [[ "${DISTRIBUTION}" == "rocky"* ]] && [[ "${SMS}" == "ohpc-huawei-sms" ]]; then
	echo "export YUM_MIRROR_BASE=http://mirrors.nju.edu.cn/rocky/" >>"${VARS}"
fi
if [[ "${DISTRIBUTION}" == "openEuler"* ]] && [[ "${SMS}" == "ohpc-lenovo-sms" ]]; then
	echo "export YUM_MIRROR_BASE=http://repo.huaweicloud.com/openeuler/" >>"${VARS}"
fi

if [ -n "${USE_IB}" ]; then
	{
		echo "export enable_ib=1"
		echo "export enable_ipoib=1"
	} >>"${VARS}"
else
	{
		echo "export enable_ib=0"
		echo "export enable_ipoib=0"
	} >>"${VARS}"
fi

if [ -n "${RPM}" ]; then
	scp "${RPM}" "${SMS}":/root/ci
	echo "export overwrite_rpm=\"/root/ci/$(basename "${RPM}")\"" >>"${VARS}"
fi

if [[ "${WITH_GPU}" == "nvidia" ]]; then
	echo "export enable_nvidia_gpu_driver=1" >>"${VARS}"
fi

scp "${VARS}" "${SMS}":/root/vars

set +x
set +e

echo "Running install.sh on ${SMS} with timeout ${TIMEOUT}m at $(date -u +"%Y-%m-%d-%H-%M-%S")" | tee -a "${LOG}"
if timeout -v --signal=9 "${TIMEOUT}m" ssh -t -n "${SMS}" 'bash -c "source /root/vars; /root/ci/install.sh"' 2>&1 | sed -u -e "s,${SMS_IPMI_PASSWORD//\$/\\$},****,g" | tee -a "${LOG}"; then
	RESULT=PASS
else
	echo "Running tests on ${SMS} failed!" | tee -a "${LOG}"
fi
echo "Finished install.sh on ${SMS} with timeout ${TIMEOUT}m at $(date -u +"%Y-%m-%d-%H-%M-%S")" | tee -a "${LOG}"

rm -f "${VARS}"

ssh "${SMS}" "mkdir -p /home/ohpc-test/tests; cp *log.xml /home/ohpc-test/tests; cd /home/ohpc-test; find . -name '*log.xml' -print0 | tar -cf - --null -T -" >"${OUT}"/test-results.tar

if [[ "${RMS}" == "slurm" ]]; then
	CMD="scontrol show job | grep JobId"
else
	CMD="qstat -x"
fi

# shellcheck disable=SC2029
LAST_JOB=$(ssh "${SMS}" "${CMD}" | tail -1 | cut -d\  -f1)

echo "Last job ID: ${LAST_JOB}" | tee -a "${LOG}"

cleanup
