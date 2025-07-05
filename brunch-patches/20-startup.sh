# This patch replaces the chromeos_startup binary with a script custom script.
ret=0
cat >/roota/sbin/chromeos_startup <<STARTUP
#!/bin/bash
#
# Custom chromeos_startup script for Brunch/FydeOS
#
# This script is responsible for setting up the basic mount points and filesystems
# required for the rest of the OS services to start. It runs before user sessions.
#

# Helper functions
mount_or_fail()
{
    echo "mount_or_fail: mount \$@"
    if ! mount "\$@"; then
        echo "FATAL: Failed to mount. Rebooting."
        reboot -f
    fi
}
mount_with_log()
{
    echo "mount_with_log: mount \$@"
    mount "\$@"
}

# Redirect all output to a log file for debugging
exec 1>>/root/brunch_startup_log
exec 2>>/root/brunch_startup_log
echo "--- Brunch/FydeOS custom startup script started at \$(date) ---"

# --- 1. Mount Kernel Virtual Filesystems ---
echo "Mounting kernel virtual filesystems..."
mount_with_log -t debugfs -o rw,nosuid,nodev,noexec,relatime,seclabel,mode=0750,gid=\$(cat /etc/group | grep '^debugfs-access:' | cut -d':' -f3) debugfs /sys/kernel/debug
mount_with_log -t tracefs -o rw,nosuid,nodev,noexec,relatime,seclabel,mode=0755 tracefs /sys/kernel/tracing
mount_with_log -t configfs -o rw,nosuid,nodev,noexec,relatime configfs /sys/kernel/config
mount_with_log -t bpf -o rw,nosuid,nodev,noexec,relatime,mode=0770,gid=\$(cat /etc/group | grep '^bpf-access:' | cut -d':' -f3) bpf /sys/fs/bpf
mount_with_log -t securityfs -o ro,nosuid,nodev,noexec,relatime securityfs /sys/kernel/security
mount_with_log -t efivarfs -o rw,nosuid,nodev,noexec,relatime,uid=20130,gid=20130 efivarfs /sys/firmware/efi/efivars

# --- 2. Mount Stateful Partition ---
echo "Preparing and mounting stateful partition..."
data_partition="\$(df -h --output=source / | tail -1 | sed 's/.\$//')1"
if [ ! -b \$data_partition ]; then echo "FATAL: data partition \$data_partition not found."; reboot -f; fi
tune2fs -g 20119 -O encrypt,project,quota,verity -Q usrquota,grpquota,prjquota \$data_partition
mount_or_fail -t ext4 -o rw,nosuid,nodev,noexec,noatime,seclabel,discard,commit=600 \$data_partition /mnt/stateful_partition

if [ -f /mnt/stateful_partition/factory_install_reset ]; then echo "Factory reset triggered. Wiping stateful partition."; rm -rf /mnt/stateful_partition/{*,.*}; fi

# --- 3. Mount Encrypted Stateful and Core Bind Mounts ---
echo "Setting up encrypted partition and core bind mounts..."
systemd-tmpfiles --create --remove --boot --prefix /mnt/stateful_partition
mount_or_fail -o bind /mnt/stateful_partition/home /home
mount_with_log -o remount,rw,nosuid,nodev,noexec,noatime,nosymfollow,seclabel /home

if [ -f /etc/init/tpm2-simulator.conf ]; then initctl start tpm2-simulator; fi

if [ -b /dev/mapper/encstateful ]; then
    mount_or_fail -t ext4 -o rw,nosuid,nodev,noexec,noatime,seclabel,discard,commit=600 /dev/mapper/encstateful /mnt/stateful_partition/encrypted
    mount_or_fail -o bind /mnt/stateful_partition/encrypted/var /var
    mount_or_fail -o bind /mnt/stateful_partition/encrypted/chronos /home/chronos
    rm -r /var/log
else
    echo "WARNING: Encrypted device not found. Using unencrypted directories."
    mkdir -p /mnt/stateful_partition/encrypted/chronos /mnt/stateful_partition/encrypted/var
    mount_or_fail -o bind /mnt/stateful_partition/encrypted/var /var
    mount_or_fail -o bind /mnt/stateful_partition/encrypted/chronos /home/chronos
    rm -r /var/log
fi

systemd-tmpfiles --create --remove --boot --prefix /home --prefix /var
mount_with_log -o bind /run /var/run
mount_with_log -o bind /run/lock /var/lock

# --- 4. Setup Daemon-Store and Daemon-Store-Cache ---
echo "Setting up tmpfs for daemon-store and daemon-store-cache..."
for d in /etc/daemon-store/*/; do
    daemon_name=\$(basename "\$d")
    mkdir -p "/run/daemon-store/\$daemon_name"
    mount_with_log -t tmpfs -o rw,nosuid,nodev,noexec,relatime,seclabel,mode=755 tmpfs "/run/daemon-store/\$daemon_name"
    mount_with_log --make-shared "/run/daemon-store/\$daemon_name"
    mkdir -p "/run/daemon-store-cache/\$daemon_name"
    mount_with_log -t tmpfs -o rw,nosuid,nodev,noexec,relatime,seclabel,mode=755 tmpfs "/run/daemon-store-cache/\$daemon_name"
    mount_with_log --make-shared "/run/daemon-store-cache/\$daemon_name"
done

# --- 5. Mount System Component SquashFS Images ---
# These are essential system components packaged as read-only squashfs images.
echo "Mounting system component squashfs images..."
mount_with_log -t squashfs -o ro,nosuid,nodev,relatime,seclabel,errors=continue /usr/share/cros-camera/g3_libs.squash /usr/share/cros-camera/libfs
mount_with_log -t squashfs -o ro,nosuid,nodev,relatime,seclabel,errors=continue /usr/share/chromeos-assets/speech_synthesis/patts.squash /usr/share/chromeos-assets/speech_synthesis/patts

# --- 6. Prepare for ARC++ (Android) ---
echo "Preparing mounts for ARC++..."
ARC_IMG_SYS="/opt/google/containers/android/system.raw.img"
ARC_IMG_VENDOR="/opt/google/containers/android/vendor.raw.img"
ARC_SDCARD="/opt/google/containers/arc-sdcard/rootfs.squashfs"
ARC_OBB="/opt/google/containers/arc-obb-mounter/rootfs.squashfs"

if [ -f "\$ARC_IMG_SYS" ] && [ -f "\$ARC_IMG_VENDOR" ]; then
    echo "ARC system/vendor images found. Setting up base mounts..."
    mount_with_log -t squashfs -o ro,relatime,seclabel,errors=continue "\$ARC_IMG_SYS" /mnt/stateful_partition/unencrypted/android/root
    mount_with_log -t squashfs -o ro,relatime,seclabel,errors=continue "\$ARC_IMG_VENDOR" /mnt/stateful_partition/unencrypted/android/vendor
    # The overlayfs mounts are handled later by arc-setup.
else
    echo "ARC system/vendor images not found, skipping mounts."
fi

if [ -f "\$ARC_SDCARD" ]; then
    mount_with_log -t squashfs -o ro,nosuid,noexec,relatime,seclabel,errors=continue "\$ARC_SDCARD" /opt/google/containers/arc-sdcard/mountpoints/container-root
fi

if [ -f "\$ARC_OBB" ]; then
    mount_with_log -t squashfs -o ro,nosuid,noexec,relatime,seclabel,errors=continue "\$ARC_OBB" /opt/google/containers/arc-obb-mounter/mountpoints/container-root
fi

# --- 7. Setup Other Basic & FydeOS-specific Mounts ---
echo "Setting up other basic and FydeOS-specific mounts..."
mount_with_log -t tmpfs -o rw,nosuid,nodev,noexec,relatime,seclabel media /media
mount_with_log --make-shared /media
systemd-tmpfiles --create --remove --boot --prefix /media

mkdir -p /mnt/stateful_partition/dev_image
mount_with_log -o bind /mnt/stateful_partition/dev_image /usr/local
mount_with_log -o remount,rw,suid,dev,exec,noatime,seclabel /usr/local

if [ -d /mnt/stateful_partition/var_overlay/cache/dlc-images ]; then
    mount_with_log -o bind /mnt/stateful_partition/var_overlay/cache/dlc-images /var/cache/dlc-images
fi

mount_with_log -o bind / /usr/share/hwtuner-script
mount_with_log -o bind / /usr/share/fydeos-ota-checker
mount_with_log -o bind / /usr/share/fydeos-backup

# --- 8. Final Touches ---
# NOTE: ZRAM swap, cryptohome user mounts, and dynamic components loaded by imageloaderd
# are handled by other, later services and are intentionally NOT included here.
echo "Applying final configurations..."
restorecon -r /home/chronos /home/root /home/user /sys/devices/system/cpu /var
mkdir -p /var/log/asan && chmod 1777 /var/log/asan

echo "--- Custom startup script finished successfully ---"
exit 0
STARTUP
if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 0))); fi
chmod 0755 /roota/sbin/chromeos_startup
if [ ! "$?" -eq 0 ]; then ret=$((ret + (2 ** 1))); fi
exit $ret