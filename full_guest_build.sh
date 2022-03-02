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
# rebuild_cpio_and_linux.sh $LINUX_ROOT.

set -e
trap "exit" INT

# Set this to paths to binaries on your system, however you'd like.  They will
# show up in /usr/local/bin/
#
# Careful of spaces.
CUSTOM_BINARIES=""
# Most of my VM apps use this.
CUSTOM_BINARIES+=" progs/bin/tinyreboot "
## For mount-fs
#CUSTOM_BINARIES+=" $HOME/go/bin/ufs "
## This is relatively large (15 MB)
#CUSTOM_BINARIES+="$HOME/src/linux/tools/perf/perf"
## TC's taskset is mediocre.
#CUSTOM_BINARIES+=" "
#CUSTOM_BINARIES+=`which taskset`
#CUSTOM_BINARIES+=" "

# Will remove these files from the tinycore image.  Paths are relative to
# tc_root.  Find victims with ./cat_cpio_gz.sh.  Can also automate this.
#
# Careful of spaces.
CUSTOM_REMOVALS=""
## fdisk and a lot of simple apps don't need C++
#CUSTOM_REMOVALS+=" usr/lib/libstdc++.so.6.0.21 "

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

# Kernel config
cp kernel.config $LINUX_ROOT/.config

# Build any of our tiny programs
(cd progs && make)

./setup_tinycore.sh

for i in $CUSTOM_BINARIES; do
	sudo cp $i tc_root/usr/local/bin/
done
sudo chmod -R o+rx tc_root/usr/local/bin/

for i in $CUSTOM_REMOVALS; do
	sudo rm tc_root/$i
done

######## SSH
# Do your own stuff here.  This lets me ssh in and out as either tc or root

if [ -f ~/.ssh/db_rsa.pub ]; then

	sudo mkdir -p tc_root/home/tc/.ssh/
	sudo cp ~/.ssh/db_rsa.pub tc_root/home/tc/.ssh/authorized_keys
	sudo cp ~/.ssh/db_rsa.pub tc_root/home/tc/.ssh/
	sudo cp ~/.ssh/db_rsa tc_root/home/tc/.ssh/

	sudo mkdir -p tc_root/root/.ssh/
	sudo cp ~/.ssh/db_rsa.pub tc_root/root/.ssh/authorized_keys
	sudo cp ~/.ssh/db_rsa.pub tc_root/root/.ssh/
	sudo cp ~/.ssh/db_rsa tc_root/root/.ssh/

# This implies the VM is using qemu mode addressing
	sudo dd of=tc_root/home/tc/.ssh/config status=none << EOF
Host host
	Hostname 10.0.2.2
	User root
	IdentitiesOnly yes
	IdentityFile ~/.ssh/db_rsa
	StrictHostKeyChecking no
EOF
	sudo cp tc_root/home/tc/.ssh/config tc_root/root/.ssh/

fi

./rebuild_cpio_and_linux.sh $LINUX_ROOT

######## Copy it somewhere
# Yes, the initrd name must be the same as the one in rebuild_cpio_and_linux.sh.

#echo "Copying to devbox"
#[ ! -n "$SKIP_KERNEL" ] && scp $LINUX_ROOT/vmlinux devbox:
#scp $LINUX_ROOT/akaros/initramfs.cpio.gz devbox:

# Example for building and deploying mount-fs:
#./embed_payload.sh vm-apps/mount-fs.sh initramfs.cpio.gz obj/mount-fs
#
#scp obj/mount-fs devbox:bin/
