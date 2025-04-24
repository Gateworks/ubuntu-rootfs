#!/bin/bash
#
# requires debootstrap qemu-user-static binfmt-support coreutils u-boot-tools mtd-utils
#          sfdisk bzip2
#
set -e

WGET="wget --no-check-certificate"

function gateworks_config {
	# add watchdog conf
	cat <<\EOF > /etc/watchdog.conf
watchdog-device = /dev/watchdog
realtime = yes
priority = 1
interval = 5
watchdog-timeout = 30
EOF
}

function ventana_config {
	gateworks_config

	# add systemd system-shutdown hook to use the GSC to power-down
	cat <<\EOF > /lib/systemd/system-shutdown/gsc-poweroff
#!/bin/bash

# use GSC to power cycle the system
echo 2 > /sys/bus/i2c/devices/0-0020/powerdown
EOF
	chmod +x /lib/systemd/system-shutdown/gsc-poweroff

	# blacklist SVNC RTC driver (we don't use it)
	echo "blacklist rtc_snvs" > /etc/modprobe.d/blacklist-rtc.conf

	# use MSI interrupts for ath9k
	# (not needed if 'pci=nomsi' in cmdline which our bootscript does)
	echo "options ath9k use_msi=1" > /etc/modprobe.d/ath9k.conf

	# initramfs config
	[ -d /etc/initramfs-tools/ ] && {
	cat <<EOF >> /etc/initramfs-tools/modules
# for NAND/ubi
gpmi_nand
ubi mtd=2
ubifs

# for usb-storage
ci_hdrc_imx
usb-storage

EOF
	}

	# Add IMX specific firmware
	FSL_MIRROR=http://www.freescale.com/lgfiles/NMG/MAD/YOCTO
	FSL_FIRMWARE=8.1.1
	# (see https://github.com/Freescale/meta-freescale/tree/master/recipes-bsp/firmware-imx for latest version)
	(cd tmp; \
	$WGET ${FSL_MIRROR}/firmware-imx-${FSL_FIRMWARE}.bin; \
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
	mkdir -p /usr/local/bin
	$WGET https://raw.githubusercontent.com/Gateworks/media-ctl-setup/master/media-ctl-setup \
		-O /usr/local/bin/media-ctl-setup
	chmod +x /usr/local/bin/media-ctl-setup

	# Sterling LWB firmware (BRCM43430)
	mkdir -p /usr/lib/firmware/updates/brcm
	$WGET https://github.com/LairdCP/Sterling-LWB-and-LWB5-Release-Packages/releases/download/LRD-REL-10.4.0.10/laird-lwb5plus-sdio-sa-firmware-10.4.0.10.tar.bz2 \
		-O /tmp/firmware.tar.bz2
	tar --strip-components=2 -C /usr/lib/firmware/updates -xf /tmp/firmware.tar.bz2 lib/firmware/brcm --keep-directory-symlink
	rm /tmp/firmware.tar.bz2

	# U-Boot env tools config
	cat << EOF > /etc/fw_env.config
# device  offset size erasesize
/dev/mtd1 0x0 0x20000 0x40000
/dev/mtd1 0x80000 0x20000 0x40000
EOF
}

function newport_config {
	gateworks_config

	# add systemd system-shutdown hook to use the GSC to power-down
	cat <<\EOF > /lib/systemd/system-shutdown/gsc-poweroff
#!/bin/bash

# use GSC to power cycle the system
echo 2 > /sys/bus/i2c/devices/0-0020/powerdown
EOF
	chmod +x /lib/systemd/system-shutdown/gsc-poweroff

	# U-Boot env tools config
	cat << EOF > /etc/fw_env.config
# Device               offset          Env. size
/dev/mmcblk0           0xff0000        0x8000
/dev/mmcblk0           0xff8000        0x8000
EOF
}

function venice_config {
	gateworks_config

	# network device naming service
	cat << EOF > /lib/systemd/system/netdev-naming.service
[Unit]
Description=Network Device Naming

Before=network-pre.target
Wants=network-pre.target

DefaultDependencies=no
Requires=local-fs.target
After=local-fs.target

[Service]
Type=oneshot

ExecStart=/usr/local/sbin/netdevname

RemainAfterExit=yes

[Install]
WantedBy=network.target
EOF
	cat <<\EOF > /usr/local/sbin/netdevname
#!/bin/bash

MODEL=$(cat /proc/device-tree/board | tr '\0' '\n')
case "$MODEL" in
	GW740*)
		echo "$0: Adjusting network names for $MODEL"
		eth0=platform/soc@0/30800000.bus/30bf0000.ethernet
		eth1=platform/soc@0/30800000.bus/30be0000.ethernet
		devs="eth0 eth1"
		;;
esac

[ "$devs" ] || exit 0

# renumber eth devs to above max eth dev
max_eth=$(grep -o '^ *eth[0-9]*:' /proc/net/dev | tr -dc '[0-9]\n' | sort -n | tail -1)
for i in $(seq 0 $max_eth); do
	ip link set "eth$i" down
	ip link set "eth$i" name "eth$((++max_eth))"
done

# renumber eth devs based on the path we defined above
for i in $devs; do
	eval path='$'$i
	devname="$(ls /sys/devices/$path/net | head -1)"
	echo "$0: $i:$path"
	ip link set "$devname" down
	ip link set "$devname" name $i
done
EOF
	chmod +x /usr/local/sbin/netdevname
	systemctl enable netdev-naming.service

	# blacklist SVNC RTC driver (we don't use it)
	echo "blacklist rtc_snvs" > /etc/modprobe.d/blacklist-rtc.conf

	# Sterling LWB firmware (BRCM43430)
	mkdir -p /usr/lib/firmware/updates/brcm
	$WGET https://github.com/LairdCP/Sterling-LWB-and-LWB5-Release-Packages/releases/download/LRD-REL-10.4.0.10/laird-lwb5plus-sdio-sa-firmware-10.4.0.10.tar.bz2 \
		-O /tmp/firmware.tar.bz2
	tar --strip-components=2 -C /usr/lib/firmware/updates -xf /tmp/firmware.tar.bz2 lib/firmware/brcm --keep-directory-symlink
	rm /tmp/firmware.tar.bz2

	# Sterling LWB5+ firmware (CYW4373)
	mkdir -p /usr/lib/firmware/updates/brcm
	$WGET https://github.com/LairdCP/Sterling-LWB-and-LWB5-Release-Packages/releases/download/LRD-REL-11.171.0.24/laird-lwb5plus-sdio-sa-firmware-11.171.0.24.tar.bz2 \
		-O /tmp/firmware.tar.bz2
	tar --strip-components=2 -C /usr/lib/firmware/updates -xf /tmp/firmware.tar.bz2 lib/firmware/brcm --keep-directory-symlink
	rm /tmp/firmware.tar.bz2

	# muRATA LBEE5HY1MW (BRCM43455)
	mkdir -p /usr/lib/firmware/updates/brcm
	$WGET https://github.com/murata-wireless/cyw-fmac-nvram/raw/refs/heads/master/cyfmac43455-sdio.1MW.txt \
		-O /usr/lib/firmware/updates/brcm/brcmfmac43455-sdio.txt
	$WGET https://github.com/Infineon/ifx-linux-firmware/raw/refs/tags/release-v6.1.97-2024_1115/firmware/cyfmac43455-sdio.bin \
		-O /usr/lib/firmware/updates/brcm/brcmfmac43455-sdio.bin
	$WGET https://github.com/murata-wireless/cyw-fmac-fw/raw/master/cyfmac43455-sdio.1MW.clm_blob \
		-O /usr/lib/firmware/updates/brcm/brcmfmac43455-sdio.clm_blob

	# U-Boot env tools config
	cat << EOF > /etc/fw_env.config
# Device               offset          Env. size
/dev/mmcblk2boot0      0x3f0000        0x8000
/dev/mmcblk2boot0      0x3f8000        0x8000
EOF
}

function malibu_config {
	gateworks_config

	# U-Boot env tools config
	cat << EOF > /etc/fw_env.config
# Device               offset          Env. size
/dev/mmcblk0boot0      0x3f0000        0x8000
/dev/mmcblk0boot0      0x3f8000        0x8000
EOF
}

# second stage setup function
# all commands in this function gets executed after chroot
function second_stage {
	set -e
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
	# Prioritize Gateworks ppa packages in all cases
	cat <<\EOF > /etc/apt/preferences.d/gateworks
Package: *
pin: release o=LP-PPA-gateworks-software-packages
Pin-Priority: 1010

EOF

	# updated modemmanager/libqmi/libmbim
	case "$distro" in
		focal|bionic|xenial|trusty)
			add-apt-repository -y ppa:aleksander-m/modemmanager-$distro
			apt update
			apt upgrade -y
			;;
	esac

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
	apt install -y wpasupplicant iw hostapd
	apt install -y modemmanager libqmi-utils libmbim-utils policykit-1
	apt install -y bluez brcm-patchram

	# Gateworks
	apt install -y gsc-update gwsoc hostapd-conf openocd

	# misc
	apt install -y can-utils i2c-tools usbutils pciutils
	apt install -y u-boot-tools
	apt install -y screen picocom # terminal programs
	apt install -y vim nano # file editors
	apt install -y ethtool iperf iperf3 iputils-ping bridge-utils # net
	apt install -y dialog less evtest
	apt install -y bsdmainutils # hexdump
	apt install -y openssh-server
	apt install -y wget
	apt install -y gpiod
	apt install -y ftdi-eeprom
	apt install -y bzip2
	apt install -y psmisc

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
	# get rid of some of the firmware bloat that will never be used on our platforms
	rm -rf /lib/firmware/marvell/prestera
	rm -rf /lib/firmware/netronome
	rm -rf /lib/firmware/mellanox
	rm -rf /lib/firmware/amdgpu
	rm -rf /lib/firmware/nvidia
	rm -rf /lib/firmware/i915

	# mmc utils for setting partconf
	apt install -y mmc-utils
	# requested by users
	apt install -y iptables binutils

	# watchdog
	apt install -y watchdog

	# configure isc-dhcp-client for 30 sec timeout
	# (so you don't have to wait the default 5 mins on no network)
	[ -r /etc/dhcp/dhclient.conf ] && {
		sed -i 's/^timeout.*/timeout 30;/' /etc/dhcp/dhclient.conf
	}

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

	# Auto-resize partition and filesystem one-shot script on first boot
	apt install -y e2fsprogs parted
	cat <<\EOF > /etc/init.d/growpart_once
#!/bin/sh
### BEGIN INIT INFO
# Provides:          growpart_once
# Required-Start:
# Required-Stop:
# Default-Start: 2 3 4 5 S
# Default-Stop:
# Short-Description: Resize the last partition/filesystem to fill device
# Description:
### END INIT INFO

. /lib/lsb/init-functions

case "$1" in
  start)
    log_daemon_msg "Starting growpart_once"
    # get root device from mounts
    ROOT=$(mount | sed -n 's|^/dev/\(.*\) on / .*|\1|p')
    if [ -n "$ROOT" ]; then
       # get the device of the partition
       DEV=$(lsblk -no pkname /dev/$ROOT)
       # get the fstype of the partition
       FSTYPE=$(lsblk -no fstype /dev/$ROOT)
       # get last part number (this is the one we can grow to end of device)
       LAST_PART_NUM=$(parted /dev/$DEV -ms unit s p | tail -n 1 | cut -f 1 -d:)
       # resize the partition
       parted /dev/$DEV "resizepart $LAST_PART_NUM -0"
       # resize the filesystem to fit the new partition size
       resize2fs /dev/$ROOT
    fi
    update-rc.d growpart_once remove &&
    rm /etc/init.d/growpart_once &&
    log_end_msg $?
    ;;
  *)
    echo "Usage: $0 start" >&2
    exit 3
    ;;
esac

EOF
	chmod +x /etc/init.d/growpart_once
	systemctl enable growpart_once

	# Add autoloading of cryptodev, algo and PHY modules
	cat <<EOF > /etc/modules
cryptodev
af_alg
algif_hash
algif_skcipher
algif_rng
algif_aead
ledtrig_heartbeat
dp83867
EOF

	# Add Gateworks version info to /etc/issue
	echo "Gateworks-Ubuntu-$revision $(date -u)" >> /etc/issue

	# Add a terminal resize script
	mkdir -p /usr/local/bin
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
	find /var/log -type f \
		\( -name "*.gz" -o -name "*.xz" -o -name "*.log" \) -delete
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

	# determine minimum size needed if not provided
	[ -z "$SIZE_MB" ] && SIZE_MB=$(( $(du --total --block-size=1  $rootfs | tail -1 | cut -f1) / 1024 / 1024 * 11 / 10))
	echo "creating ${SIZE_MB}MiB compressed disk image..."

	# create fs image
	rm -f $name.$fstype
	truncate -s ${SIZE_MB}M $name.$fstype
	case "$fstype" in
		ext4)
			# remove metadata checksums for newer e2fsprogs
			# to allow U-Boot to write to ext4
			if grep -q "metadata_csum" /etc/mke2fs.conf; then
				mkfs.$fstype -q -F -O ^metadata_csum -L $volname $name.$fstype
			else
				mkfs.$fstype -q -F -L $volname $name.$fstype
			fi
			;;
		f2fs)
			mkfs.$fstype -q -l $volname $name.$fstype
			;;
	esac
	mount $name.$fstype ${TMP}
	cp -rup $rootfs/* ${TMP}
	[ $? -ne 0 ] && {
		echo "Error copying rootfs - ${SIZE_MB}MiB too small?"
		umount ${TMP}
		return
	}
	umount ${TMP}
	rm -rf ${TMP}

	xz -f $name.$fstype
}

function usage {
	cat <<EOF
usage: $0 <family> <distro>

	family: malibu venice newport ventana
	distro: noble jammy focal eoan bionic xenial trusty

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
	ventana)
		required mkfs.ubifs mtd-utils
		ARCH=armhf
		;;
	newport|venice|malibu)
		ARCH=arm64
		required mkimage u-boot-tools
		mkimage -h 2>&1 | grep auto >/dev/null || {
			echo "mkimage v2016.05 with support for '-f auto' required"
			exit 1
		}
		;;
	*) usage;;
esac
case "$DIST" in
	noble|jammy|focal|eoan|bionic|xenial|trusty);;
	*) usage;;
esac

# check prerequisites
required debootstrap
required qemu-arm-static qemu-user-static
required chroot coreutils
required tar
required sfdisk fdisk
required bzip2
required xz xz-utils

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
export -f gateworks_config
export -f ventana_config
export -f newport_config
export -f venice_config
export -f malibu_config
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
# misc
export WGET=$WGET
# make sure apt is non-interactive
export DEBIAN_FRONTEND=noninteractive

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
	echo "Building disk/filesystem image..."
	blkdev_image $outdir ext4
}

exit 0
