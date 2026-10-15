// SPDX-License-Identifier: GPL-2.0
/*
 * Test-only: oopses as soon as it is loaded. Neither kernel the rpi tests boot has LKDTM.
 *
 * BUG() from module init is an oops in the context of the modprobe that loaded it, not a
 * panic. By default the kernel kills that one process and carries on, so the machine only
 * panics (and, with panic=, reboots) when oops=panic is in effect, which is what
 * tests/crash-recovery.nix checks.
 */
#include <linux/bug.h>
#include <linux/init.h>
#include <linux/module.h>

static int __init crash_recovery_oops_init(void)
{
	BUG();
	return 0;
}
module_init(crash_recovery_oops_init);

MODULE_DESCRIPTION("Oopses on load (test-only)");
MODULE_LICENSE("GPL");
