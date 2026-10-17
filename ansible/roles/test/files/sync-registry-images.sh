#!/bin/bash

# Mirror the container images used by the OpenHPC CI into the local
# registry on the repo server. Pulling from ghcr.io is slow and not
# always possible from the compute nodes, the CI therefore rewrites
# ghcr.io/<namespace>/<image> to <repo>:5000/<namespace>/<image> when
# provisioning the compute nodes (see support_functions.sh).
#
# The images are copied as they are, only the registry is replaced:
#   ghcr.io/warewulf/warewulf-almalinux:10
# becomes
#   localhost:5000/warewulf/warewulf-almalinux:10
#
# ghcr.io is slow and unreliable from China, the images are pulled
# from a ghcr.io mirror instead. Set SOURCE=ghcr.io to pull directly.
#
# Run this on the repo server whenever the upstream images changed.

set -eu

SOURCE="${SOURCE:-ghcr.nju.edu.cn}"
REGISTRY="${REGISTRY:-localhost:5000}"

IMAGES=(
	ghcr.io/openchami/image-build:latest
	ghcr.io/warewulf/warewulf-almalinux:10
	ghcr.io/warewulf/warewulf-openeuler:24.03
	ghcr.io/warewulf/warewulf-rockylinux:10
)

for image in "${IMAGES[@]}"; do
	# strip the registry, keep namespace, name and tag
	source="${SOURCE}/${image#*/}"
	destination="${REGISTRY}/${image#*/}"
	echo "--> ${source} -> ${destination}"
	skopeo copy --dest-tls-verify=false "docker://${source}" "docker://${destination}"
done
