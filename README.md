BTRFS Initrd 
======

btrfs-initrd creates an initrd image to support mounting a btrfs subvolume as root during boot.

Usage
-----
```bash
$ mount /boot
# Creates /boot/initrd-btrfs-$KERNEL.gz
$ ./btrfs_create_initrd.sh
```
After that, update your bootloader config.


Requirements
-----

- MAKEDEV
- busybox
- pivot_root
- btrfs (btrfs-progs)

Example bootloader config
-----

Lilo config

```go
image=/boot/3.17.7 
    label=3.17.7-btrfsn 
    initrd=/boot/initrd-btrfs-3.17.7-gentoo.gz 
    append="root=/dev/ram0 realroot=/dev/sda5 subvol=root"
```

Contribution
-----

Feel free to make a pull request. For bigger changes create a issue first to discuss about it.


License
-----

GPL - See [LICENSE NOTICE](btrfs_create_initrd.sh).
