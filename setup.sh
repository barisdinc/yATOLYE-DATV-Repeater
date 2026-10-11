#!/bin/bash
#
# yATOLYE DATV Repeater - source tree setup
#
# Clones the Analog Devices PlutoSDR firmware tree at the supported
# release, checks out the pinned submodules and applies the DATV
# repeater patches on top of them.
#
# usage: ./setup.sh [-s|--shallow] [target-dir]
#
#   -s, --shallow   shallow clones (depth 1), much smaller download
#   target-dir      where to put plutosdr-fw (default: ./plutosdr-fw)

set -euo pipefail

PLUTOSDR_FW_URL=${PLUTOSDR_FW_URL:-https://github.com/analogdevicesinc/plutosdr-fw.git}
PLUTOSDR_FW_TAG=v0.38

# submodule commits of plutosdr-fw v0.38 the patches are based on
declare -A BASE_COMMIT=(
	[hdl]=1978df2985ce230f3a50b717accd7066609866ec
	[buildroot]=f70f4aff40bcc16e3d9a920984d034ad108f4993
	[linux]=e14e351533f934047ba0473e836e561682ec67fe
	[u-boot-xlnx]=90401ce9ce029e5563f4dface63914d42badf5bc
)

# submodules that receive patches, in order
PATCHED_SUBMODULES=(hdl buildroot)

BRANCH=yatolye-datv

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PATCH_DIR=$SCRIPT_DIR/patches

SHALLOW=0
TARGET=

usage() {
	sed -n '9,13p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

info() {
	echo -e "\033[1;32m==>\033[0m $*"
}

die() {
	echo -e "\033[1;31mERROR:\033[0m $*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		-s|--shallow) SHALLOW=1 ;;
		-h|--help) usage 0 ;;
		-*) usage 1 ;;
		*) [ -z "$TARGET" ] || usage 1; TARGET=$1 ;;
	esac
	shift
done

TARGET=${TARGET:-$PWD/plutosdr-fw}

for tool in git make; do
	command -v $tool >/dev/null || die "$tool is not installed"
done

# git am needs a committer identity; fall back to a local one if the
# user has none configured
GIT_ID=()
if [ -z "$(git config user.email || true)" ]; then
	GIT_ID=(-c user.name="yATOLYE DATV setup" -c user.email="setup@localhost")
fi

depth_args=()
[ $SHALLOW -eq 1 ] && depth_args=(--depth 1)

# 1. plutosdr-fw

if [ -d "$TARGET/.git" ]; then
	info "Using existing $TARGET"
	tag=$(git -C "$TARGET" describe --tags --exact-match HEAD 2>/dev/null || true)
	[ "$tag" = "$PLUTOSDR_FW_TAG" ] || \
		die "$TARGET is not at $PLUTOSDR_FW_TAG (found '${tag:-untagged}')"
else
	info "Cloning plutosdr-fw $PLUTOSDR_FW_TAG into $TARGET"
	git clone "${depth_args[@]}" --branch "$PLUTOSDR_FW_TAG" \
		-c advice.detachedHead=false "$PLUTOSDR_FW_URL" "$TARGET"
fi

cd "$TARGET"

# 2. submodules

info "Checking out submodules"
for sm in "${!BASE_COMMIT[@]}"; do
	# leave already initialized (and possibly patched) submodules alone
	[ -e "$sm/.git" ] && continue
	git submodule update --init "${depth_args[@]}" -- "$sm"
done

for sm in "${!BASE_COMMIT[@]}"; do
	head=$(git -C "$sm" rev-parse HEAD)
	[ "$head" = "${BASE_COMMIT[$sm]}" ] && continue
	# already patched trees are on top of the base commit
	git -C "$sm" merge-base --is-ancestor "${BASE_COMMIT[$sm]}" HEAD 2>/dev/null || \
		die "$sm is at $head, expected ${BASE_COMMIT[$sm]}"
done

# 3. patches

for sm in "${PATCHED_SUBMODULES[@]}"; do
	patches=("$PATCH_DIR/$sm"/*.patch)
	[ -e "${patches[0]}" ] || continue

	# git mailinfo unfolds the (possibly wrapped) Subject header
	last_subject=$(git mailinfo /dev/null /dev/null < "${patches[-1]}" | \
		sed -n 's/^Subject: //p')
	if git -C "$sm" log --format=%s "${BASE_COMMIT[$sm]}..HEAD" 2>/dev/null | \
			grep -qxF "$last_subject"; then
		info "$sm: patches already applied"
		continue
	fi

	[ -z "$(git -C "$sm" status --porcelain --untracked-files=no)" ] || \
		die "$sm has local modifications, refusing to patch"

	info "$sm: applying ${#patches[@]} patch(es) on branch $BRANCH"
	git -C "$sm" checkout -q -B "$BRANCH" "${BASE_COMMIT[$sm]}"
	git -C "$sm" "${GIT_ID[@]}" am --3way --whitespace=nowarn "${patches[@]}" || {
		git -C "$sm" am --abort || true
		die "$sm: failed to apply patches"
	}
done

info "Done. Source tree: $TARGET"
cat <<EOF

Next steps (Vivado 2022.2 must be installed under /opt/Xilinx):

  cd $TARGET
  SKIP_LEGAL=1 make build/pluto.dfu     # firmware image (HDL + Linux + rootfs)

Load into RAM for testing (Pluto at 192.168.2.1):

  ssh root@192.168.2.1 device_reboot ram
  dfu-util -D build/pluto.dfu -a firmware.dfu
  dfu-util -d 0456:b674 -a firmware.dfu -e

Write to flash:

  ssh root@192.168.2.1 device_reboot sf
  dfu-util -D build/pluto.dfu -a firmware.dfu
  dfu-util -d 0456:b674 -a firmware.dfu -e

Pass SKIP_LEGAL as an environment variable, not as a make argument:
command line variables are forwarded to the HDL build, which then builds
the Vivado project in a separate sub directory and the old bitstream is
used.
EOF
