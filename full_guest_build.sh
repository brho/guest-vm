#!/bin/bash
# Barret Rhoden (brho@google.com)
#
# Helper script - sets up the tinycore image (setup_tinycore.sh), adds custom
# binaries and config files, builds the CPIO and guest kernel
# (rebuild_cpio_and_linux.sh), and copies the guest to various places.
#
# You need to call this from the directory it is in and pass it a non-relative
# path to a linux repo.  You can set SKIP_KERNEL=1 to avoid rebuilding the guest
# kernel.
#
# You'll want to customize this for your environment.  You'll also want to set
# the PACKAGES variable in setup_tinycore.sh.  This is heavily
# customized for brho's system.
#
# If you don't care about ssh or anything, consider just running
# setup_tinycore.sh, optionally mucking with the contents of tc_root, and then
# rebuild_cpio_and_linux.sh

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

DIR=`dirname "$0"`
if [[ "$DIR" != "." ]]; then
	echo "Run the script $0 from within its directory: $DIR"
	exit -1
fi

if [ ! -z $KERNEL_CONFIG ]; then
	cp $KERNEL_CONFIG $LINUX_REPO/.config
fi

# Build any of our tiny programs
(cd progs && make)

./setup_tinycore.sh

for i in $CUSTOM_BINARIES; do
	# sudo cp doesn't work for some weird file types; bounce them off /tmp/
	BOUNCE=/tmp/`basename $i`
	rm -f $BOUNCE
	cp $i $BOUNCE
	sudo cp $BOUNCE tc_root/usr/local/bin/
done
sudo chmod -R o+rx tc_root/usr/local/bin/

for i in $CUSTOM_REMOVALS; do
	sudo rm tc_root/$i
done

######## SSH
# Do your own stuff here.  This lets me ssh in and out as either tc or root
if [ ! -z $SSH_KEY ]; then

	sudo mkdir -p tc_root/home/tc/.ssh/
	sudo cp $SSH_KEY.pub tc_root/home/tc/.ssh/authorized_keys
	sudo cp $SSH_KEY.pub tc_root/home/tc/.ssh/
	sudo cp $SSH_KEY tc_root/home/tc/.ssh/

	sudo mkdir -p tc_root/root/.ssh/
	sudo cp $SSH_KEY.pub tc_root/root/.ssh/authorized_keys
	sudo cp $SSH_KEY.pub tc_root/root/.ssh/
	sudo cp $SSH_KEY tc_root/root/.ssh/

	# This implies the VM is using qemu mode addressing
	sudo dd of=tc_root/home/tc/.ssh/config status=none << EOF
Host host
	Hostname 10.0.2.2
	User root
	IdentitiesOnly yes
	IdentityFile ~/.ssh/`basename $SSH_KEY`
	StrictHostKeyChecking no
EOF
	sudo cp tc_root/home/tc/.ssh/config tc_root/root/.ssh/

else
	echo "No SSH_KEY set, you won't be able to SSH in"
fi

./rebuild_cpio_and_linux.sh

######## Copy it somewhere
# Yes, the initrd name must be the same as the one in rebuild_cpio_and_linux.sh.

#echo "Copying to devbox"
#[ ! -n "$SKIP_KERNEL" ] && scp $LINUX_REPO/vmlinux devbox:
#scp $LINUX_REPO/akaros/initramfs.cpio.gz devbox:

# Example for building and deploying mount-fs:
#./embed_payload.sh vm-apps/mount-fs.sh initramfs.cpio.gz obj/mount-fs
#
#scp obj/mount-fs devbox:bin/
