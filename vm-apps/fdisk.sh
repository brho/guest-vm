#!/bin/bash
# Copyright (c) 2019 Google, Inc
# Barret Rhoden <brho@cs.berkeley.edu>
#
# fdisk
#
# Run fdisk in a VM.  Closely coupled with the VM image (kernel and initramfs).
# This script expects to run with an image that runs fdisk on /dev/vda
# (virtio-block), outputs to /dev/hvc0 (virtio-cons), and exits (vmcall, usually
# via tinyreboot).
#
# This script requires an embedded initramfs.  To make and embed it, head to the
# this repo's (linux-guest) akaros/ directory.  Set rcS-link to point to
# rcS-fdisk, then do a ./full_guest_build.sh FULL_PATH_TO_LINUX_GUEST_ROOT.
#
# To embed the initramfs:
#
#  ./embed_payload.sh vm-apps/fdisk.sh initramfs.cpio.gz obj/fdisk
#
# Then scp it or put it in $AKAROS_ROOT/kern/kfs/bin (about 3 MB).  Also
# consider keeping the fdisk-specific initramfs in obj/.
#
# You also need a suitable /lib/vmlinux on the Akaros host.  Right now, a
# reasonably generic one that works for several apps works for fdisk.
# full_guest_build.sh should have built one.
#
# You can optionally slim down your initramfs to just run fdisk.  For instance,
# set PACKAGES='' in setup_tinycore.sh and you can set CUSTOM_REMOVALS to
# include most of the large files in TC in full_guest_build.sh.
#
# TODO:
# - Tune the memory usage.  Based on the vmlinux/initramfs.
# - Consider an even smaller, customized vmlinux.  We can embed the initramfs
# into the vmlinux, and embed that instead of just an initramfs.
# - Consider some sort of Makefile for all of the vm-apps.  Store the
# app-specific initrd in obj/, etc.  Note that full_guest_build.sh is involved
# in the customization of a particular app too, so that might need to change
# into some sort of "recipe".

set -e

##### Standard stuff for VM apps with an embedded initramfs:

FULL_DIRNAME="$( cd "$(dirname "$0")" ; pwd -P )"
BASENAME=`echo $0 | grep -o '[^/]*$'`
FULL_PATH=${FULL_DIRNAME}/${BASENAME}

extract_initramfs() {
	if ! grep -q '^PAYLOAD:$' $FULL_PATH; then
		echo "No embedded initramfs, aborting!"
		exit 1
	fi
	LINE=`grep -an '^PAYLOAD:$' $FULL_PATH | cut -f 1 -d ':'`
	LINE=$((LINE + 1))
	tail -n +$LINE $FULL_PATH > initramfs
}

##### Actual app:

if [ $# -lt 1 ]; then
	echo "Usage: $0 [FDISK ARGS] /full/path/to/disk/data"
	exit
fi

# Set $DISK to the last arg, and FDISK_ARGS to the intermediate ones.
#
# We need to octal-encode the spaces (040).  The kernel command line can handle
# spaces (inside quotes btw), but it's easier to parse them in rcS with octal
while [ $# -gt 1 ]; do
        FDISK_ARGS="${FDISK_ARGS}\040$1"
        shift
done
DISK=$1

if [ ! -e $DISK ]; then
	echo "No such file $DISK, aborting!"
	exit 1
fi

# vmrunkernel takes a bunch of text files.  We can 'bring our own' by dumping
# them in a tmpfs that disappears when the script exits.

# Need the -P since # is outside the namespace.
# Squelch stderr since bash's getcwd() complains.
cd -P '#tmpfs' 2>/dev/null

# For extra debugging, change console=hvc0 and/or add earlyprintk=akaros
# The 'nortc' and 'nozswap' are only processed by tinycore, which our image
# probably won't use.  Keeping them around helps with debugging.
cat > guest_cmdline <<EOF
console=none
lapic=notscdeadline
nortc
nozswap
fdisk_args=$FDISK_ARGS
EOF

# The initramfs can be put in the tmpfs too!
extract_initramfs

# Note the full path to vmlinux.  Our pwd is #tmpfs, not the directory we
# started in.
vmrunkernel -k guest_cmdline -m 0x4000000 -f $DISK -s /lib/vmlinux -i initramfs

exit 0
