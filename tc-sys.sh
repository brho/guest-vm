#!/bin/sh
# brho@google.com
# Machine and site-specific runtime configuration/init scripts

# Here's an example of what you can do.  This example is a little hokey for two
# reasons:
# - DHCP may be running, and Akaros's virtio-net NAT will give a response.  We
# kill it if it was already running.  Maybe that's enough.  If you know your
# app/VM won't need dhcp, pass tinycore nodhcp, or override rcS.
# - Akaros's NAT is set up to give 10.0.2.15 for that specific MAC.  Though
# that may change over time, and other VMs may have that same MAC.  I use the
# same MAC for qemu and cloud-hypervisor.  YMMV.

NIC=eth0

read MAC < /sys/class/net/$NIC/address

if [[ "$MAC" == "00:01:02:03:04:0b" ]]; then
	echo "Detected magic paravirt mac address on $NIC, setting up static networking" > /dev/kmsg
	killall udhcpc 2> /dev/null

	while : ; do
		read CARRIER < /sys/class/net/$NIC/carrier
		# 1 is up, but CARRIER could be empty
		[ "x$CARRIER" == "x1" ] && break
		usleep 10000
	done

	ifconfig $NIC up 10.0.2.15 netmask 255.255.255.0 broadcast 10.0.2.255
	route add default gw 10.0.2.2 $NIC
	echo "nameserver 8.8.8.8" > /etc/resolv.conf 

	# For hosts using IPv6 only
	ifconfig $NIC add fd0:1234:4321::15/64

	# For my own sanity.  Note that tc-sys.sh often runs backgrounded.
	echo "Static networking complete" > /dev/kmsg
else
	echo "Unknown host, turning on DHCP" > /dev/kmsg
	/etc/init.d/dhcp.sh
fi
