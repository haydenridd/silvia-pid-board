#!/bin/bash
JLINK_EXE="/usr/bin/JLinkExe"

DEVICE="RP2040_M0_0"

${JLINK_EXE} -NoGui 1 << EOF
device ${DEVICE}
si SWD
speed 4000
h
r
loadfile $1
r
g
exit
EOF