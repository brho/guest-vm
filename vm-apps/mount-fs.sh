#!/bin/bash
# Copyright (c) 2019 Google, Inc
# Barret Rhoden <brho@cs.berkeley.edu>
#
# File system mounter
#
# 	Usage: $0 /full/path/to/disk/data PART_ID /full/path/to/mnt [mount opts]
# 
# Run fdisk -l to get the partition ID. "" for None.
#
# Mount opts are the standard Akaros/Plan 9 mount command args.  -b, -a, -c, -C,
# etc.  Fun note: -c (create) is about creation, not modification.  You can edit
# even without -c.  But you can't create.
#
# Kill the shell process to clean up.  If you forget to unmount first, this will
# do it for you too.
#
# TODO:
# - HOST_PORT is static, but might be in use
# - srv occasionally gets hung, stuck in syn-sent.  Might be a kernel TCP bug
# (should time out faster?).  If you see srv running in ps, kill it once.
# - If something breaks, things go to hell quickly.  Typically if the VM is
# stuck, srv will just keep hammering away in its loop.  The most obvious
# symptom is if you run ps a few times and see "can't open
# '#proc/23720/status...", which is because srv dies before ps can cat its
# status.
# - If you kill the shell, it shuts down cleanly.  If you kill VMRK, it doesn't.
# It'd be nice to be able to kill either one and have VMRK 'forward' its SIGINT
# to its parent or something.  Note that ctl-c in dropbear might kill either of
# them.
# - It'd be nice to be able to change the process's name in 'ps', for easier
# killing.
# - Tune memory usage, etc
# - For debugging, you can set console=hvc0 *and* don't redirect VMRK's output
# to /dev/null.  If you run 'ash' in rcS, you probably need to talk to it via
# pipe/data, which is in /srv.  If you want to ssh, add it to setup_tinycore.sh,
# start it in rcS, and add a port-forward to vnet-opts.

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

HOST_PORT=3333
GUEST_PORT=3332

if [ $# -lt 3 ]; then
	# or empty quotes for part
	echo "Usage: $0 /full/path/to/disk/data PART_ID /full/path/to/mnt [mount opts]"
	exit
fi

DISK=$1
PART_ID=$2
MNT=$3
shift 3
MNT_OPTS=$*

shutdown_vm() {
	# unmount also syncs the GTFS, so we want to do that before telling the
	# guest to shutdown.  Callers might have already unmounted it.  This is
	# more of an attempt to sync data before we just kill the fileserver.
	unmount $MNT &>/dev/null || true
	echo SHUTDOWN > pipe/data
}
trap "shutdown_vm" SIGINT SIGTERM

cleanup() {
	set +e
	rm -f /srv/ext4-$$
	rm -f /srv/pipe-data-$$
	# If we don't unmount this before the script exits, we'll leak our
	# #tmpfs until the entire namespace is cleaned up.
	unmount pipe/
	# If the guest crashed or shutdown before we synced, we may have lost
	# data (cached in the gtfs, if applicable).  We also left something
	# mounted.  This will remove it if we hadn't already removed it.
	unmount $MNT &>/dev/null || true
}
trap "cleanup" EXIT

cd -P '#tmpfs' 2>/dev/null

echo "port:tcp:$HOST_PORT:$GUEST_PORT" > vnet_opts

cat > guest_cmdline <<EOF
console=none
lapic=notscdeadline
nortc
nozswap
mount_part_id=$PART_ID
mount_port_nr=$GUEST_PORT
EOF

# Creates data and data1, two sides of a Plan 9 pipe.  VMRK will read on
# 'data1'; we'll send a control message on 'data'.
mkdir pipe
/bin/bind '#pipe' pipe

# Pipes hangup when one side closes.  That means we can only script a single
# command, after which it hangs up.  Virtio-cons will complain too (on EOF),
# even if you use a single command.  If we drop a copy of the chan for the end
# we want to write to (pipe/data) in srv, that will keep the pipe open (i.e. a
# long-lived FD points to the pipe/data chan).
echo 0 < pipe/data > /srv/pipe-data-$$

extract_initramfs

# Note the full path to the VM and initrd.  Our pwd is #tmpfs, not the directory
# we started in.  We also squelch the output, o/w the VM blurts out whatever it
# heard on its hvc0 (i.e. 'SHUTDOWN')
vmrunkernel -k guest_cmdline -n vnet_opts -m 0x8000000 -f $DISK -s \
	/lib/vmlinux -i initramfs < pipe/data1 &>/dev/null &
VMRK_PID=$!

# This is hokey.  If srv pokes the guest at the wrong time, it'll get stuck in
# SYN_SENT.  Not sure where the bug is.  Easiest thing is to wait 1 sec, which
# is more than enough time for VMRK to start the guest.
while true; do
	sleep 1
	srv "tcp!127.0.0.1!$HOST_PORT" ext4-$$ &>/dev/null && break
done

mount $MNT_OPTS /srv/ext4-$$ $MNT

# This first wait will get interrupted by kill.  At that point, the VM should be
# unmounting and shutting down
wait $VMRK_PID || true

# Wait again for them to finish.  We could use a timer or something too.
wait $VMRK_PID || true

# Automatically runs 'cleanup' on EXIT
exit 0
