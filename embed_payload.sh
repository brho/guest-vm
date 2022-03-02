#!/bin/bash
#
# Embeds a payload with a shell script and makes it executable.

set -e

usage () {
	echo "Usage: $0 SRC_SCRIPT PAYLOAD DST_SCRIPT"
	exit -1
}

[ $# -lt 3 ] && usage

SRC=$1
BLOB=$2
DST=$3

cat $SRC > $DST
echo "" >> $DST
echo "PAYLOAD:" >> $DST
cat $BLOB >> $DST

chmod +x $DST
