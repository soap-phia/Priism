#!/bin/busybox sh

set -eE

TMPFS_SIZE=1024M
NEWROOT_MNT=/newroot
ROOTFS_MNT=/usb

STATEFUL_MNT="$1"
STATEFUL_DEV="$2"
BOOTSTRAP_DEV="$3"
ARCHITECTURE="${4:-x86_64}"

ROOTFS_DEV=

SCRIPT_DATE="[2025-5-21]"

COLOR_RESET="\033[0m"
COLOR_BLACK_B="\033[1;30m"
COLOR_RED_B="\033[1;31m"
COLOR_GREEN="\033[0;32m"
COLOR_GREEN_B="\033[1;32m"
COLOR_YELLOW="\033[0;33m"
COLOR_YELLOW_B="\033[1;33m"
COLOR_BLUE_B="\033[1;34m"
COLOR_MAGENTA_B="\033[1;35m"
COLOR_CYAN_B="\033[1;36m"

fail() {
	printf "%b\nAborting.\n" "$*" >&2
	cleanup || :

	sleep 1
	self_shell || :

	tail -f /dev/null
	exit 1
}

cleanup() {
	umount "$STATEFUL_MNT" || :
	umount "$ROOTFS_MNT" || :
}

trap 'fail "An unhandled error occured."' ERR

enable_input() {
	stty echo || :
}

disable_input() {
	stty -echo || :
}

clear_line() {
	local cols
	cols=$(stty size | cut -d" " -f 2)
	printf "%-${cols}s\r"
}

pv_dircopy() {
	[ -d "$1" ] || return 1
	local apparent_bytes
	apparent_bytes=$(du -sb "$1" | cut -f 1)
	mkdir -p "$2"
	tar -cf - -C "$1" . | pv -f -s "${apparent_bytes:-0}" | tar -xf - -C "$2"
}

determine_rootfs() {
	local bootstrap_num
	bootstrap_num="$(echo "$BOOTSTRAP_DEV" | grep -o '[0-9]*$')"
	ROOTFS_DEV="$(echo "$BOOTSTRAP_DEV" | sed 's/[0-9]*$//')$((bootstrap_num + 1))"
	[ -b "$ROOTFS_DEV" ] || return 1
}

patch_new_root_sh1mmer() {
	[ -f "$NEWROOT_MNT/sbin/chromeos_startup" ] && sed -i "s/BLOCK_DEVMODE=1/BLOCK_DEVMODE=/g" "$NEWROOT_MNT/sbin/chromeos_startup"
	[ -f "$NEWROOT_MNT/usr/share/cros/dev_utils.sh" ] && sed -i "/^dev_check_block_dev_mode\(\)/a return" "$NEWROOT_MNT/usr/share/cros/dev_utils.sh"
	[ -f "$NEWROOT_MNT/sbin/chromeos-boot-alert" ] && sed -i "/^mode_block_devmode\(\)/a return" "$NEWROOT_MNT/sbin/chromeos-boot-alert"
	# disable factory-related jobs
	local file
	local disable_jobs="factory_shim factory_install factory_ui"
	for job in $disable_jobs; do
		file="$NEWROOT_MNT/etc/init/${job}.conf"
		if [ -f "$file" ]; then
			sed -i '/^start /!d' "$file"
			echo "exec true" >>"$file"
		fi
	done
}

# todo: dev console on tty4, better logging

disable_input

mkdir -p "$NEWROOT_MNT" "$ROOTFS_MNT"
mount -t tmpfs tmpfs "$NEWROOT_MNT" -o "size=$TMPFS_SIZE" || fail "Failed to mount tmpfs"

determine_rootfs || fail "Could not determine rootfs"
mount -o ro "$ROOTFS_DEV" "$ROOTFS_MNT" || fail "Failed to mount rootfs $ROOTFS_DEV"

printf "\033[?25l\033[2J\033[H"

printf "${COLOR_MAGENTA_B}"
echo "                                              ...."
echo "                        ..                  ......"
echo "                       .::.              ........."
echo "                      .:..:.          ......:::..."
echo "                     .::..::.      ..::::---:::..."
echo "  ........          ::::::::::  ..::-====--::.... "
echo "        ...:::::...::::::::..:::-=++=--:.....     "
echo "              ....----:::::::::-:.....            "
echo "                .:-:.........::::.                "
echo "               .............::::-:.               "
echo "               ............::::::-:.              "
echo "              .....::::::::::::::--:              "
printf "${COLOR_RESET}"
echo "Priism is loading..."
echo "Bootloader version: ${SCRIPT_DATE}"
echo "https://github.com/xmb9/Priism"
echo ""

echo "Copying rootfs..."
pv_dircopy "$ROOTFS_MNT" "$NEWROOT_MNT"
umount "$ROOTFS_MNT"
echo ""

SKIP_SH1MMER_PATCH=0

echo "Patching new root..."
printf "${COLOR_BLACK_B}"
/bin/patch_new_root.sh "$NEWROOT_MNT" "$STATEFUL_DEV"
[ "$SKIP_SH1MMER_PATCH" -eq 0 ] && patch_new_root_sh1mmer
printf "${COLOR_RESET}"
echo ""

if [ "$SKIP_SH1MMER_PATCH" -eq 0 ]; then
	echo "Copying Priism files..."
	pv_dircopy "$STATEFUL_MNT/root/noarch" "$NEWROOT_MNT" || :
	pv_dircopy "$STATEFUL_MNT/root/$ARCHITECTURE" "$NEWROOT_MNT" || :
	echo ""
fi

umount "$STATEFUL_MNT"

# write this to a file so the user can easily run this from the debug shell
cat <<EOF >/bin/sh1mmer_switch_root
#!/bin/busybox sh

if [ \$\$ -ne 1 ]; then
	echo "No PID 1. Abort."
	exit 1
fi

BASE_MOUNTS="/sys /proc /dev"
move_mounts() {
	# copied from https://chromium.googlesource.com/chromiumos/platform/initramfs/+/54ea247a6283e7472a094215b4929f664e337f4f/factory_shim/bootstrap.sh#302
	echo "Moving \$BASE_MOUNTS to $NEWROOT_MNT"
	for mnt in \$BASE_MOUNTS; do
		# \$mnt is a full path (leading '/'), so no '/' joiner
		mkdir -p "$NEWROOT_MNT\$mnt"
		mount -n -o move "\$mnt" "$NEWROOT_MNT\$mnt"
	done
	echo "Done."
}

move_mounts
echo "exec switch_root"
echo "this shouldn't take more than a few seconds"
exec switch_root "$NEWROOT_MNT" /sbin/priisminit -v --default-console output || :
EOF
chmod +x /bin/sh1mmer_switch_root

enable_input
exec sh1mmer_switch_root || :

# should never reach here
fail "Failed to exec switch_root."
