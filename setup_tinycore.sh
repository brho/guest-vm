#!/bin/bash
# Barret Rhoden (brho@google.com)
#
# Downloads corepure, extracts it to initramfs, and downloads a few extra
# packages and their deps.  Blows away your old tc_core/.
#
# Once you set up tc_root, you can manually edit files, add packages, or
# whatever, then rebuild_cpio_and_linux.sh.  To add a new TCZ package, just edit
# PACKAGES and rerun this script.
# When mucking with tc_root, you'll usually need sudo.  Sorry.
#
# You probably want to set up ssh keys for the TC user, both so you can ssh
# into the VM, as well as so TC can ssh out.  Right now, the server/host keys
# are the same as Akaros's default dropbear server.

set -e
trap "exit" INT

SSHD_PORT=22
VERBOSE=1
#Other fun packages: strace tcpdump
PACKAGES='openssh'

TC_URL=http://tinycorelinux.net/7.x/x86_64/

DIR=`dirname "$0"`
if [[ "$DIR" != "." ]]
then
	echo "Run the script $0 from within its directory: $DIR"
	exit -1
fi

echo "Downloading TC distro"
wget -q -nc $TC_URL/release/distribution_files/corepure64.gz

echo "Extracting TC distro"
sudo rm -rf tc_root
mkdir tc_root
chmod 777 tc_root
(cd tc_root && zcat ../corepure64.gz | sudo cpio -H newc -i)
(cd tc_root && sudo ln -s lib lib64)

######## BASIC DISTRO SETUP

# Homedir for 'tc', in case we're using that account.  Will get chowned later.
sudo mkdir -p tc_root/home/tc

# Even if we don't override rcS, I can't stand the screen clear
sudo sed -i '/^clear$/d' tc_root/etc/init.d/rcS

# We don't want the RTC and don't build it into the kernel.  TC has the 'nortc'
# command line parameter, but I sometimes forget to add it.
sudo sed -i 's/### END functions/### END functions\n\nNORTC=1/' tc_root/etc/init.d/tc-config

# Our auto-login will be root.  Tinycore has a 'tc' user, but this initrd is
# used on machines where we ssh to Akaros, and using 'root' and the same keys
# for both OSes is easier.
sudo touch tc_root/etc/sysconfig/superuser

# When running paravirt, we don't care about the baud anyway.  When running on
# hardware or qemu + serial, we want 115200.  tty1 will be changed to either
# hvc0 or ttyS0 at runtime (bootlocal.sh, see below).  This is so we can run the
# same image in multiple VMs / environments.  We make the changes to inittab
# statically, since bootlocal.sh runs relatively late in boot.  An alternative
# is to change /init.
sudo sed -i 's/38400 tty1/115200 tty1/' tc_root/etc/inittab
sudo sed -i 's/38400 tty1/115200 tty1/' tc_root/sbin/autologin

# Straight-up replacement of TC's mostly-empty bootlocal.sh
sudo dd of=tc_root/opt/bootlocal.sh status=none << EOF
#!/bin/sh
# put other system startup commands here

######## CONSOLE
# Tinycore's default is:
#	tty1::respawn:/sbin/getty -nl /sbin/autologin 38400 tty1
# Plus, there are settings in /sbin/autologin and /etc/securetty that expect
# tty1.  We can't just change inittab either, since we're not PID 1 (init q).
#
# In a VM with virtio-cons, we want hvc0.  On hardware or a VM without virtio
# (e.g. qemu with console=ttyS0), we want to autologin to ttyS0.  Easiest thing
# is to just symlink it.  You'll see an occasional "can't open /dev/tty1:".
# Ignore it.
if [[ -c /dev/hvc0 ]]; then
	rm /dev/tty1
	ln -s hvc0 /dev/tty1
else
	rm /dev/tty1
	ln -s ttyS0 /dev/tty1
fi

[[ -f /root/tc-sys.sh ]] && sh /root/tc-sys.sh
EOF
sudo chmod +x tc_root/opt/bootlocal.sh

# Machine/site-specific setup
[ -e tc-sys.sh-link ] && sudo cp tc-sys.sh-link tc_root/root/tc-sys.sh

# Total override of tinycore's init scripts.  All the tty1, bootlocal, and other
# stuff won't necessarily run, unless your rcS script calls it.
[ -e rcS-link ] && sudo cp rcS-link tc_root/etc/init.d/rcS

######## PACKAGES

echo "Downloading packages"
mkdir -p tczs
cd tczs

declare -A TCZS
for i in $PACKAGES; do
	TCZS["$i.tcz"]="undepped"
done

REDEP=1
while [ $REDEP -eq 1 ]; do
	REDEP=0

	for i in "${!TCZS[@]}"; do
		if [[ ${TCZS[$i]} == "depped" ]]; then
			continue
		fi

		if [[ ! -f $i.dep ]]; then
			curl -sS $TC_URL/tcz/$i.dep > $i.dep
			# Not Found is split over lines...
			if cat $i.dep | xargs | grep -q "Not Found"; then
				echo "" > $i.dep
			fi
		fi
		DEPS=`cat $i.dep`
		TCZS[$i]="depped"

		for j in $DEPS; do
			[[ $VERBOSE ]] && echo Dep: $i pulls in $j
			# We're likely building our own kernel and don't want
			# their modules
			if [[ $j =~ KERNEL ]]; then
				[[ $VERBOSE ]] && echo "Skipping $j (KERNEL modules)"
				continue;
			fi
			if [[ ${TCZS[$j]} == "depped" ]]; then
				continue;
			fi
			TCZS[$j]="undepped"
			REDEP=1
		done
	done
done

for i in "${!TCZS[@]}"; do
	if [[ ${TCZS[$i]} != "depped" ]]; then
		echo "Warning: $i has unmet dependencies! (Our bug)"
	fi
	wget -q -nc $TC_URL/tcz/$i ||
		echo "Failed to download $i; you might have runtime issues"
done
cd ..

echo "Extracting TCZs"

for i in "${!TCZS[@]}"; do
	sudo unsquashfs -f -d tc_root/ tczs/$i >/dev/null
done

(cd tc_root && sudo ldconfig -r . )

######## SSH

# mildly hokey - not indenting.
if [[ $PACKAGES =~ openssh ]]; then

echo "Setting up SSH"

sudo mkdir -p tc_root/usr/local/etc/ssh
sudo mkdir -p tc_root/var/lib/sshd

# creates our sshd_config
sudo dd of=tc_root/usr/local/etc/ssh/sshd_config status=none <<-EOF
# This is ssh server systemwide configuration file.
Port $SSHD_PORT
HostKey /usr/local/etc/ssh/ssh_host_rsa_key
ServerKeyBits 1024
LoginGraceTime 600
KeyRegenerationInterval 3600
PermitRootLogin yes
StrictModes no
X11Forwarding no
PrintMotd yes
SyslogFacility AUTH
LogLevel INFO
RSAAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
EOF

# The RSA key is same server key Akaros uses for its default dropbear setup.
# Using the same keys helps with swapping between TC and Akaros when ssh'ing to
# the same machine.  The other keys are from a random openssh start.
# Precomputing and saving the keys saves a little time at boot.
#
# You can change these on your own, precompute when building the initrd, or
# whatever.  Note that these keys (and this file) are not secret in any way.

# Server rsa key:
sudo dd of=tc_root/usr/local/etc/ssh/ssh_host_rsa_key status=none <<-EOF
-----BEGIN RSA PRIVATE KEY-----
MIICZQIBAAKBgwCAPaxDQDoR05AF7uaM7FvOMFJoC56HX/7T4bSpjRieqsHXD3r5
wk6xpIlohmlmlz8QSCFl2VamyKFL8JpYnekha6M7+7MiK8bzPb7lqmd+dZCk2/4n
JYNnxjFHv8RRWcX6xvrpqZsVpKzMN+nN6Q26ln31TSfiYAIMqaQFiHNpMY0/AgMB
AAECgYIHx/YyVGzRlRUpjv/VMCg34A23+3CAhU4YfBryqLmEMxc03d8X1Xbh53pg
6brueyHb8ox4OhI8Z3MGARDUbKxvFxtDUgZrXktdJqXvsB+jRPO8JoLybrkWmeP4
QdRqzHWPiqzHKNEbIxfYnPoz+A/W9OOsxniMMSD9iflouy8yPpGdAkIAyMnKBy3L
g7EqtHA6s3dxwyN1K4AxBcP9yRSupvSdMWR+Gnwy82jb+98TUU53z+Cbu85dk+Pe
gO5SuFbIjg53FHsCQgCjgQPBLJB/zzDPZvrFexU/vO+GE++5t0pyTB91to1eODaC
H8j6RnEjR+13s1ipVGmDPnTqs35vRmKTkVrb5TiZDQJCAKDILTXIbwI6WUb545eY
Wwl2mDnIQfkq80sUe7KHiGRn4y7UK3yMiDNNc0uVOQ3F/w7JdleZja/Sp3yjSZ+v
Z52HAkFTiXstm2NIqcc6cFb3xucYZaPLUSxOKsOymgoIznh0ByxyV2ML3Cm56On/
GnbWLParw6FguMyEdeWvl7hgWUENkQJBKzT0azmCC4Par0M8Qns39Y80bxrOxc9z
YZIjPU14FiD1uvOj5e2WxYIjqGj3ttsBYc/cKC7MCH4RHp5smOo0yBU=
-----END RSA PRIVATE KEY-----
EOF
sudo chmod 600 tc_root/usr/local/etc/ssh/ssh_host_rsa_key

# Server rsa pubkey:
sudo dd of=tc_root/usr/local/etc/ssh/ssh_host_rsa_key.pub status=none <<-EOF
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgwCAPaxDQDoR05AF7uaM7FvOMFJoC56HX/7T4bSpjRieqsHXD3r5wk6xpIlohmlmlz8QSCFl2VamyKFL8JpYnekha6M7+7MiK8bzPb7lqmd+dZCk2/4nJYNnxjFHv8RRWcX6xvrpqZsVpKzMN+nN6Q26ln31TSfiYAIMqaQFiHNpMY0/ root@
EOF
sudo chmod 600 tc_root/usr/local/etc/ssh/ssh_host_rsa_key.pub

# DSA
sudo dd of=tc_root/usr/local/etc/ssh/ssh_host_dsa_key status=none <<-EOF
-----BEGIN DSA PRIVATE KEY-----
MIIBugIBAAKBgQCa7L4DlYGKYzD5w17MoQq5YuSvN+XZuMWpzj9R95jOpRncjrOB
dApOpuyPX6GQHa6KxTWIG5ReuyBFrgMQMIuB5nzHRViwYopc20JQ3FA7zWD6voPH
vToKEF2Z3j14dpfCnA5kq5U4H9zj9DGjyNp4hdtGqrsepp0/UQ3dtoP+zQIVAOK5
8sb9lDl1ZJ9RGMFUK495ecqnAoGADafo2AJffgjfBvicYMWI8I4YHHrb3rbHWa50
1YUwCC2YEw946BxY0WBRfE2uNdajMhXmphgDDcivsw3rbVUFq1CJ7HMwvwXQVgY+
AuUINYMoqa5vqeYIbYzwZeCSNMC9lvDpA5a2A/V/nn0urff5A/PAXcst01d2JD4D
INM/vYQCgYAAt7bx8oIvxBGpBSLEITeudnGy9J8jYbnUQi0WbnReSATJes12jkqH
z6i5CHQHoyd+wX2Ie5hFpWG6JhMgqFbzhnFyL5XKepXsHD0avsH+M/GiHwsSuZbg
+s578C0fvxqJegr+uOAO9hzrtV58wjTmp3I3c+8yYKhNRcDd5z+FVQIUBUsezpDY
7KDq2wSD/oP2HiwDwOs=
-----END DSA PRIVATE KEY-----
EOF
sudo chmod 600 tc_root/usr/local/etc/ssh/ssh_host_dsa_key

sudo dd of=tc_root/usr/local/etc/ssh/ssh_host_dsa_key.pub status=none <<-EOF
ssh-dss AAAAB3NzaC1kc3MAAACBAJrsvgOVgYpjMPnDXsyhCrli5K835dm4xanOP1H3mM6lGdyOs4F0Ck6m7I9foZAdrorFNYgblF67IEWuAxAwi4HmfMdFWLBiilzbQlDcUDvNYPq+g8e9OgoQXZnePXh2l8KcDmSrlTgf3OP0MaPI2niF20aqux6mnT9RDd22g/7NAAAAFQDiufLG/ZQ5dWSfURjBVCuPeXnKpwAAAIANp+jYAl9+CN8G+JxgxYjwjhgcetvetsdZrnTVhTAILZgTD3joHFjRYFF8Ta411qMyFeamGAMNyK+zDettVQWrUInsczC/BdBWBj4C5Qg1gyiprm+p5ghtjPBl4JI0wL2W8OkDlrYD9X+efS6t9/kD88Bdyy3TV3YkPgMg0z+9hAAAAIAAt7bx8oIvxBGpBSLEITeudnGy9J8jYbnUQi0WbnReSATJes12jkqHz6i5CHQHoyd+wX2Ie5hFpWG6JhMgqFbzhnFyL5XKepXsHD0avsH+M/GiHwsSuZbg+s578C0fvxqJegr+uOAO9hzrtV58wjTmp3I3c+8yYKhNRcDd5z+FVQ== root@
EOF
sudo chmod 600 tc_root/usr/local/etc/ssh/ssh_host_dsa_key.pub

# ECDSA
sudo dd of=tc_root/usr/local/etc/ssh/ssh_host_ecdsa_key status=none <<-EOF
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIDJSnV6xzf5PfKDa7agVfX33seyRAmgQMp9tQ8u2UztqoAoGCCqGSM49
AwEHoUQDQgAEgxWZ0GPel/CwLm5iMeYbokckWnE8uW2Hgo8skQNhpstwe6lYQMVy
dSsejPUpkdJZdaWgRISNtH/jHGjQUYbxxg==
-----END EC PRIVATE KEY-----
EOF
sudo chmod 600 tc_root/usr/local/etc/ssh/ssh_host_ecdsa_key

sudo dd of=tc_root/usr/local/etc/ssh/ssh_host_ecdsa_key.pub status=none <<-EOF
ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBIMVmdBj3pfwsC5uYjHmG6JHJFpxPLlth4KPLJEDYabLcHupWEDFcnUrHoz1KZHSWXWloESEjbR/4xxo0FGG8cY= root@
EOF
sudo chmod 600 tc_root/usr/local/etc/ssh/ssh_host_ecdsa_key.pub

sudo bash <<-EOF
echo '/usr/local/etc/init.d/openssh start' >> tc_root/opt/bootlocal.sh
EOF

fi #openssh
