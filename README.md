# Omarchy Headless Boot

Configure TPM2-backed LUKS unlocking on Omarchy so a system installed from the Omarchy ISO can boot without an interactive disk-unlock prompt and become available for remote SSH access.

For bluetooth keyboard/mouse enthusiasts, this also means you no longer need to keep a 2.4 GHz keyboard connected through a USB dongle just to log in. The bluetooth and network stacks initialize after the system powers on.

The script preserves Secure Boot measurement by enrolling the TPM2 key against PCR 7 and keeps the existing LUKS passphrase as a fallback.

## Requirements

- Omarchy
- LUKS2-encrypted root mapped as `/dev/mapper/root`
- Secure Boot enabled
- TPM2 available and enabled in firmware
- A working local disk passphrase
- `sshd` and a network manager configured for the system

The script targets Omarchy's current Limine and mkinitcpio layout. Review it before using it after an Omarchy or systemd update.

## Usage

Clone the repository and inspect the script:

```bash
git clone https://github.com/nickcisne/omarchy-headless-boot.git
cd omarchy-headless-boot
less omarchy-headless-boot.sh
```

Run the non-destructive check first:

```bash
bash omarchy-headless-boot.sh --dry-run
```

Apply the configuration:

```bash
bash omarchy-headless-boot.sh
```

The script requests sudo access and asks for the existing LUKS passphrase when enrolling the TPM2 token. It does not reboot the machine.

## What It Does

1. Detects the physical LUKS device backing `/dev/mapper/root`.
2. Verifies the expected Omarchy configuration files and `sd-encrypt` hook.
3. Backs up configuration files with timestamped `.bak` suffixes.
4. Replaces the classic `encrypt` initramfs hook with `systemd` and `sd-encrypt`.
5. Replaces Limine's `cryptdevice=` argument with `rd.luks.uuid=` and `rd.luks.name=` arguments.
6. Rebuilds the Limine UKI.
7. Enrolls a TPM2 unlock token using PCR 7, unless one already exists.
8. Rebuilds the Limine UKI again and checks SSH/network readiness.

Generated files such as `/boot/limine.conf` are not edited directly.

## Afterward

Keep the disk passphrase available for the first reboot. When ready, reboot locally:

```bash
sudo reboot
```

From another machine, connect using the server's address:

```bash
ssh your-user@server-address
```

## Recovery

TPM unlocking depends on the measured boot state and PCR policy. Firmware, Secure Boot, bootloader, kernel, or initramfs changes may cause TPM unlocking to fail. The original LUKS passphrase remains the recovery path; keep it available and test it before relying on unattended boot.

Do not use this script if its expected configuration layout no longer matches the installed Omarchy version. Review the script and current system configuration first.
