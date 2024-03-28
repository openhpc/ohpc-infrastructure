#!/bin/bash

set -o pipefail

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
	echo "  -i                    Install and run tests using package built with the"
	echo "                        Intel compiler"
	echo "  -h                    Show this help"
}

TIMEOUT="100m"

while getopts "d:v:r:m:ih" OPTION; do
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
	i)
		WITH_INTEL="true"
		TIMEOUT="150m"
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

if [[ "${SMS}" == "openhpc-lenovo-jenkins-sms" ]]; then
	LAUNCHER="lenovo_launch_sms.sh"
elif [[ "${SMS}" == "openhpc-oe-jenkins-sms" ]]; then
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
if [[ "${SMS}" == "openhpc-oe-jenkins-sms" ]]; then
	TEST_ARCH="aarch64"
	CI_CLUSTER=huawei
	COMPUTE_HOSTS="openhpc-oe-jenkins-c1, openhpc-oe-jenkins-c2"
	((TIMEOUT += 100))
else
	TEST_ARCH=$(uname -m)
	CI_CLUSTER=lenovo
	COMPUTE_HOSTS="openhpc-lenovo-jenkins-c1, openhpc-lenovo-jenkins-c2"
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
	echo "--> node names:        ${COMPUTE_HOSTS}"
	echo "--> launcher:          ${LAUNCHER}"
	echo "--> test timeout:      ${TIMEOUT}"
	echo "--> resource manager:  ${RMS}"
}

cleanup() {
	if [ ! -d "${RESULTS}/${VERSION_MAJOR}" ]; then
		mkdir "${RESULTS}/${VERSION_MAJOR}"
	fi
	if [ ! -d "${RESULTS}/${VERSION_MAJOR}/${VERSION}" ]; then
		mkdir "${RESULTS}/${VERSION_MAJOR}/${VERSION}"
	fi
	if [ -s "${OUT}"/test-results.tar ]; then
		cd "${OUT}"
		set +e
		tar xf test-results.tar
		/usr/local/junit2html/bin/junit2html --merge results tests
		/usr/local/junit2html/bin/junit2html results --summary-matrix | tee -a "${LOG}"
		/usr/local/junit2html/bin/junit2html results --report-matrix junit.html
		rm -rf tests
		cd - >/dev/null
		set -e
	fi
	echo "Finished at $(date -u +"%Y-%m-%d-%H-%M-%S")" >>"${LOG}"
	mv "${LOG}" "${OUT}"/console.out
	chmod 644 "${OUT}"/console.out
	sed -e "s,${SMS_IPMI_PASSWORD//\$/\\$},****,g" -i "${OUT}"/console.out
	touch "${OUT}/${RESULT}"
	DEST_DIR="${RESULTS}/${VERSION_MAJOR}/${VERSION}"
	NAME="OHPC-${VERSION}-${DISTRIBUTION}-${TEST_ARCH}-${RMS}"
	if [ -z "${WITH_INTEL}" ]; then
		NAME="${NAME}-INTEL"
	fi
	DEST_NAME="$(date -u +"%Y-%m-%d-%H-%M-%S")-${RESULT}-${NAME}-${RANDOM}"
	mv "${OUT}" "${DEST_DIR}/${DEST_NAME}"
	chmod 755 "${DEST_DIR}/${DEST_NAME}"
	cd "${DEST_DIR}"
	ln -sfn "${DEST_NAME}" "0-LATEST-${NAME}"
	cd - >/dev/null
	rsync -a /results ohpc@repos.ohpc.io:/stats/
	# shellcheck disable=SC2029
	ssh ohpc@repos.ohpc.io /home/ohpc/bin/update_results.sh "${VERSION_MAJOR}" "${VERSION}"
	# save CPAN cache
	if [[ "${SMS}" == "openhpc-oe-jenkins-sms" ]]; then
		# shellcheck disable=SC2029
		ssh "${BOOT_SERVER}" "bash -c \"rsync -az --info=progress2 --zl 9 --exclude=CPAN/MyConfig.pm ${SMS}:/root/.cpan/ /root/.cache/cpan-backup/\""
	fi
	print_overview
	echo "--> resource manager:  ${RMS}"
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

print_overview

if ! "ansible/roles/test/files/${LAUNCHER}" "${SMS}" "${DISTRIBUTION}" "${VERSION}" "${ROOT_PASSWORD}" | tee -a "${LOG}"; then
	cd - >/dev/null
	echo "Provisiong ${SMS} failed. Exiting" | tee -a "${LOG}"
	cleanup
fi

cd - >/dev/null

set -e

VARS=$(mktemp)

cat vars >"${VARS}"
echo "export IPMI_PASSWORD=${SMS_IPMI_PASSWORD}" >>"${VARS}"

set -x

{
	echo "export BaseOS=${DISTRIBUTION}"
	echo "export Version=${VERSION}"
	echo "export Architecture=${TEST_ARCH}"
	echo "export SMS=${SMS}"
	echo "export NODE_NAME=${SMS}"
	echo "export RMS=${RMS}"
	echo "export Repo=${REPO}"
	echo "export CI_CLUSTER=${CI_CLUSTER}"
	echo "export COMPUTE_HOSTS=\"${COMPUTE_HOSTS}\""
	echo "export EnableOneAPI=${WITH_INTEL:-false}"
} >>"${VARS}"

if [[ "${DISTRIBUTION}" == "almalinux"* ]] && [[ "${SMS}" == "openhpc-oe-jenkins-sms" ]]; then
	echo "export YUM_MIRROR_BASE=http://mirrors.nju.edu.cn/almalinux/" >>"${VARS}"
fi
if [[ "${DISTRIBUTION}" == "openEuler"* ]] && [[ "${SMS}" == "openhpc-lenovo-jenkins-sms" ]]; then
	echo "export YUM_MIRROR_BASE=http://repo.huaweicloud.com/openeuler/" >>"${VARS}"
fi

scp "${VARS}" "${SMS}":/root/vars

set +x

echo "Running install.sh on ${SMS}"
if timeout --signal=9 "${TIMEOUT}" ssh "${SMS}" 'bash -c "source /root/vars; /root/ci/install.sh"' 2>&1 | sed -e "s,${SMS_IPMI_PASSWORD//\$/\\$},****,g" | tee -a "${LOG}"; then
	RESULT=PASS
else
	echo "Running tests on ${SMS} failed!" | tee -a "${LOG}"
fi

rm -f "${VARS}"

ssh "${SMS}" "mkdir -p /home/ohpc-test/tests; cp *log.xml /home/ohpc-test/tests; cd /home/ohpc-test; find . -name '*log.xml' -print0 | tar -cf - --null -T -" >"${OUT}"/test-results.tar
cleanup
