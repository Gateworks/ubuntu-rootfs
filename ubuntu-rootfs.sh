#!/bin/bash
#
# requires debootstrap qemu-user-status binfmt-support coreutils
#

function ventana_config {
	# watchdog config for GSC watchdog
	cat <<EOF > /etc/watchdog.conf
watchdog-device = /dev/watchdog
realtime = yes
priority = 1
interval = 5
watchdog-timeout = 30
EOF

	# use MSI interrupts for ath9k
	# (not needed if 'pci=nomsi' in cmdline which our bootscript does)
	echo "options ath9k use_msi=1" > /etc/modprobe.d/ath9k.conf

	# initramfs config
	cat <<EOF >> /etc/initramfs-tools/modules
# for NAND/ubi
gpmi_nand
ubi mtd=2
ubifs

# for usb-storage
ci_hdrc_imx
usb-storage

EOF

	# blacklist imx watchdog
	# (not needed for our kernel as we disable it, for other kernels
	#  they can reconfigure watchdog.conf if needed)
	#echo "blacklist rtc_snvs" > /etc/modprobe.d/blacklist-rtc.conf

	# Add IMX specific firmware
	FSL_MIRROR=http://www.freescale.com/lgfiles/NMG/MAD/YOCTO
	FSL_FIRMWARE=8.1.1
	# (see https://github.com/Freescale/meta-freescale/tree/master/recipes-bsp/firmware-imx for latest version)
	(cd tmp; \
	wget ${FSL_MIRROR}/firmware-imx-${FSL_FIRMWARE}.bin; \
	sh ./firmware-imx-${FSL_FIRMWARE}.bin --auto-accept --force; \
	)
	# VPU firmware
	mkdir -p /lib/firmware/vpu
	cp -rfv /tmp/firmware-imx-*/firmware/vpu/vpu_fw_imx6*.bin \
		/lib/firmware/vpu
	# SDMA firmware
	# (linux-firmware.git is up to date 2019-06-07)
	#mkdir -p /lib/firmware/imx/sdma
	#cp firmware-imx-*/firmware/sdma-imx6q.bin /lib/firmware/imx/sdma

	# media-ctl-setup script
	wget https://raw.githubusercontent.com/Gateworks/media-ctl-setup/master/media-ctl-setup \
		-O /usr/local/bin/media-ctl-setup
	chmod +x /usr/local/bin/media-ctl-setup

	# Sterling LWB firmware
	wget http://dev.gateworks.com/sources/480-0079.tar.bz2 \
		-O /tmp/480-0079.tar.bz2
	tar -C / -xvf /tmp/480-0079.tar.bz2
}

function newport_config {
	# CPT (crypto) firmware
	wget http://dev.gateworks.com/images/cpt8x-mc-ae.out \
		-O /lib/firmware/cpt8x-mc-ae.out
	wget http://dev.gateworks.com/images/cpt8x-mc-se.out \
		-O /lib/firmware/cpt8x-mc-se.out

	# add systemd system-shutdown hook to use the GSC to power-down
	cat <<\EOF > /lib/systemd/system-shutdown/gsc-poweroff
#!/bin/bash

# use GSC to power cycle the system
echo 2 > /sys/bus/i2c/devices/0-0020/powerdown
EOF
	chmod +x /lib/systemd/system-shutdown/gsc-poweroff
}

# second stage setup function
# all commands in this function gets executed after chroot
function second_stage {
	echo "Starting second stage"
	export LANG=C
	export FLASH_KERNEL_SKIP=1
	/debootstrap/debootstrap --second-stage

	# environment
	cat <<EOF > /etc/environment
FLASH_KERNEL_SKIP=1
EOF
	# Add package repos
	cat <<EOF > /etc/apt/sources.list
deb http://ports.ubuntu.com/ubuntu-ports $distro main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports ${distro}-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports ${distro}-security main restricted universe multiverse

EOF
	# Add package src repos
	cat <<EOF >> /etc/apt/sources.list
deb-src http://ports.ubuntu.com/ubuntu-ports $distro main restricted universe multiverse
deb-src http://ports.ubuntu.com/ubuntu-ports ${distro}-updates main restricted universe multiverse
deb-src http://ports.ubuntu.com/ubuntu-ports ${distro}-security main restricted universe multiverse

EOF

	# PPA's
	apt install -y software-properties-common # add-apt-repository
	# Gateworks packages
	add-apt-repository -y ppa:gateworks-software/packages
	# updated modemmanager/libqmi/libmbim
	add-apt-repository -y ppa:aleksander-m/modemmanager-$distro
	apt update
	apt upgrade -y

	# Set Hostname
	echo "${distro}-${family}" > /etc/hostname

	# default fstab
	cat <<EOF > /etc/fstab
# configure filesystems that are auto or manually mounted after kernel init
# note that the kernel will mount rootfs depending on various cmdline args
# such as root= rootwait and rw
/dev/root            /                    ext4       errors=remount-ro	0  1
tmpfs	/tmp	tmpfs	rw,nodev,nosuid	0	0
EOF

	# root password
	[ -n "$root_passwd" ] && {
		echo "Setting root passwd"
		echo "root:$root_passwd" | chpasswd
	}

	# Additional user
	[ -n "$user" -a -n "$user_passwd" ] && {
		adduser --disabled-password --gecos "" $user
		echo "$user:$user_passwd" | chpasswd
	}

	# Networking (we like ifupdown vs netplan)
	apt install -y net-tools ifupdown
	echo "Configuring network via ifupdown ($network_if/$network_ip)..."
	if [ "$network_ip" = "dhcp" ]; then
		echo "Configuring dhcp network"
		cat <<EOF >> /etc/network/interfaces
allow-hotplug $network_if
auto $network_if
iface $network_if inet dhcp
EOF
	elif [ -n "$network_ip" -a -n "$network_gateway" -a -n "$network_nameservers" ]; then
		echo "Configuring static network"
		cat <<EOF >> /etc/network/interfaces
allow-hotplug $network_if
auto $network_if
iface $network_if inet static
address $network_ip
gateway $network_gateway
EOF
		cat <<EOF >> /etc/resolv.conf
nameserver $network_nameserver
EOF
	fi

	# Wireless
	apt install -y wpasupplicant hostapd iw
	apt install -y modemmanager libqmi-utils libmbim-utils policykit-1
	apt install -y bluez brcm-patchram

	# Gateworks
	apt install -y gsc-update gwsoc hostapd-conf openocd

	# misc
	apt install -y can-utils i2c-tools usbutils pciutils
	apt install -y u-boot-tools
	apt install -y screen picocom # terminal programs
	apt install -y vim pico # file editors
	apt install -y ethtool iperf iperf3 iputils-ping bridge-utils # net
	apt install -y dialog less evtest
	apt install -y bsdmainutils # hexdump
	apt install -y openssh-server
	apt install -y wget
	apt install -y gpiod
	apt install -y ftdi-eeprom

	# distro specific packages
	case "$distro" in
		xenial)
			;;
		*)
			apt install -y chrony
			;;
	esac

	# firmware
	apt install -y linux-firmware
	# use updated QCA9984 board-2.bin file from linux.git for ath10k radios
	# (updates the one provided by Ubuntu linux-firmware package)
	# still needed as of 20191219
	# NOTE - next upgrade of linux-firmware will undo it
	cp /lib/firmware/ath10k/QCA9984/hw1.0/board-2.bin \
		/lib/firmware/ath10k/QCA9984/hw1.0/board-2.bin.orig
	wget https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/ath10k/QCA9984/hw1.0/board-2.bin -O \
		/lib/firmware/ath10k/QCA9984/hw1.0/board-2.bin

	# mmc utils for setting partconf
	apt install -y mmc-utils
	# requested by users
	apt install -y iptables binutils

	# watchdog
	apt install -y watchdog

	# configure dhcp client for 30 sec timeout
	# (so you don't have to wait the default 5 mins on no network)
	sed -i 's/^timeout.*/timeout 30;/' /etc/dhcp/dhclient.conf

	# mask wpa_supplicant
	# (our instructions config it via /etc/network/interfaces per interface)
	# mask creates symlink between service and /dev/null which
	# prevents any other service from launching this one
	systemctl mask wpa_supplicant

	# filesystems
	#apt install -y f2fs-tools btrfs-tools

	# disable persistent network interfaces
	#rm /lib/systemd/network/99-default.link
	# kernel specific stuff such as module blacklist, initrd and bootscript (ie ventana)

	# family specific stuff
	${family}_config

	# Install additional packages
	[ -n "$packages" ] && {
		echo "Installing additional packages: $packages"
		apt install -y $packages
	}

	# Add a default rc.local if one not present
	[ -r /etc/rc.local ] || {
		cat <<\EOF > /etc/rc.local
#!/bin/sh -e
#
# rc.local
#
# This script is executed at the end of each multiuser runlevel.
# Make sure that the script will "exit 0" on success or any other
# value on error.
#
# In order to enable or disable this script just change the execution
# bits.
#
# By default this script does nothing.

exit 0
EOF
		chmod +x /etc/rc.local
	}

	# Auto-resize filesystem one-shot script on first boot
	apt install -y e2fsprogs
	cat <<\EOF > /etc/init.d/resize2fs_once
#!/bin/sh
### BEGIN INIT INFO
# Provides:          resize2fs_once
# Required-Start:
# Required-Stop:
# Default-Start: 2 3 4 5 S
# Default-Stop:
# Short-Description: Resize the root filesystem to fill partition
# Description:
### END INIT INFO

. /lib/lsb/init-functions

ROOT=$(cat /proc/cmdline | sed -e 's/^.*root=//' -e 's/ .*$//')

case "$1" in
  start)
    log_daemon_msg "Starting resize2fs_once" &&
    resize2fs $ROOT &&
    update-rc.d resize2fs_once remove &&
    rm /etc/init.d/resize2fs_once &&
    log_end_msg $?
    ;;
  *)
    echo "Usage: $0 start" >&2
    exit 3
    ;;
esac

EOF
	chmod +x /etc/init.d/resize2fs_once
	systemctl enable resize2fs_once

	# Add autoloading of cryptodev and algo modules
	cat <<EOF > /etc/modules
cryptodev
af_alg
algif_hash
algif_skcipher
algif_rng
algif_aead
EOF

	# DHCP timeout
	sed -i 's/^timeout.*/timeout 30;/' /etc/dhcp/dhclient.conf

	# Add Gateworks version info to /etc/issue
	echo "Gateworks-Ubuntu-$revision $(date -u)" >> /etc/issue

	# Add a terminal resize script
	cat <<\EOF > /usr/local/bin/resize
#!/bin/sh

old=$(stty -g)
stty raw -echo min 0 time 5
printf '\0337\033[r\033[999;999H\033[6n\0338' > /dev/tty
IFS='[;R' read -r _ rows cols _ < /dev/tty
stty "$old"
stty cols "$cols" rows "$rows"
echo "size:${cols}x${rows}"
EOF
	chmod +x /usr/local/bin/resize
	cat <<\EOF >> /etc/profile

# resize tty
if command -v resize >/dev/null && command -v tty >/dev/null; then
        # Make sure we are on a serial console (i.e. the device used starts with
        # /dev/tty[A-z]), otherwise we confuse e.g. the eclipse launcher which
        # tries do use ssh
        case $(tty) in
                /dev/tty[A-z]*) resize >/dev/null;;
        esac
fi
EOF

	# cleanup
	apt autoremove -y
	apt-get clean
	rm -rf /tmp/{*,.*} # /tmp
	find /var/log -type f \
		\( -name "*.gz" -o -name "*.xz" -o -name "*.log" \) -delete
}

# extract kernel and bootscript
# $1=output-dir
function ventana_kernel {
	local outdir=$1
	local TMP=$(mktemp)
	local URL=http://dev.gateworks.com/ventana/images
	local KERNEL=gateworks-linux-4.20.tar.xz

	# kernel
	wget -q -c -N $URL/$KERNEL -O $TMP
	tar -C $outdir -xf $TMP
	rm $TMP
}

# extract kernel and bootscript
# $1=output-dir
function newport_kernel {
	local outdir=$1
	local TMP=$(mktemp)
	local URL=http://dev.gateworks.com/newport/kernel
	local KERNEL=linux-newport.tar.xz

	# kernel
	wget -q -c -N $URL/$KERNEL -O $TMP
	tar -C $outdir -xf $TMP
	rm $TMP

	# create kernel.itb with compressed kernel image
	TMP=$(mktemp -d)
	mv $outdir/boot/Image $TMP/vmlinux
	(cd $TMP/; \
	gzip vmlinux;
	wget https://raw.githubusercontent.com/Gateworks/bsp-newport/sdk-10.1.1.0-newport/mkits.sh; \
	chmod +x mkits.sh; \
	./mkits.sh -o kernel.its -k vmlinux.gz -C gzip -v "Ubuntu"; \
	mkimage -f kernel.its kernel.itb; \
	)
	# create bootscript
	(cd $TMP/; \
	wget https://raw.githubusercontent.com/Gateworks/bsp-newport/sdk-10.1.1.0-newport/ubuntu.scr; \
	mkimage -A arm64 -T script -C none -d ubuntu.scr newport.scr
	)
	cp $TMP/kernel.itb $outdir/boot/
	cp $TMP/newport.scr $outdir/boot/
	rm -rf $TMP
}

# create NAND UBI image of rootfs+kernel
# $1=rootfsdir
# $2=large|normal
#
# creates ${name}_${geometry}.ubifs and ${name}_${geometry}.ubi
function mkubi {
	local rootfs=$1
	local geometry=$2
	local TMP=$(mktemp)

	case "$geometry" in
		large)
			DESC="4k page, 256k erase-block"
			UBIFS_ARGS="-m 4096 -e 248KiB -c 8124"
			UBINIZE_ARGS="-m 4096 -p 256KiB"
			;;

		normal)
			DESC="2k page, 128k erase-block"
			UBIFS_ARGS="-m 2048 -e 124KiB -c 16248"
			UBINIZE_ARGS="-m 2048 -p 128KiB"
			;;
	esac
	echo "creating ubi for $geometry FLASH geometry: $DESC"

	# create NAND ubi image for
	mkfs.ubifs -F $UBIFS_ARGS -x zlib -o ${name}_${geometry}.ubifs -d $rootfs
	cat <<EOF > $TMP
[rootfs]
# Volume mode (other option is static)
mode=ubi
# Source image
image=${name}_${geometry}.ubifs
# Volume ID in UBI image
vol_id=0
# Allow for dynamic resize
vol_type=dynamic
# Volume name
vol_name=rootfs
vol_flags=autoresize
EOF
	ubinize $UBINIZE_ARGS -o ${name}_${geometry}.ubi $TMP
	rm $TMP
	# create symlink of generic name for ssh push
	#ln -sf ${name}_${geometry}.ubi bionic-ventana_${geometry}.ubi
}

# create blkdev disk image containing boot firmware + rootfs partition
# $1 rootfsdir
# $2 fstype: ext4|f2fs
# $3 size_mib
# $4 volname (defaults to 'rootfs' if not provided)
#
# creates $name.$fstype and $name.img.gz
function blkdev_image {
	local rootfs=$1
	local fstype=$2
	local SIZE_MB=$3
	local volname=${4:-rootfs}
	local TMP=$(mktemp -d)
	local PARTOFFSET_MB=
	local SIZEPART_MB=

	case "$family" in
		ventana)
			PARTOFFSET_MB=1 # offset for first partition
			;;
		newport)
			PARTOFFSET_MB=16 # offset for first partition
			;;
	esac

	SIZEPART_MB=$(($SIZE_MB-$PARTOFFSET_MB))
	echo "creating ${SIZE_MB}MiB compressed disk image..."

	# create ext4 fs image
	rm -f $name.$fstype
	truncate -s ${SIZEPART_MB}M $name.$fstype
	mkfs.$fstype -q -F -L $volname $name.$fstype
	mount $name.$fstype ${TMP}
	cp -rup $rootfs/* ${TMP}
	umount ${TMP}

	# create disk image
	rm -f $name.img
	truncate -s ${SIZE_MB}M $name.img

	# boot firmware
	case "$family" in
		ventana)
			SPL_OFFSET_KB=1
			UBOOT_OFFSET_KB=69
			ENV_OFFSET_KB=709
			# create MBR partition table
			printf "$((PARTOFFSET_MB*2*1024)),,L,*" | sfdisk -uS $name.img
			# fetch boot firmware
			(cd $TMP; \
			wget -q -c -N http://dev.gateworks.com/ventana/images/SPL; \
			wget -q -c -N http://dev.gateworks.com/ventana/images/u-boot.img; \
			)
			dd if=$TMP/SPL of=$name.img bs=1K seek=${SPL_OFFSET_KB} oflag=sync status=none
			dd if=$TMP/u-boot.img of=$name.img bs=1K seek=${UBOOT_OFFSET_KB} oflag=sync status=none
			#dd if=$TMP/env of=$name.img bs=1K seek=${ENV_OFFSET_KB} oflag=sync status=none
			;;
		newport)
			# fetch boot firmware
			(cd $TMP; wget -q -c -N http://dev.gateworks.com/newport/boot_firmware/firmware-newport.img)
			dd if=$TMP/firmware-newport.img of=$name.img bs=1M oflag=sync status=none
			;;
	esac

	dd if=$name.$fstype of=$name.img bs=1K seek=$((PARTOFFSET_MB*1024))

	rm -rf ${TMP}

	gzip -f $name.$fstype
	gzip -f $name.img

	# create symlink of generic name
	#ln -sf $name.img.gz $distro-$family.img.gz
}

function usage {
	cat <<EOF
usage: $0 <family> <distro>

	family: newport ventana
	distro: eoan bionic xenial trusty

EOF

	exit 1
}

function required {
	local cmd=$1
	local pkg=$2

	if ! [ -x "$(command -v $cmd)" ]; then
		if [ "$pkg" ]; then
			echo "Error: $cmd required (package $pkg)"
		else
			echo "Error: $cmd required"
		fi
		exit 1
	fi
}

###### Main Script ######

FAMILY=$1
DIST=$2
# default ENV
[ -z "$NETWORK_IP" ] && NETWORK_IP=dhcp
[ -z "$ROOT_PASSWD" ] && ROOT_PASSWD=root
#[ -z "$USER" ] || USER=gateworks
#[ -z "$USER_PASSWD" ] || USER=gateworks

# check CMDLINE env
case "$FAMILY" in
	ventana) ARCH=armhf;;
	newport) ARCH=arm64;;
	*) usage;;
esac
case "$DIST" in
	eoan|bionic|xenial|trusty);;
	*) usage;;
esac

# check prerequisites
required debootstrap
required qemu-arm-static qemu-user-static
required chroot coreutils
required tar

#name=${DIST}-${ARCH}
name=${DIST}-${FAMILY}
outdir=$name
echo "Creating ${outdir}..."

# first stage
debootstrap --arch=$ARCH --foreign $DIST $outdir

# install qemu to rootfs
case "$ARCH" in
	armhf)
		cp /usr/bin/qemu-arm-static $outdir/usr/bin
		;;
	arm64)
		cp /usr/bin/qemu-aarch64-static $outdir/usr/bin
		;;
esac

#
# export functions and vars to make accessible to chroot env
#
export -f second_stage
export -f ventana_config
export -f newport_config
export family=$FAMILY
export distro=$DIST
export arch=$ARCH
export root_passwd=$ROOT_PASSWD
export revision=gateworks-g$(git describe --always --dirty)
# additional user
export user=$USER
export user_passwd=$USER_PASSWD
# network config
export network_if=eth0
export network_ip=$NETWORK_IP
export network_gateway=$NETWORK_GATEWAY
export network_nameservers=$NETWORK_NAMESERVERS
# additional packages
export packages=$PACKAGES

# second stage
chroot $outdir /bin/bash -c "second_stage"

# cleanup
rm $outdir/usr/bin/qemu-*-static # remove qemu

# create package manifest (name/ver) and package list (name)
echo "Creating package manifests"
dpkg -l --root=$outdir | grep ^ii | awk '{print $2 "\t" $3}' | sed s/:$ARCH// > ${name}.manifest; \
awk '{ print $1 }' ${name}.manifest > ${name}.packages

# build tarball
[ -n "$SKIP_TAR" ] || {
	echo "Building rootfs tarball ${outdir}.tar.xz ..."
	tar --numeric-owner -cJf ${outdir}.tar.xz -C $outdir .
}

# build disk images
[ -n "$SKIP_IMAGE" ] || {
	echo "Building disk/filesystem images ..."

	# add kernel
	${family}_kernel $outdir

	# disk image and ext4 fs
	blkdev_image $outdir ext4 1536

	# ubi filesystems
	[ "$family" = "ventana" ] && {
		mkubi $outdir normal
		mkubi $outdir large
	}
}
