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
	int fd, conn_fd;
	ssize_t ret;
	char buf[20];
	struct sockaddr_vm sa_vm = {0};
	socklen_t sa_size;
	// For sanity, always listen on ANY, guest or host
	int cid = VMADDR_CID_ANY;

	if (argc > 1) {
		cid = (int)strtol(argv[1], NULL, 0);
	}

	fd = socket(AF_VSOCK, SOCK_STREAM, 0);
	if (fd < 0)
		handle_error("socket");
	sa_vm.svm_family = AF_VSOCK;
	// 
	sa_vm.svm_port = 1234;
	sa_vm.svm_cid = cid;

	ret = bind(fd, (struct sockaddr *)&sa_vm, sizeof(sa_vm));
	if (ret < 0)
		handle_error("bind");
	ret = listen(fd, 0);
	if (ret < 0)
		handle_error("listen");
	conn_fd = accept(fd, NULL, NULL);
	if (conn_fd < 0)
		handle_error("accept");

	sa_size = sizeof(sa_vm);
	ret = getpeername(conn_fd, (struct sockaddr *)&sa_vm, &sa_size);
	if (ret < 0)
		handle_error("getpeername");
	printf("got connection from family %d (%d) CID %d, port %d\n",
	       sa_vm.svm_family, AF_VSOCK, sa_vm.svm_cid, sa_vm.svm_port);

	while ((ret = read(conn_fd, buf, sizeof(buf))) > 0)
		printf("read :%s:\n", buf);
	if (ret < 0)
		handle_error("read");

	close(conn_fd);
	close(fd);
	return 0;
}
