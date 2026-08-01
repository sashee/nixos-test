# Filesystem types that are not writable data volumes, shared by everything that walks the
# mount table: the disk-space health check (modules/monitoring.nix) and the measurement
# collector (modules/system-metrics.nix). One copy, so a type added for one of them cannot
# stay missing from the other -- they read the same /proc/mounts and would otherwise disagree
# about what a "filesystem" is.
[
  # Kernel and pseudo filesystems: either sized 0 (so a used-percentage is meaningless) or
  # sized after RAM rather than after any disk.
  "tmpfs"
  "devtmpfs"
  "ramfs"
  "efivarfs"
  "proc"
  "sysfs"
  "devpts"
  "cgroup"
  "cgroup2"
  "pstore"
  "securityfs"
  "debugfs"
  "tracefs"
  "fusectl"
  "configfs"
  "bpf"
  "binfmt_misc"
  "mqueue"
  "hugetlbfs"
  "nsfs"
  "autofs"
  # Read-only / store-transport filesystems, not writable data volumes to alert on. In VM
  # tests these expose the builder's host store (its real disk usage), which would otherwise
  # make the check depend on the builder's free space.
  "9p"
  "virtiofs"
  "erofs"
  "squashfs"
]
