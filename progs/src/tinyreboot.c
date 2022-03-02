/* Copyright (c) 2019 Google, Inc                                                
 * Barret Rhoden <brho@google.com>                                          
 * See LICENSE for details.
 *
 * Syncs and reboots.
 *
 * If you want something extremely small and static, we can hack up a vmcall. */

#include <unistd.h>
#include <sys/reboot.h>

int main()
{
	sync();
	reboot(RB_HALT_SYSTEM);
	return -1;
}
