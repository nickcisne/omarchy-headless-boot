#!/usr/bin/env bash
set -Eeuo pipefail

readonly HOOKS_FILE=/etc/mkinitcpio.conf.d/omarchy_hooks.conf
readonly LIMINE_DEFAULTS=/etc/default/limine
DRY_RUN=false

if [[ ${1:-} == --dry-run ]]; then
	DRY_RUN=true
	shift
fi

[[ $# -eq 0 ]] || {
	printf 'Usage: %s [--dry-run]\n' "$0" >&2
	exit 2
}

log() {
	printf '\n==> %s\n' "$*"
}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

backup_file() {
	local file=$1
	local backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
	sudo cp -a -- "$file" "$backup"
	printf 'Backup: %s\n' "$backup"
}

require_command awk
require_command blkid
require_command cryptsetup
require_command findmnt
require_command grep
require_command limine-mkinitcpio
require_command lsblk
require_command mkinitcpio
require_command sed
require_command systemd-cryptenroll

(( EUID == 0 )) || sudo -v || fail 'sudo authentication failed'

[[ -f $HOOKS_FILE ]] || fail "missing $HOOKS_FILE"
[[ -f $LIMINE_DEFAULTS ]] || fail "missing $LIMINE_DEFAULTS"

root_source=$(findmnt -no SOURCE /)
[[ $root_source == /dev/mapper/root* ]] ||
	fail "root is $root_source, expected /dev/mapper/root"

LUKS_DEVICE=$(sudo cryptsetup status root |
	sed -n 's/^[[:space:]]*device:[[:space:]]*//p' | head -n1)
[[ -n $LUKS_DEVICE ]] || fail 'could not determine the backing device of /dev/mapper/root'
readonly LUKS_DEVICE
[[ -b $LUKS_DEVICE ]] || fail "$LUKS_DEVICE is not a block device"

sudo cryptsetup isLuks "$LUKS_DEVICE" ||
	fail "$LUKS_DEVICE is not a LUKS device"

luks_uuid=$(sudo blkid -s UUID -o value "$LUKS_DEVICE")
[[ $luks_uuid =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] ||
	fail "could not determine a valid LUKS UUID"

printf 'LUKS device: %s\n' "$LUKS_DEVICE"
printf 'LUKS UUID:   %s\n' "$luks_uuid"

log 'Checking required initramfs hook'
sudo mkinitcpio -H sd-encrypt >/dev/null ||
	fail 'sd-encrypt is unavailable'

hooks_line=$(sudo grep -m1 -E '^[[:space:]]*HOOKS=' "$HOOKS_FILE" || true)
if [[ $hooks_line == *'sd-encrypt'* && $hooks_line == *'systemd'* ]]; then
	printf 'Initramfs hooks already use systemd/sd-encrypt.\n'
elif [[ $hooks_line == *' encrypt '* ]]; then
	if $DRY_RUN; then
		printf 'Would replace the active encrypt hook with systemd + sd-encrypt.\n'
	else
		backup_file "$HOOKS_FILE"
		sudo sed -i -E \
			's/^HOOKS=\(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs\)$/HOOKS=(base systemd udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block sd-encrypt filesystems fsck btrfs-overlayfs)/' \
			"$HOOKS_FILE"
	fi
else
	fail "unexpected HOOKS line in $HOOKS_FILE"
fi

hooks_line=$(sudo grep -m1 -E '^[[:space:]]*HOOKS=' "$HOOKS_FILE" || true)
if $DRY_RUN; then
	printf 'Would produce: HOOKS=(base systemd udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block sd-encrypt filesystems fsck btrfs-overlayfs)\n'
else
	[[ $hooks_line == *'systemd'* && $hooks_line == *'sd-encrypt'* ]] ||
		fail 'initramfs hook replacement did not verify'
	[[ $hooks_line != *' encrypt '* ]] ||
		fail 'classic encrypt hook is still present'
	printf '%s\n' "$hooks_line"
fi

log 'Updating Limine kernel command line'
limine_line=$(sudo grep -n '^KERNEL_CMDLINE\[default\]' "$LIMINE_DEFAULTS" || true)
[[ -n $limine_line ]] || fail "no default kernel command line in $LIMINE_DEFAULTS"

if [[ $limine_line == *"rd.luks.uuid=$luks_uuid"* &&
	  $limine_line == *"rd.luks.name=$luks_uuid=root"* ]]; then
	printf 'Limine command line already uses rd.luks parameters.\n'
elif [[ $limine_line == *'cryptdevice='* ]]; then
	if $DRY_RUN; then
		printf 'Would replace cryptdevice with rd.luks.uuid and rd.luks.name for this LUKS UUID.\n'
	else
		backup_file "$LIMINE_DEFAULTS"
		sudo sed -i \
			"s#cryptdevice=[^ ]*#rd.luks.uuid=${luks_uuid} rd.luks.name=${luks_uuid}=root#" \
			"$LIMINE_DEFAULTS"
	fi
else
	fail 'Limine command line contains neither cryptdevice nor the expected rd.luks parameters'
fi

limine_line=$(sudo grep -n '^KERNEL_CMDLINE\[default\]' "$LIMINE_DEFAULTS")
if $DRY_RUN; then
	printf 'Would add: rd.luks.uuid=%s rd.luks.name=%s=root\n' "$luks_uuid" "$luks_uuid"
else
	[[ $limine_line == *"rd.luks.uuid=$luks_uuid"* &&
		$limine_line == *"rd.luks.name=$luks_uuid=root"* ]] ||
		fail 'Limine command line replacement did not verify'
	printf '%s\n' "$limine_line"
fi

log 'Rebuilding Limine UKI'
if $DRY_RUN; then
	printf 'Would run: sudo limine-mkinitcpio\n'
else
	sudo limine-mkinitcpio
fi

log 'Enrolling TPM2 token'
if $DRY_RUN; then
	printf 'Would enroll TPM2 with PCR 7 if no systemd-tpm2 token exists.\n'
elif sudo cryptsetup luksDump "$LUKS_DEVICE" | grep -q 'systemd-tpm2'; then
	printf 'A systemd-tpm2 token is already present; enrollment skipped.\n'
else
	sudo systemd-cryptenroll \
		--tpm2-device=auto \
		--tpm2-pcrs=7 \
		"$LUKS_DEVICE"
fi

if ! $DRY_RUN; then
	sudo cryptsetup luksDump "$LUKS_DEVICE" | grep -q 'systemd-tpm2' ||
		fail 'TPM2 token was not found after enrollment'
fi

log 'Rebuilding Limine UKI after TPM enrollment'
if $DRY_RUN; then
	printf 'Would run: sudo limine-mkinitcpio\n'
else
	sudo limine-mkinitcpio
fi

log 'Checking SSH and network readiness'
systemctl is-enabled sshd
systemctl is-active sshd
if systemctl is-active --quiet NetworkManager; then
	printf 'Network manager: NetworkManager active\n'
elif systemctl is-active --quiet systemd-networkd; then
	printf 'Network manager: systemd-networkd active\n'
else
	fail 'neither NetworkManager nor systemd-networkd is active'
fi

if command -v ss >/dev/null 2>&1; then
	ss -ltn | grep -qE '(:22[[:space:]]|:22$)' ||
		fail 'sshd is not listening on TCP port 22'
	ss -ltn | grep -E '(:22[[:space:]]|:22$)' || true
fi

cat <<'EOF'

Configuration complete. Keep the disk passphrase available for the first reboot.
Do not reboot if either limine-mkinitcpio invocation reported an error.
When ready, run: sudo reboot
EOF
