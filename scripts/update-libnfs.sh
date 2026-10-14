#!/usr/bin/env bash

set -euo pipefail

# Imports the libnfs client library sources into Vendor/LibNFS, where Xcode
# compiles them for every platform through a local Swift package. Only the
# library itself is copied (its CMake source lists, headers and licences);
# examples, utils, tests, TLS and non-Apple ports stay upstream.
#
# To update: change the tag and commit below, run this script, review the
# diff (and Sources/LibNFS/config/config.h against cmake/ConfigureChecks.cmake)
# and build all three platforms.

readonly LIBNFS_TAG="libnfs-8.0.0"
readonly LIBNFS_COMMIT="5b1bc60260b5ddac34900c5315010b88b73e7edd"
readonly REPOSITORY_URL="https://github.com/sahlberg/libnfs.git"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGE_DIR="${PROJECT_DIR}/Vendor/LibNFS"
SOURCES_DIR="${PACKAGE_DIR}/Sources/LibNFS"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

git clone --quiet --depth 1 --branch "${LIBNFS_TAG}" "${REPOSITORY_URL}" "${WORK_DIR}/libnfs"
actual_commit="$(git -C "${WORK_DIR}/libnfs" rev-parse HEAD)"
if [[ "${actual_commit}" != "${LIBNFS_COMMIT}" ]]; then
    echo "error: ${LIBNFS_TAG} is ${actual_commit}, expected ${LIBNFS_COMMIT}" >&2
    exit 1
fi
upstream="${WORK_DIR}/libnfs"

# Directory -> sources, mirroring each CMakeLists.txt SOURCES list.
readonly -a COMPONENTS=(
    "lib:init.c krb5-wrapper.c libnfs.c libnfs-sync.c libnfs-zdr.c multithreading.c nfs_v3.c nfs_v4.c pdu.c socket.c"
    "mount:libnfs-raw-mount.c mount.c"
    "nfs:libnfs-raw-nfs.c nfs.c nfsacl.c"
    "nfs4:libnfs-raw-nfs4.c nfs4.c"
    "nlm:libnfs-raw-nlm.c nlm.c"
    "nsm:libnfs-raw-nsm.c nsm.c"
    "portmap:libnfs-raw-portmap.c portmap.c"
    "rquota:libnfs-raw-rquota.c rquota.c"
)

# Keep the files this package owns (umbrella header, module map, config.h).
for component in "${COMPONENTS[@]}"; do
    rm -rf "${SOURCES_DIR:?}/${component%%:*}"
done
rm -rf "${SOURCES_DIR}/include/nfsc"
rm -f "${SOURCES_DIR}/include/libnfs-private.h" \
      "${SOURCES_DIR}/include/libnfs-multithreading.h" \
      "${SOURCES_DIR}/include/slist.h"

for component in "${COMPONENTS[@]}"; do
    directory="${component%%:*}"
    mkdir -p "${SOURCES_DIR}/${directory}"
    for source in ${component#*:}; do
        cp "${upstream}/${directory}/${source}" "${SOURCES_DIR}/${directory}/"
    done
    # The protocol headers stay beside their sources: upstream includes some
    # of them by relative path (for example "../nfs4/libnfs-raw-nfs4.h").
    find "${upstream}/${directory}" -maxdepth 1 -name '*.h' -exec cp {} "${SOURCES_DIR}/${directory}/" \;
done

mkdir -p "${SOURCES_DIR}/include/nfsc"
cp "${upstream}"/include/nfsc/*.h "${SOURCES_DIR}/include/nfsc/"
cp "${upstream}/include/libnfs-private.h" \
   "${upstream}/include/libnfs-multithreading.h" \
   "${upstream}/include/slist.h" \
   "${SOURCES_DIR}/include/"

cp "${upstream}/COPYING" \
   "${upstream}/LICENCE-LGPL-2.1.txt" \
   "${upstream}/LICENCE-BSD.txt" \
   "${PACKAGE_DIR}/"

echo "Imported ${LIBNFS_TAG} (${LIBNFS_COMMIT}) into ${PACKAGE_DIR}"
