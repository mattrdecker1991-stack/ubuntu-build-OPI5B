#!/bin/bash
set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

#set -x

cleanup_loopdev() {
    local loop="$1"

    sync --file-system
    sync

    sleep 1

    if [ -b "${loop}" ]; then
        for part in "${loop}"p*; do
            if mnt=$(findmnt -n -o target -S "$part"); then
                umount "${mnt}"
            fi
        done
        losetup -d "${loop}"
    fi
}

wait_loopdev() {
    local loop="$1"
    local seconds="$2"

    until test $((seconds--)) -eq 0 -o -b "${loop}"; do sleep 1; done

    ((++seconds))

    ls -l "${loop}" &> /dev/null
}

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

export  LC_ALL=C 
export  LC_CTYPE=C
export  LANGUAGE=C
export  LANG=C

if [ ! -f ./rootfs ]; then 
	exit 1 
fi

. ./rootfs
. ./kernel_version

rootfs="$(readlink -f "$rootfs")"
if [[ "$(basename "${rootfs}")" != *".rootfs.tar" || ! -e "${rootfs}" ]]; then
    echo "Error: $(basename "${rootfs}") must be a rootfs tarfile"
    exit 1
fi

mkdir -p images
now=`date +%F`
# Create an empty disk image
img="./Ubuntu-${kernel_version}-$2-$now.img"
size="$(( $(wc -c < "${rootfs}" ) / 1024 / 1024 ))"
truncate -s "$(( size + 512 ))M" "${img}"

# Create loop device for disk image
loop="$(losetup -f)"
losetup -P "${loop}" "${img}"
disk="${loop}"

# Cleanup loopdev on early exit
trap 'cleanup_loopdev ${loop}' EXIT

# Ensure disk is not mounted
mount_point=/tmp/mnt
umount "${disk}"* 2> /dev/null || true
umount ${mount_point}/* 2> /dev/null || true
mkdir -p ${mount_point}

    # Setup partition table with proper bootloader space
    # For RK3588S: bootloader @ offset 64 (32KB), u-boot.itb @ offset 16384 (8MB)
    # Keep 16MiB free for bootloader to avoid conflicts
    dd if=/dev/zero of="${disk}" count=4096 bs=512
    parted --script "${disk}" \
    mklabel gpt \
    mkpart ESP fat32 2MiB 16MiB \
    mkpart primary ext4 16MiB 100%

    # Set boot flag on partition 1
    {
        echo "t"
        echo "1"
        echo "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
        echo "t"
        echo "2"
        echo "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
        echo "w"
    } | fdisk "${disk}" &> /dev/null || true

    partprobe "${disk}"

    partition_char="$(if [[ ${disk: -1} == [0-9] ]]; then echo p; fi)"

    sleep 1

    wait_loopdev "${disk}${partition_char}1" 60 || {
        echo "Failure to create ${disk}${partition_char}1 in time"
        exit 1
    }

    wait_loopdev "${disk}${partition_char}2" 60 || {
        echo "Failure to create ${disk}${partition_char}2 in time"
        exit 1
    }

    sleep 1

    # Generate random uuid for rootfs
    root_uuid=$(uuidgen)
    boot_uuid=$(uuidgen)

    # Create filesystems on partitions
    dd if=/dev/zero of="${disk}${partition_char}1" bs=1KB count=10 > /dev/null
    mkfs.vfat -F 32 -n boot "${disk}${partition_char}1"
    
    dd if=/dev/zero of="${disk}${partition_char}2" bs=1KB count=10 > /dev/null
    mkfs.ext4 -U "${root_uuid}" -L desktop-rootfs "${disk}${partition_char}2"

    # Mount partitions
    mkdir -p ${mount_point}/boot
    mkdir -p ${mount_point}/writable
    mount "${disk}${partition_char}1" ${mount_point}/boot
    mount "${disk}${partition_char}2" ${mount_point}/writable

# Copy the rootfs to root partition
tar -xpf "${rootfs}" -C ${mount_point}/writable

fdt_name="rockchip/$3.dtb"
dtbs_install_path="/usr/lib/linux-image-"

if [ ! -f ${mount_point}/writable${dtbs_install_path}${kernel_version}/${fdt_name} ]; then
	echo "${dtbs_install_path}${kernel_version}/${fdt_name}"
	echo "$3.dtb not found"
	exit 1
fi

# Create fstab entries
echo "# <file system>     <mount point>  <type>  <options>   <dump>  <fsck>" > ${mount_point}/writable/etc/fstab
echo "UUID=${root_uuid,,} /              ext4    defaults,x-systemd.growfs    0       1" >> ${mount_point}/writable/etc/fstab
echo "UUID=${boot_uuid,,} /boot          vfat    defaults                     0       2" >> ${mount_point}/writable/etc/fstab

# Create boot directory structure
mkdir -p ${mount_point}/writable/boot/dtbs
mkdir -p ${mount_point}/writable/boot/extlinux

# Copy device tree to boot partition
cp ${mount_point}/writable${dtbs_install_path}${kernel_version}/${fdt_name} ${mount_point}/writable/boot/dtbs/

# Create extlinux.conf for proper bootloader configuration
cat > ${mount_point}/writable/boot/extlinux/extlinux.conf << 'EOF'
LABEL mainline
    MENU LABEL Mainline Linux
    LINUX /Image
    INITRD /initrd.img
    FDT /dtbs/rk3588s-orangepi-5b.dtb
    APPEND root=UUID=ROOT_UUID_PLACEHOLDER rw rootwait console=ttyS2,1500000 earlycon=uart8250,mmio32,0xfeb50000
EOF

# Replace UUID placeholder in extlinux.conf
sed -i "s/ROOT_UUID_PLACEHOLDER/${root_uuid,,}/g" ${mount_point}/writable/boot/extlinux/extlinux.conf

# Write bootloader to disk image at correct offsets for RK3588S
# idbloader @ offset 64 (512-byte blocks = 32KB)
# u-boot.itb @ offset 16384 (512-byte blocks = 8MB)
if [ -f "idbloader.img" ]; then
    echo "Writing idbloader.img at offset 64..."
    dd if="idbloader.img" of="${loop}" seek=64 bs=512 conv=fsync
else
    echo "Warning: idbloader.img not found, attempting with u-boot-rockchip.bin"
    if [ -f "u-boot-rockchip.bin" ]; then
        echo "Writing u-boot-rockchip.bin at offset 64 (RK3588S standard)..."
        dd if="u-boot-rockchip.bin" of="${loop}" seek=64 bs=512 conv=fsync
    else
        echo "Error: Neither idbloader.img nor u-boot-rockchip.bin found"
        exit 1
    fi
fi

if [ -f "u-boot.itb" ]; then
    echo "Writing u-boot.itb at offset 16384..."
    dd if="u-boot.itb" of="${loop}" seek=16384 bs=512 conv=fsync
fi

echo U_BOOT_FDT='"'"$fdt_name"'"' >> ${mount_point}/writable/etc/default/u-boot
echo U_BOOT_FDT_DIR='"'"$dtbs_install_path"'"' >> ${mount_point}/writable/etc/default/u-boot

echo "---------------Check the u-boot settings.----------------"
cat ${mount_point}/writable/etc/default/u-boot
echo "----------------------------------------------------------"

echo "---------------Check extlinux.conf settings.-------------"
cat ${mount_point}/writable/boot/extlinux/extlinux.conf
echo "----------------------------------------------------------"

mountpoint="${mount_point}/writable"

mount dev-live -t devtmpfs "$mountpoint/dev"
mount devpts-live -t devpts -o nodev,nosuid "$mountpoint/dev/pts"
mount proc-live -t proc "$mountpoint/proc"
mount sysfs-live -t sysfs "$mountpoint/sys"
mount securityfs -t securityfs "$mountpoint/sys/kernel/security"

# u-boot-update 
chroot ${mount_point}/writable/ /bin/bash -c "u-boot-update&&sync" || echo "Warning: u-boot-update failed or not available"

sync --file-system
sync

umount "$mountpoint/sys/kernel/security"
umount "$mountpoint/sys"
umount "$mountpoint/proc"
umount "$mountpoint/dev/pts"
umount "$mountpoint/dev"

# Umount boot partition
umount "${mount_point}/boot"

# Umount root partition
umount "$mountpoint"

# Remove loop device
losetup -d "${loop}"

# Exit trap is no longer needed
trap '' EXIT

echo -e "\nCompressing $(basename "${img}.xz")\n"
xz -v -9 -T0 "${img}"
#rm "${img}"
#cd ./images && sha256sum "$(basename "${img}.xz")" > "$(basename "${img}.xz.sha256")"
exit 0
