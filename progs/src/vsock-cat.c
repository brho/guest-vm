#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <assert.h>
#include <errno.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#include <sys/socket.h>
#include <linux/vm_sockets.h>

#define handle_error(msg) \
        do { perror(msg); exit(-1); } while (0)

int main(int argc, char *argv[])
{
	int fd;
	ssize_t ret;
	char buf[20] = "HELLO";
	struct sockaddr_vm sa_vm = {0};
	int cid = VMADDR_CID_HOST;

	if (argc > 1) {
		cid = (int)strtol(argv[1], NULL, 0);
	}
	fd = socket(AF_VSOCK, SOCK_STREAM, 0);
	if (fd < 0)
		handle_error("socket");
	sa_vm.svm_family = AF_VSOCK;
	// hardcoded port
	sa_vm.svm_port = 1234;
	sa_vm.svm_cid = cid;

	ret = connect(fd, (struct sockaddr *)&sa_vm, sizeof(sa_vm));
	if (ret < 0)
		handle_error("connect");

	ret = write(fd, buf, sizeof(buf));
	if (ret < 0)
		handle_error("write");

	close(fd);
	return 0;
}

/*
 * NOTES:
 *
 * CID_HYPERVISOR = 0
 * CID_LOCAL      = 1
 * CID_HOST       = 2
 * CID_ANY 	  = -1
 *
 * qemu with args didn't seem to have an ss vhost socket
 * 	it doesn't create the socket, but it sets up some channel (vhost?) so
 * 	that its CID (42) is reserved and associated with qemu
 *
 * qemu with cid=42:
 * 	server can't bind to 42: 
 * 		bind: Cannot assign requested address
 * 			regardless of whether qemu is running or not
 * 		what does qemu do?
 * 			some ioctl mess on /dev/vhost-vsock
 * 			see way below
 * 			it's not binding that socket CID=42 though
 * 			seems like no one can bind it.
 *
 * 	if the host server listens on CID_ANY (bind and listen)
 * 		you host listen on *:1234 (according to ss)
 * 		server can use getpeername() to determine who is on the other
 * 		end
 * 		- host client can get to it via CID_HOST *or* CID_LOCAL
 * 			getpeername says it is from CID 1 (LOCAL)
 * 			*DO NOT USE CID_HOST for this*  (see below)
 * 		- host client cannot get to it with HYPERVISOR
 * 		- host client cannot get to it with 42
 * 			- if qemu is running on CID=42, ECONNRESET
 * 			- if not, ENODEV
 * 		- guest client can get to it via CID_HOST
 * 			getpeername says it is from "42": qemu's assigned CID
 * 		- guest client cannot get to it with HYPERVISOR
 * 			timesout.  maybe some qemu internal thing?
 *
 * 	if the host server listens on CID_HOST
 * 		host client cannot reach via CID_LOCAL. (expected)
 * 		host client can reach via CID_HOST
 * 		guest client can reach via CID_HOST
 * 			getpeername: 42
 *
 * 	if the host server listens on CID_LOCAL
 * 		host client can reach via CID_LOCAL.
 * 		host client cannot reach via CID_HOST
 * 		guest client cannot reach via CID_HOST
 *
 * 	if the guest server listens on CID_ANY
 * 		host client can reach via 42 (qemu number)
 * 			connection came from CID=2 (HOST)
 * 		host cannot reach via CID_HOST (makes sense)
 * 		guest client can reach via 42
 * 			connection came from CID=1 (LOCAL)
 * 		guest client can reach via CID_LOCAL
 * 		guest cannot reach via CID_HOST (surprise!)
 * 			this works if you are in the host!  so CID_HOST isn't a
 * 			relative term.  if you're in a VM, it means the HOST.
 * 			if you are the HOST, it means you.  that means code that
 * 			'works' natively won't work in a guest.
 *
 * 	if the guest server listens on 42
 * 		host client can reach via 42 (qemu number)
 * 			connection came from CID=2 (HOST)
 * 		guest client can reach via 42
 * 			connection came from CID=1 (LOCAL)
 * 		guest client *CANNOT* reach via CID_LOCAL
 * 			differs from guest listening on CID_ANY
 *
 * 	if the guest server listens on CID_HOST
 * 		host client cannot reach
 * 		guest client cannot reach (CID_HOST or CID_LOCAL or 42)
 *
 * 	if the guest server listens on CID_LOCAL
 * 		guest can reach via LOCAL.  all else fails
 *
 * OK:
 * 	1) guest server bind/listen, host client connects:
 * 	- guest listens on CID_ANY or vmm-reserved guest-cid "42"
 * 		- recommended to listen on ANY, since you need to do an ioctl in
 * 		the guest to figure out '42'
 * 		- if CID_ANY, the guest can connect via CID_LOCAL.  but not with
 * 		CID=42.  if you explicitly listen on CID=42, the guest must
 * 		connect to CID=42.
 * 	- host connects via '42', always.
 * 	- extra:
 * 		- guest connects via CID_LOCAL (if listen on CID_ANY) or CID=42
 * 		always
 * 		- not sure how to restrict host connections: who all can connect
 * 		to CID=42?  any host process?  not clear that '42' is secret.
 * 		similar issues to tun/tap with random IPv6 addrs
 * 		- not a big deal either, since cpud uses ssh and nonce keys.
 *
 * 	2) host server listen, guest connects:
 * 	- host listens on CID_ANY or CID_HOST
 * 	- guest connects via CID_HOST
 *
 * 	- extra
 * 		- host connects via CID_LOCAL (if listen on CID_ANY) or CID_HOST
 * 		always
 * 		- any guest can connect to this.  getpeername() tells you which
 * 		guest it was, e.g. CID=42.
 * 		- same issues with restricting connections: we can't, but we can
 * 		tell who it is
 * 		- not a big deal with cpu: so long as we use the nonce.
 *
 * Kernel CONFIG
 *

CONFIG_VSOCKETS=y
CONFIG_VSOCKETS_DIAG=y
CONFIG_VSOCKETS_LOOPBACK=y
CONFIG_VIRTIO_VSOCKETS=y
CONFIG_VIRTIO_VSOCKETS_COMMON=y
CONFIG_VHOST_VSOCK=y

 *
 * qemu strace, with -device vhost-vsock-pci,guest-cid=42

36865 openat(AT_FDCWD, "/dev/vhost-vsock", O_RDWR) = 37
36865 mmap(NULL, 135168, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0) = 0x7f2d4419d000
36865 ioctl(37, VHOST_SET_OWNER, 0)     = 0
36865 ioctl(37, VHOST_GET_FEATURES, 0x7ffc65fdc2e0) = 0
36865 eventfd2(0, EFD_CLOEXEC|EFD_NONBLOCK) = 38
36865 ioctl(37, VHOST_SET_VRING_CALL, 0x7ffc65fdc2f0) = 0
36865 eventfd2(0, EFD_CLOEXEC|EFD_NONBLOCK) = 39
36865 ioctl(37, VHOST_SET_VRING_CALL, 0x7ffc65fdc2f0) = 0
36865 openat(AT_FDCWD, "/sys/module/vhost/parameters/max_mem_regions", O_RDONLY) = 40
36865 newfstatat(40, "", {st_mode=S_IFREG|0444, st_size=4096, ...}, AT_EMPTY_PATH) = 0
36865 read(40, "64\n", 4096)            = 3
36865 read(40, "", 4093)                = 0
36865 close(40)                         = 0
36865 futex(0x7f2d481d1fe8, FUTEX_WAKE_PRIVATE, 2147483647) = 0
36865 ioctl(37, VHOST_VSOCK_SET_GUEST_CID, 0x7ffc65fdc328) = 0

*/
