#!/bin/bash
# Barret Rhoden (brho@google.com)
# 
# Dumps the contents of an initramfs to easily see what takes up the most space.

set -e
trap "exit" INT

usage()
{
	echo "Usage: $0 INITRAMFS.cpio.gz"
	exit -1
}

if [ $# -lt 1 ]
then
	usage
fi
INITRD_GZ=$1

gunzip -c $INITRD_GZ | cpio -tv 2>/dev/null | grep -v '^[dlbc]' | awk '{ print $5 " " $9 }' | sort -h
