#!/bin/bash
#
# Runs the axi_datv_xpdr testbench in the Vivado simulator (xsim).
#
# usage: sim/run.sh [hdl-dir]
#
#   hdl-dir   patched hdl tree (default: ./plutosdr-fw/hdl, as created by
#             setup.sh in the repository directory)
#
# Vivado 2022.2 is taken from PATH or /opt/Xilinx/Vivado/2022.2.

set -euo pipefail

SIM_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HDL=$(cd "${1:-$SIM_DIR/../plutosdr-fw/hdl}" && pwd)

[ -f "$HDL/library/axi_datv_xpdr/axi_datv_xpdr.v" ] || {
	echo "ERROR: $HDL is not a patched hdl tree (run setup.sh first)" >&2
	exit 1
}

if ! command -v xvlog >/dev/null; then
	# shellcheck disable=SC1091
	source /opt/Xilinx/Vivado/2022.2/settings64.sh
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

xvlog -nolog \
	"$HDL/library/common/up_axi.v" \
	"$HDL/library/common/up_xfer_cntrl.v" \
	"$HDL/library/common/up_xfer_status.v" \
	"$HDL/library/axi_datv_xpdr/datv_nco_mixer.v" \
	"$HDL/library/axi_datv_xpdr/axi_datv_xpdr.v" \
	"$SIM_DIR/tb_axi_datv_xpdr.v" >/dev/null
xelab -nolog -debug off tb -s tb_sim >/dev/null
xsim -nolog tb_sim -R | tee sim.log | grep -E "^(ok|FAIL)|TESTS"

grep -q "ALL TESTS PASSED" sim.log
