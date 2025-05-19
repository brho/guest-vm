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

if [ ! -f Localconfig ]; then
	cp Localconfig.template Localconfig
fi
source ./Localconfig

if [[ -z $INITRD_NAME ]]; then
	echo INITRD_NAME is empty
	exit -1
fi

if [[ $LINUX_REPO == "/path/to/linux/repo" ]]; then
	echo "LINUX_REPO is still set to $LINUX_REPO"
	exit -1
fi
if [[ ${LINUX_REPO:0:1} == "." ]]; then
	echo "LINUX_REPO must be a full path"
	exit -1
fi
if [[ ${LINUX_REPO:0:1} == "~" ]]; then
	echo "LINUX_REPO must not use ~"
	exit -1
fi

DIR=`dirname "$0"`
if [[ "$DIR" != "." ]]; then
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
	(cd $LINUX_REPO &&
	 > $LINUX_REPO/$INITRD_NAME &&
	$MAKE &&
	make INSTALL_MOD_PATH=$KERNEL_MODS INSTALL_MOD_STRIP=1 modules_install
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
sudo find . -print | sudo cpio -H newc -o | gzip > $LINUX_REPO/$INITRD_NAME
)

if [ ! -n "$SKIP_KERNEL" ]
then
	echo "Building Linux (maybe with embedded CPIO, based on CONFIGS)"
	(cd $LINUX_REPO &&
	$MAKE
	)
	echo "Final vmlinux at $LINUX_REPO/vmlinux"
fi

echo "Compressed initramfs at $LINUX_REPO/$INITRD_NAME"
