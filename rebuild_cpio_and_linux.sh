#!/bin/bash
# Barret Rhoden (brho@google.com)
#
# Given an existing FS hierarchy at tc_root, this rebuilds the CPIO archive and
# rebuilds Linux, embedding the initramfs according to the .config.  Any kernel
# modules will be added to the initramfs.
#
# Run with SKIP_KERNEL=1 if you want to skip rebuilding the kernel.
#
# You'll need to run this anytime you manually change the contents of tc_root
# or if you have new kernel modules you'd like to install.
#
# Note you can run this independently of the other scripts, but overriding rcS
# by changing the symlink happens in setup_tinycore.sh.  So you'll need to edit
# tc_root/etc/init.d/rcS manually.  Same goes for tc-sys.sh.

set -e
trap "exit" INT

MAKE_JOBS="${MAKE_JOBS:-8}"
# keep this in sync with the published linux .config.  Must end in .cpio.gz.
# This is relative to LINUX_ROOT.  This is all in case the initrd is built into
# the kernel.
INITRD_NAME=initramfs.cpio.gz

usage()
{
	echo "Usage: ./`basename $0` NOT_RELATIVE_PATH_TO_LINUX_ROOT"
	exit -1
}

if [ $# -lt 1 ]
then
	usage
fi
LINUX_ROOT=$1

if [[ ${LINUX_ROOT:0:1} == "." ]]
then
	usage
fi

DIR=`dirname "$0"`
if [[ "$DIR" != "." ]]
then
	echo "Run the script $0 from within its directory: $DIR"
	usage
fi

if [ ! -d "tc_root" ]
then
	echo "tc_root not found, run setup_tinycore.sh first"
	exit -1
fi

if [ ! -n "$SKIP_KERNEL" ]
then
	echo "Building Linux modules"
	sudo rm -rf tc_root/lib/modules/*
	rm -rf kernel_mods/
	mkdir -p kernel_mods
	KERNEL_MODS=`pwd`/kernel_mods
	(cd $LINUX_ROOT &&
	 > $LINUX_ROOT/$INITRD_NAME &&
	make -j $MAKE_JOBS &&
	make -j $MAKE_JOBS INSTALL_MOD_PATH=$KERNEL_MODS INSTALL_MOD_STRIP=1 modules modules_install
	)
	sudo cp -r kernel_mods/* tc_root/ || true
else
	# Don't want any old tinycore modules, but we also don't want to blow
	# away modules from the correct kernel
	sudo rm -rf tc_root/lib/modules/*tinycore*/
fi

echo "Rebuilding CPIO"

# In case someone is using ~tc and dropped some stuff in that home dir
sudo chown -R 1001 tc_root/home/tc

(cd tc_root &&
sudo find . -print | sudo cpio -H newc -o | gzip > $LINUX_ROOT/$INITRD_NAME
)

if [ ! -n "$SKIP_KERNEL" ]
then
	echo "Building Linux (maybe with embedded CPIO, based on CONFIGS)"
	(cd $LINUX_ROOT &&
	ARCH=x86_64 make -j $MAKE_JOBS
	)
	echo "Final vmlinux at $LINUX_ROOT/vmlinux"
fi

echo "Compressed initramfs at $LINUX_ROOT/$INITRD_NAME"
