#!/bin/bash
#
# Modified version of lvm2create_initrd to support btrfs filesystem mounting using subvolumes
#
# Modified version (support btrfs) from Benedikt Lang <github (at) blang (dot) io>
# Original version (support lvm) from Miguel Cabeca <cabeca (at) ist (dot) utl (dot) pt> (lvm2create_initrd):
#
## BTRFS modification:
# 
# Support for root volumes mounted as btrfs subvolumes. LVM Support removed (btrfs has volume manager builtin)
# Tested on gentoo with kernel 3.17.7.
#
## Original Notice:
#
# Inspiration to write this script came from various sources
#
# Original LVM lvmcreate_initrd: ftp://ftp.sistina.com/pub/LVM/1.0/
# Kernel initrd.txt: http://www.kernel.org/
# EVMS INSTALL.initrd & linuxrc: http://evms.sourceforge.net/
# Jeffrey Layton's lvm2create_initrd: http://poochiereds.net/svn/lvm2create_initrd/
# Christophe Saout's initrd & linuxrc: http://www.saout.de/misc/
#
# This script was only tested with kernel 2.6 with everything required to boot 
# the root filesystem built-in (not as modules). Ex: SCSI or IDE, RAID, device mapper
# It does not support devfs as it is deprecated in the 2.6 kernel series
#
# It needs lvm2 tools, busybox, pivot_root, MAKEDEV
#
# It has been tested on Debian sid (unstable) only
#
# Changelog
# 26/02/2004	Initial release -- Miguel Cabeca
# 27/02/2004	Removed the BUSYBOXSYMLINKS var. The links are now determined at runtime.
#		some changes in init script to call a shell if something goes wrong. -- Miguel Cabeca
# 19/04/2004    Several small changes. Pass args to init so single user mode works. Add some
#               PATH entries to /sbin/init shell script so chroot works without /usr mounted. Remove
#               mkdir /initrd so we don't cause problems if root filesystem is corrupted. -- Jeff Layton
# 15/05/2004	initial support for modules, create lvm.conf from lvm dumpconfig, other cleanups -- Jeff Layton
# 14/11/2006	Update handling of ldd output to handle hardcoded library links and virtual dll linux-gate.
#		Add support for Gentoo-style MAKEDEV. Remove hardcoded BINUTILS paths -- Douglas Mayle
# 01/01/2015  Removed lvm support and added btrfs subvolume support. -- Benedikt Lang
#
# Copyright Miguel Cabeca, Jeffrey Layton, 2004
# Copyright Benedikt Lang, 2015
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
# $Id$

TMPMNT=/tmp/mnt.$$
DEVRAM=/tmp/initrd.$$

# set defaults
BINFILES=${BINFILES:-"`which bash` `which busybox` `which pivot_root` `which btrfs`"}
BASICDEVICES=${BASICDEVICES:-"std consoleonly fd"}
BLOCKDEVICES=${BLOCKDEVICES:-"md hda hdb hdc hdd sda sdb sdc sdd"}
MAKEDEV=${MAKEDEV:-"debian"}

# Uncomment this if you want to disable automatic size detection
#INITRDSIZE=4096

PATH=/bin:/sbin:/usr/bin:/usr/sbin:$PATH

usage () {
	echo "Create an initial ramdisk image for BTRFS root filesystem"
	echo "$cmd: [-h] [-v] [-m modulelist] [-e extrafiles] -r [raiddevs] [-R mdadm.conf] [-M style] [kernel version]"
	echo "      -h|--help      print this usage message"
	echo "      -v|--verbose   verbose progress messages"
	echo "      -m|--modules   modules to copy to initrd image"
	echo "      -e|--extra     extra files to add to initrd"
	echo "      -r|--raid      raid devices to start in initrd"
	echo "      -R|--raidconf  location of mdadm.conf file to include"
	echo "      -M|--makedev   set MAKEDEV type (debian, redhat, gentoo)"
}

verbose () {
   [ "$VERBOSE" ] && echo "`echo $cmd | tr '[a-z0-9/_]' ' '` -- $1" || true
}

cleanup () {
  [ "`mount | grep $DEVRAM`" ] && verbose "unmounting $DEVRAM" && umount $DEVRAM
  [ -f $DEVRAM ] && verbose "removing $DEVRAM" && rm $DEVRAM
  [ -d $TMPMNT ] && verbose "removing $TMPMNT" && rmdir $TMPMNT
  verbose "exit with code $1"
  exit $1
}

trap "
  verbose 'Caught interrupt'
  echo 'Bye bye...'
  cleanup 1
" 1 2 3 15

create_init () {
   cat << 'INIT' > $TMPMNT/sbin/init
#!/bin/bash

# include in the path some dirs from the real root filesystem
# for chroot, blockdev
PATH="/sbin:/bin:/usr/sbin:/usr/bin:/lib/lvm-200:/initrd/bin:/initrd/sbin"
PRE="initrd:"

do_shell(){
    /bin/echo
    /bin/echo "*** Entering Rescue shell. Exit shell to continue booting. ***"
    /bin/echo
    /bin/bash
}

echo "$PRE Remounting / read/write"
mount -t ext2 -o remount,rw /dev/ram0 /


# We need /proc for device mapper
echo "$PRE Mounting /proc"
mount -t proc none /proc

# We need /sys for lvm
echo "$PRE Mounting /sys"
mount -t sysfs sysfs /sys

# plug in modules listed in /etc/modules
if [ -f /etc/modules ]; then
    echo -n "$PRE plugging in kernel modules:"
    cat /etc/modules |
    while read module; do
        echo -n " $module"
        modprobe $module
    done
    echo '.'
fi


# Scan for btrfs devices (find arrays of btrfs partitions)
btrfs device scan

# Create the /dev/mapper/control device for the ioctl
# interface using the major and minor numbers that have been allocated
# dynamically.

echo -n "$PRE Finding device mapper major and minor numbers "

MAJOR=$(sed -n 's/^ *\([0-9]\+\) \+misc$/\1/p' /proc/devices)
MINOR=$(sed -n 's/^ *\([0-9]\+\) \+device-mapper$/\1/p' /proc/misc)
if test -n "$MAJOR" -a -n "$MINOR" ; then
	mkdir -p -m 755 /dev/mapper
	mknod -m 600 /dev/mapper/control c $MAJOR $MINOR
fi

echo "($MAJOR,$MINOR)"

# Get real root volume, since root is initrd
for arg in `cat /proc/cmdline`; do
	echo $arg | grep '^realroot=' > /dev/null
	if [ $? -eq 0 ]; then
		rootvol=${arg#realroot=}
		break
	fi
done

# Determine btrfs subvolume
for arg in `cat /proc/cmdline`; do
	echo $arg | grep '^subvol=' > /dev/null
	if [ $? -eq 0 ]; then
		subvol=${arg#subvol=}
		break
	fi
done

echo "$PRE Mounting root filesystem $rootvol with subvol $subvol ro"
mkdir /rootvol
if ! mount -t btrfs -o ro,subvol=$subvol $rootvol /rootvol; then
	echo "\t*FAILED TRYING TO MOUNT ROOTVOL*";
	do_shell
fi

echo "$PRE Umounting /proc"
umount /proc

echo "$PRE Umounting /sys"
umount /sys

echo "$PRE Changing roots"
cd /rootvol

# Rootvol needs /initrd empty directory
if ! pivot_root . initrd ; then
	echo "\t*FAILED PIVOT TO NEW ROOT*"
	do_shell
fi

echo "$PRE Proceeding with boot..."

exec chroot . /bin/sh -c "umount /initrd/dev; umount /initrd; blockdev --flushbufs /dev/ram0 ; exec /sbin/init $*" < dev/console > dev/console 2>&1

INIT
   chmod 555 $TMPMNT/sbin/init
}


#
# Main
#

cmd=`basename $0`

VERSION=`uname -r`

while [ $# -gt 0 ]; do
   case $1 in
   -h|--help) usage; exit 0;;
   -v|--verbose)  VERBOSE="y";;
   -m|--modules)  MODULES=$2; shift;;
   -e|--extra)    EXTRAFILES=$2; shift;;
   -r|--raid)     RAID=$2; shift;;
   -R|--raidconf) RAIDCONF=$2; shift;;
   -M|--makedev)  MAKEDEV=$2; shift;;
   [2-9].[0-9]*.[0-9]*) VERSION=$1;;
   *) echo "$cmd -- invalid option '$1'"; usage; exit 0;;
   esac
   shift
done

INITRD=${INITRD:-"/boot/initrd-btrfs-$VERSION.gz"}

echo "$cmd -- make initial ram disk $INITRD"
echo ""

if [ -n "$RAID" ]; then
    BINFILES="$BINFILES /sbin/mdadm"
    RAIDCONF=${RAIDCONF:-"/etc/mdadm/mdadm.conf"}
    if [ -r $RAIDCONF ]; then
	EXTRAFILES="$EXTRAFILES $RAIDCONF"
    else
        echo "$cmd -- WARNING: No $RAIDCONF! Your RAID device minor numbers must match their superblock values!"
    fi
fi

# add modprobe if we declared any modules
if [ -n "$MODULES" ]; then
    BINFILES="$BINFILES /sbin/modprobe /sbin/insmod /sbin/rmmod"
fi

for a in $BINFILES $EXTRAFILES; do
    if [ ! -r "$a" ] ; then
	echo "$cmd -- ERROR: you need $a"
	exit 1;
    fi;
done

# Figure out which shared libraries we actually need in our initrd
echo "$cmd -- finding required shared libraries"
verbose "BINFILES: `echo $BINFILES`"

# We need to strip certain lines from ldd output.  This is the full output of an example ldd:
#lvmhost~ # ldd /sbin/lvm /bin/bash
#/sbin/lvm:
#        not a dynamic executable
#/bin/bash:
#        linux-gate.so.1 =>  (0xbfffe000)
#        libncurses.so.5 => /lib/libncurses.so.5 (0xb7ee3000)
#        libdl.so.2 => /lib/libdl.so.2 (0xb7edf000)
#        libc.so.6 => /lib/libc.so.6 (0xb7dc1000)
#        /lib/ld-linux.so.2 (0xb7f28000)
#
# 1) Lines with a ":" contain the name of the original binary we're examining, and so are unnecessary.
#    We need to strip them because they contain "/", and can be confused with links with a hardcoded path.
# 2) The linux-gate library is a virtual dll that does not exist on disk, but is instead loaded automatically
#    into the process space, and can't be copied to the ramdisk
#
# After these lines have been stripped, we're interested in the lines remaining if they
# 1) Contain "=>" because they are pathless links, and the value following the token is the path on the disk
# 2) Contain "/" because it's a link with a hardcoded path, and so we're interested in the link itself.
LIBFILES=`ldd $BINFILES 2>/dev/null |grep -v -E \(linux-gate\|:\) | awk '{if (/=>/) { print $3 } else if (/\//) { print $1 }}' | sort -u`
if [ $? -ne 0 ]; then
   echo "$cmd -- ERROR figuring out needed shared libraries"
   exit 1
fi

verbose "Shared libraries needed: `echo $LIBFILES`"

INITRDFILES="$BINFILES $LIBFILES $MODULES $EXTRAFILES"

# tack on stuff for modules if we declared any and the files exist
if [ -n "$MODULES" ]; then
    if [ -f "/etc/modprobe.conf" ]; then
	INITRDFILES="$INITRDFILES /etc/modprobe.conf"
    fi
    if [ -f "/lib/modules/modprobe.conf" ]; then
	INITRDFILES="$INITRDFILES /lib/modules/modprobe.conf"
    fi
fi

# Calculate the the size of the ramdisk image.
# Don't forget that inodes take up space too, as does the filesystem metadata.
echo "$cmd -- calculating initrd filesystem parameters"
if [ -z "$INITRDSIZE" ]; then
   echo "$cmd -- calculating loopback file size"
   verbose "finding size"
   INITRDSIZE="`du -Lck $INITRDFILES | tail -1 | cut -f 1`"
   verbose "minimum: $INITRDSIZE kB for files + inodes + filesystem metadata"
   INITRDSIZE=`expr $INITRDSIZE + 512`  # enough for ext2 fs + a bit
fi

echo "$cmd -- making loopback file ($INITRDSIZE kB)"
verbose "using $DEVRAM as a temporary loopback file"
dd if=/dev/zero of=$DEVRAM count=$INITRDSIZE bs=1024 > /dev/null 2>&1
if [ $? -ne 0 ]; then
   echo "$cmd -- ERROR creating loopback file"
   cleanup 1
fi

echo "$cmd -- making ram disk filesystem"
verbose "mke2fs -F -m0 -L LVM-$VERSION $DEVRAM $INITRDSIZE"
[ "$VERBOSE" ] && OPT_Q="" || OPT_Q="-q"
mke2fs $OPT_Q -F -m0 -L LVM-$VERSION $DEVRAM $INITRDSIZE
if [ $? -ne 0 ]; then
   echo "$cmd -- ERROR making ram disk filesystem"
   echo "$cmd -- ERROR you need to use mke2fs >= 1.14 or increase INITRDSIZE"
   cleanup 1
fi

verbose "creating mountpoint $TMPMNT"
mkdir $TMPMNT
if [ $? -ne 0 ]; then
   echo "$cmd -- ERROR making $TMPMNT"
   cleanup 1
fi

echo "$cmd -- mounting ram disk filesystem"
verbose "mount -o loop $DEVRAM $TMPMNT"
mount -oloop $DEVRAM $TMPMNT
if [ $? -ne 0 ]; then
   echo "$cmd -- ERROR mounting $DEVRAM on $TMPMNT"
   cleanup 1
fi

verbose "creating basic set of directories in $TMPMNT"
(cd $TMPMNT; mkdir bin dev etc lib proc sbin sys var)
if [ $? -ne 0 ]; then
   echo "$cmd -- ERROR creating directories in $TMPMNT"
   cleanup 1
fi

# Add some /dev files. We have to handle different types of MAKEDEV invocations
# here, so this is rather messy.
RETCODE=0
echo "$cmd -- adding required /dev files"
verbose "BASICDEVICES: `echo $BASICDEVICES`"
verbose "BLOCKDEVICES: `echo $BLOCKDEVICES`"
[ "$VERBOSE" ] && OPT_Q="-v" || OPT_Q=""
case "$MAKEDEV" in 
debian)
    (cd $TMPMNT/dev; /dev/MAKEDEV $OPT_Q $BASICDEVICES $BLOCKDEVICES)
    RETCODE=$?
    ;;
redhat)
    (cd $TMPMNT/dev; /dev/MAKEDEV $OPT_Q -d $TMPMNT/dev -m 2)
    RETCODE=$?
    ;;
gentoo)
    (cd $TMPMNT/dev; /sbin/MAKEDEV $OPT_Q $BASICDEVICES $BLOCKDEVICES)
    RETCODE=$?
    ;;
*)
    echo "$cmd -- ERROR: $MAKEDEV is not a known MAKEDEV style."
    RETCODE=1
    ;;
esac


if [ $RETCODE -ne 0 ]; then
   echo "$cmd -- ERROR adding /dev files"
   cleanup 1
fi


# copy necessary files to ram disk
echo "$cmd -- copying initrd files to ram disk"
[ "$VERBOSE" ] && OPT_Q="-v" || OPT_Q="--quiet"
verbose "find \$INITRDFILES | cpio -pdmL $OPT_Q $TMPMNT"
find $INITRDFILES | cpio -pdmL $OPT_Q $TMPMNT
if [ $? -ne 0 ]; then
   echo "$cmd -- ERROR cpio to ram disk"
   cleanup 1
fi


echo "$cmd -- creating symlinks to busybox"
shopt -s extglob
[ "$VERBOSE" ] && OPT_Q="-v" || OPT_Q=""
BUSYBOXSYMLINKS=`busybox 2>&1| awk '/^Currently defined functions:$/ {i++;next} i'|tr ',\t\n' ' '`
for link in ${BUSYBOXSYMLINKS//@(linuxrc|init|busybox)}; do 
	ln -s $OPT_Q busybox $TMPMNT/bin/$link;
done
shopt -u extglob

echo "$cmd -- creating new $TMPMNT/sbin/init"
create_init
if [ $? -ne 0 ]; then
   echo "$cmd -- ERROR creating init"
   cleanup
   exit 1
fi

if [ -n "$RAID" ]; then
    RAIDLIST="$TMPMNT/etc/raid_autostart"
    echo "$cmd -- creating $RAIDLIST file."
    for device in $RAID; do
        echo $device >> $RAIDLIST
    done
fi

# create modules.dep and /etc/modules files if needed
if [ -n "$MODULES" ]; then
    echo "$cmd -- creating $MODDIR/modules.dep file and $TMPMNT/etc/modules"
    depmod -b $TMPMNT $VERSION
    for module in $MODULES; do
        basename $module | sed 's/\.k\{0,1\}o$//' >> $TMPMNT/etc/modules
    done
fi

verbose "removing $TMPMNT/lost+found"
rmdir $TMPMNT/lost+found

echo "$cmd -- ummounting ram disk"
umount $TMPMNT
if [ $? -ne 0 ]; then
   echo "$cmd -- ERROR umounting $TMPMNT"
   cleanup 1
fi

echo "$cmd -- creating compressed initrd $INITRD"
verbose "dd if=$DEVRAM bs=1k count=$INITRDSIZE | gzip -9"
dd if=$DEVRAM bs=1k count=$INITRDSIZE 2>/dev/null | gzip -9 > $INITRD
if [ $? -ne 0 ]; then
   echo "$cmd -- ERROR creating $INITRD"
   cleanup 1
fi


cat << FINALTXT
--------------------------------------------------------
Your initrd is ready in $INITRD

Don't forget to set root=/dev/ram0 in kernel parameters
Don't forget to set realroot=/dev/sdXX in kernel parameters, where sdXX is your root device
Don't forget to set subvol=root in kernel parameters, where root is your subvolume
If you use lilo try adding/modifying an entry similar to this one in lilo.conf:

image=/boot/vmlinuz-btrfs-$VERSION
        label="ramdisk_LVM"
        initrd=/boot/initrd-btrfs-$VERSION.gz
        append="root=/dev/ram0 realroot=/dev/sda2 subvol=root <other parameters>"

If using grub try adding/modifying an entry similar to this one in menu.lst

title ramdisk LVM
        kernel /boot/vmlinuz-btrfs-$VERSION root=/dev/ram0 realroot=/dev/sda2 subvol=root <other parameters>
        initrd /boot/initrd-btrfs-$VERSION.gz

--------------------------------------------------------
FINALTXT

cleanup 0
