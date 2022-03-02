#!/bin/bash
# Barret Rhoden (brho@google.com)
#
# Sets up the host's tun/tap for IPv4 and IPv6 to the guest


ip link delete tap-vm 2>/dev/null
ip link delete br-vm 2>/dev/null

ip link add br-vm type bridge
ip addr add 10.0.2.2/24 dev br-vm 2>/dev/null || true
ip addr add fd0:1234:4321::2/64 dev br-vm
ip link set up dev br-vm
ip tuntap add tap-vm mode tap
ip link set up dev tap-vm
ip link set tap-vm master br-vm
