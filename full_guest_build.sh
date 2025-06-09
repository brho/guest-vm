#!/bin/bash
# Barret Rhoden (brho@google.com)
#
# Builds the kernel + initramfs.
#
# You need to call this from the directory it is in and pass it a non-relative
# path to a linux repo.  You can set SKIP_KERNEL=1 to avoid rebuilding the
# kernel.

set -e
trap "exit" INT

if [ ! -f Localconfig ]; then
	cp Localconfig.template Localconfig
fi
source ./Localconfig

[ -n "$SKIP_KERNEL" ] && echo "Don't SKIP_KERNEL if you have modules" && sleep 5

if [[ -z $LINUX_REPO ]]; then
	echo "LINUX_REPO is empty"
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

if [[ -z $UROOT_REPO ]]; then
	echo "UROOT_REPO is empty"
	exit -1
fi
if [[ $UROOT_REPO == "/path/to/u-root/repo" ]]; then
	echo "UROOT_REPO is still set to $UROOT_REPO"
	exit -1
fi
if [[ ${UROOT_REPO:0:1} == "." ]]; then
	echo "UROOT_REPO must be a full path"
	exit -1
fi
if [[ ${UROOT_REPO:0:1} == "~" ]]; then
	echo "UROOT_REPO must not use ~"
	exit -1
fi

DIR=`dirname "$0"`
if [[ "$DIR" != "." ]]; then
	echo "Run the script $0 from within its directory: $DIR"
	exit -1
fi

if [ ! -z $KERNEL_CONFIG ]; then
	cp $KERNEL_CONFIG $LINUX_REPO/.config
fi

# Build any of our tiny programs, which might be included via UROOT_EXTRA
(cd progs && make)

# Build u-root initramfs
UROOT_CPIO=`pwd`/initramfs.uroot.cpio
UROOT_CMD=(./u-root)
UROOT_CMD+=(-uinitcmd=\"/tc-sys.sh\")
UROOT_CMD+=($UROOT_EXTRA)
UROOT_CMD+=(-o $UROOT_CPIO)
# non-option commands must be last...
UROOT_CMD+=(core cmds/exp/modprobe)
echo ${UROOT_CMD[@]}

(cd $UROOT_REPO && eval "${UROOT_CMD[@]}")
echo "Built $UROOT_CPIO"

# Build tc_root initramfs
rm -rf tc_root/
mkdir tc_root
cp -r tc-sys.sh tc_root/
mkdir -p tc_root/root/

# SSH Keys.  Putting them in root/.ssh just out of convention.
if [ ! -z $SSH_KEY ]; then

	mkdir -p tc_root/root/.ssh/
	cp $SSH_KEY.pub tc_root/root/.ssh/authorized_keys
	cp $SSH_KEY.pub tc_root/root/.ssh/
	cp $SSH_KEY tc_root/root/.ssh/

	# Let the VM ssh into the host easily.
	# This implies the VM is using qemu mode addressing.
	# YMMV
	dd of=tc_root/root/.ssh/config status=none << EOF
Host host
	Hostname 10.0.2.2
	User root
	IdentitiesOnly yes
	IdentityFile ~/.ssh/`basename $SSH_KEY`
	StrictHostKeyChecking no
EOF

	# Starts u-root's sshd
	bash <<-EOF
	echo "echo Starting sshd" >> tc_root/tc-sys.sh
	echo "sshd -keys /root/.ssh/authorized_keys -privatekey /root/.ssh/`basename $SSH_KEY` -port $SSHD_PORT &" >> tc_root/tc-sys.sh
	EOF

else
	echo "No SSH_KEY set, you won't be able to SSH in"
fi

# uinitcmd isn't calling the shell afterwards.  and -i for bash, since there's
# some other u-root issue with bash (at least in a VM)
echo "/bin/sh -i" >> tc_root/tc-sys.sh

if [ ! -n "$SKIP_KERNEL" ]; then
	echo "Building Linux modules, adding them to tc_root/"
	KERNEL_MODS=`pwd`/tc_root/
	(cd $LINUX_REPO &&
	 > $LINUX_REPO/$INITRD_NAME &&
	$MAKE &&
	make INSTALL_MOD_PATH=$KERNEL_MODS INSTALL_MOD_STRIP=1 modules_install
	)
fi

TC_ROOT_CPIO=initramfs.tc_root.cpio
(cd tc_root && find . -print | cpio -H newc -o > ../$TC_ROOT_CPIO)
echo "Built $TC_ROOT_CPIO"

# Smash!
# Careful... Linux can extract concatenated cpios, but the cpio tool won't.  The
# first cpio has the sentinel TRAILER!!! file that will end the cpio...
cat $UROOT_CPIO $TC_ROOT_CPIO | gzip > $LINUX_REPO/$INITRD_NAME

if [ ! -n "$SKIP_KERNEL" ]
then
	echo "Building Linux (maybe with embedded CPIO, based on CONFIGS)"
	(cd $LINUX_REPO && $MAKE)
	echo "Final vmlinux at $LINUX_REPO/vmlinux"
fi

echo "Compressed final initramfs at $LINUX_REPO/$INITRD_NAME"

# Example for building and deploying mount-fs:
#./embed_payload.sh vm-apps/mount-fs.sh initramfs.cpio.gz obj/mount-fs
