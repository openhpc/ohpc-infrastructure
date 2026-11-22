#!/usr/bin/env bats
# shellcheck disable=SC2154

SCRIPT=".github/scripts/cleanup-ghcr-untagged.sh"

setup() {
	TEST_DIR=$(mktemp -d)
	export TEST_DIR
	mkdir "${TEST_DIR}/bin"

	cat >"${TEST_DIR}/bin/gh" <<-'STUB'
		#!/bin/bash
		if [[ "$*" == *DELETE* ]]; then
			echo "${@: -1}" >>"${TEST_DIR}/deleted"
		else
			cat "${TEST_DIR}/versions.json"
		fi
	STUB

	cat >"${TEST_DIR}/bin/docker" <<-'STUB'
		#!/bin/bash
		if [ "${FAIL_INSPECT:-}" = "1" ]; then
			exit 1
		fi
		cat "${TEST_DIR}/manifest-${*: -1:1}.json" 2>/dev/null ||
			cat "${TEST_DIR}/manifest.json"
	STUB
	chmod +x "${TEST_DIR}/bin/gh" "${TEST_DIR}/bin/docker"
	PATH="${TEST_DIR}/bin:${PATH}"

	# Version 1 is the current image index. Versions 2 and 3 are its
	# per-architecture manifests. Versions 4, 5 and 6 are the index and
	# the manifests of the previous build.
	cat >"${TEST_DIR}/versions.json" <<-'JSON'
		[
		  {"id": 1, "name": "sha256:index-new", "metadata": {"container": {"tags": ["latest"]}}},
		  {"id": 2, "name": "sha256:amd64-new", "metadata": {"container": {"tags": []}}},
		  {"id": 3, "name": "sha256:arm64-new", "metadata": {"container": {"tags": []}}}
		]
		[
		  {"id": 4, "name": "sha256:index-old", "metadata": {"container": {"tags": []}}},
		  {"id": 5, "name": "sha256:amd64-old", "metadata": {"container": {"tags": []}}},
		  {"id": 6, "name": "sha256:arm64-old", "metadata": {"container": {"tags": []}}}
		]
	JSON
	cat >"${TEST_DIR}/manifest.json" <<-'JSON'
		{"manifests": [{"digest": "sha256:amd64-new"}, {"digest": "sha256:arm64-new"}]}
	JSON
}

teardown() {
	rm -rf "${TEST_DIR}"
}

@test "arguments are required" {
	run "${SCRIPT}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Usage"* ]]
}

@test "only unreferenced untagged versions are deleted" {
	run "${SCRIPT}" openhpc obs-worker
	[ "$status" -eq 0 ]
	[ "$(cat "${TEST_DIR}/deleted")" = "/orgs/openhpc/packages/container/obs-worker/versions/4
/orgs/openhpc/packages/container/obs-worker/versions/5
/orgs/openhpc/packages/container/obs-worker/versions/6" ]
	[[ "$output" == *"Deleted 3 untagged version(s)"* ]]
}

@test "a tagged single-arch image is kept" {
	echo '{"config": {"digest": "sha256:config"}}' >"${TEST_DIR}/manifest.json"
	run "${SCRIPT}" openhpc obs-worker
	[ "$status" -eq 0 ]
	[ "$(wc -l <"${TEST_DIR}/deleted")" -eq 5 ]
	run grep -q "versions/1$" "${TEST_DIR}/deleted"
	[ "$status" -eq 1 ]
}

@test "nothing is deleted without a tagged version" {
	sed -i 's/\["latest"\]/[]/' "${TEST_DIR}/versions.json"
	run "${SCRIPT}" openhpc obs-worker
	[ "$status" -ne 0 ]
	[ ! -e "${TEST_DIR}/deleted" ]
	[[ "$output" == *"Not deleting anything"* ]]
}

@test "nothing is deleted if the index cannot be inspected" {
	FAIL_INSPECT=1 run "${SCRIPT}" openhpc obs-worker
	[ "$status" -ne 0 ]
	[ ! -e "${TEST_DIR}/deleted" ]
}

@test "nothing is deleted if the version list cannot be fetched" {
	rm "${TEST_DIR}/versions.json"
	run "${SCRIPT}" openhpc obs-worker
	[ "$status" -ne 0 ]
	[ ! -e "${TEST_DIR}/deleted" ]
}
