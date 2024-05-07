#!/bin/bash

VERSION="$1"

set -e

echo
echo
echo "Computing sums for release tarballs for OpenHPC Version ${VERSION}"

filename="OpenHPC-$VERSION.checksums"

pushd "/repos/dist/$VERSION"

# ensure no cruft from previous runs
rm -f "$filename"

sha256sum --tag -- *.tar | tee -a "$filename"

gpg --clear-sign "$filename"

mv "$filename.asc" "$filename"

echo
echo "Done"
