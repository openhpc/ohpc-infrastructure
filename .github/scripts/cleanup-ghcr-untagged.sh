#!/bin/bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
	echo "Usage: $0 <organization> <package>" >&2
	exit 1
fi

organization=$1
package=$2
api="/orgs/${organization}/packages/container/${package}/versions"
image="ghcr.io/${organization}/${package}"

versions=$(gh api --paginate "${api}?per_page=100" |
	jq -r '.[] | [.id, .name, (.metadata.container.tags | length)] | @tsv')

# A multi-arch tag points to an image index. The per-architecture manifests
# in the index are untagged versions of the package. Deleting one of them
# breaks the tagged image for that architecture.
declare -A referenced
tagged=0
while IFS=$'\t' read -r _ digest tags; do
	if [ "${tags}" -eq 0 ]; then
		continue
	fi
	tagged=$((tagged + 1))
	manifest=$(docker buildx imagetools inspect --raw "${image}@${digest}")
	while read -r child; do
		if [ -n "${child}" ]; then
			referenced["${child}"]=1
		fi
	done < <(jq -r '.manifests[]?.digest' <<<"${manifest}")
done <<<"${versions}"

# Without a tagged version every version would be deleted. That state is
# more likely an unexpected API response than a package to clean up.
if [ "${tagged}" -eq 0 ]; then
	echo "No tagged version of ${image} found. Not deleting anything." >&2
	exit 1
fi

deleted=0
while IFS=$'\t' read -r id digest tags; do
	if [ "${tags}" -gt 0 ]; then
		echo "Keeping tagged version ${digest}"
		continue
	fi
	if [ -n "${referenced[${digest}]:-}" ]; then
		echo "Keeping ${digest}, a tagged image index references it"
		continue
	fi
	echo "Deleting untagged version ${digest}"
	gh api --method DELETE "${api}/${id}"
	deleted=$((deleted + 1))
done <<<"${versions}"

echo "Deleted ${deleted} untagged version(s) of ${image}"
