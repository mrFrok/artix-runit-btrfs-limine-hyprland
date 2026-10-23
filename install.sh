#!/usr/bin/env bash
# Artix Linux (runit) auto-installer
#   btrfs + snapper + limine (snapshot boot entries) + SDDM + Hyprland + NVIDIA (open, Turing+)
#   Target: AMD Ryzen 5 5500 + RTX 2060 Super, NVMe, UEFI. Optional Windows dual boot.
#
# Run from the Artix live ISO as root:
#   bash install.sh
set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults (can be overridden via environment: TIMEZONE=... bash install.sh)
# ----------------------------------------------------------------------------
TIMEZONE="${TIMEZONE:-Europe/Moscow}"
LANG_="${LANG_:-ru_RU.UTF-8}"
KEYMAP="${KEYMAP:-ru}"
CONSOLE_FONT="${CONSOLE_FONT:-cyr-sun16}"
ESP_SIZE="${ESP_SIZE:-2G}"
BTRFS_OPTS="noatime,compress=zstd:1"
MNT=/mnt
TTL_FIX=no

ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

c_red=$'\e[1;31m'; c_grn=$'\e[1;32m'; c_ylw=$'\e[1;33m'; c_rst=$'\e[0m'
info() { printf '%s==>%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s==> WARNING:%s %s\n' "$c_ylw" "$c_rst" "$*"; }
die()  { printf '%s==> ERROR:%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

ask() { # ask VAR "prompt" [default]
	local __v __d="${3:-}"
	read -rp "$2${__d:+ [$__d]}: " __v
	printf -v "$1" '%s' "${__v:-$__d}"
}

ask_pass() { # ask_pass VAR "prompt"
	local p1 p2
	while true; do
		read -rsp "$2: " p1; echo
		read -rsp "Repeat: " p2; echo
		[[ -n "$p1" && "$p1" == "$p2" ]] && break
		warn "Passwords are empty or do not match, try again."
	done
	printf -v "$1" '%s' "$p1"
}

# Shared with the chroot stage: pacman retry wrapper + mirror ranking.
cat >/tmp/rank-mirrors.sh <<'RANK_EOF'
pac() { # pacman with retries (flaky/mobile connections)
	local i
	for i in 1 2 3 4 5; do
		pacman "$@" && return 0
		echo "==> pacman failed (attempt $i/5), retrying in 5s..." >&2
		sleep 5
	done
	return 1
}

rank_mirrors() { # rank_mirrors <mirrorlist> <repo to test> [count]
	local list=$1 repo=$2 count=${3:-8} tmp out url test i=0
	tmp=$(mktemp -d)
	out=$(mktemp)
	while read -r url; do
		test=${url//\$repo/$repo}
		test=${test//\$arch/x86_64}
		(
			t=$(curl -sfo /dev/null --connect-timeout 3 -m 10 -w '%{time_total}' "$test/$repo.db") &&
				echo "$t $url" >"$tmp/$i"
		) &
		i=$((i + 1))
		if ((i % 20 == 0)); then wait; fi
	done < <(sed -n 's/^[#[:space:]]*Server[[:space:]]*=[[:space:]]*//p' "$list" | sort -u)
	wait
	cat "$tmp"/* 2>/dev/null | sort -n | head -n "$count" | awk '{print "Server = " $2}' >"$out" || true
	rm -rf "$tmp"
	if [[ -s "$out" ]]; then
		cp "$list" "$list.bak"
		cat "$out" >"$list"
		rm -f "$out"
		return 0
	fi
	rm -f "$out"
	return 1
}
RANK_EOF
source /tmp/rank-mirrors.sh

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
((EUID == 0)) || die "Run as root."
[[ -d /sys/firmware/efi/efivars ]] || die "Not booted in UEFI mode."
command -v basestrap >/dev/null || die "basestrap not found — is this the Artix live ISO?"
# Old ISOs have a stale keyring/glibc: installing current packages into them breaks tools
pacman_ver=$(pacman -Q pacman | awk '{print $2}')
if (($(vercmp "$pacman_ver" 6.1) < 0)); then
	die "This live ISO is too old (pacman $pacman_ver). Download the latest base-runit ISO from https://artixlinux.org/download.php"
fi

info "Checking network..."
net_ok() { # ICMP may be filtered, so also try plain HTTP to an IP
	ping -c1 -W3 1.1.1.1 &>/dev/null || ping -c1 -W3 8.8.8.8 &>/dev/null ||
		curl -so /dev/null -m 5 http://1.1.1.1 || curl -so /dev/null -m 5 http://8.8.8.8
}
if ! net_ok; then
	gw=$(ip route show default | awk '{print $3; exit}')
	if [[ -n "$gw" ]] && ping -c1 -W3 "$gw" &>/dev/null; then
		warn "Gateway $gw is reachable, but the internet is not."
		warn "Phone USB/Wi-Fi tethering? Mobile carriers often block it by TTL — trying TTL=65..."
		sysctl -qw net.ipv4.ip_default_ttl=65
		net_ok || die "Still no internet via $gw. Check mobile data / tethering limits on the phone."
		TTL_FIX=yes
	else
		die "No network. Check 'ip a' / 'ip route'; cable: 'dhcpcd', Wi-Fi: 'connmanctl'. Then rerun."
	fi
fi
if ! getent hosts artixlinux.org &>/dev/null; then
	warn "DNS is not working, switching to 1.1.1.1 / 8.8.8.8"
	rm -f /etc/resolv.conf
	printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >/etc/resolv.conf
	getent hosts artixlinux.org &>/dev/null || die "DNS still does not work."
fi

# A wrong clock (common with Windows dual boot) breaks gpg: "key was created in the future".
# NTP may be missing/blocked on the ISO, so take the time from an HTTPS Date header.
info "Syncing clock..."
http_date=$(curl -sI -m 10 https://github.com | sed -n 's/^[Dd]ate: //p' | tr -d '\r')
if [[ -n "$http_date" ]] && date -u -s "$http_date" >/dev/null; then
	info "Clock set to $(date -u '+%F %T') UTC"
else
	warn "Could not sync the clock, current time: $(date -u '+%F %T') UTC"
fi

# Known-good mirrors as extra candidates, in case the ISO's mirrorlist is outdated
if ! grep -q 'installer fallback' /etc/pacman.d/mirrorlist; then
	cat >>/etc/pacman.d/mirrorlist <<'EOF'
# installer fallback candidates
#Server = https://mirror1.artixlinux.org/repos/$repo/os/$arch
#Server = https://mirrors.dotsrc.org/artix-linux/repos/$repo/os/$arch
#Server = https://mirror.netcologne.de/artix-linux/$repo/os/$arch
#Server = https://mirror.clarkson.edu/artix-linux/repos/$repo/os/$arch
#Server = https://ftp.sh.cvut.cz/artix-linux/$repo/os/$arch
EOF
fi
info "Ranking Artix mirrors (this takes a few seconds)..."
if rank_mirrors /etc/pacman.d/mirrorlist system 8; then
	sed 's/^/    /' /etc/pacman.d/mirrorlist
else
	warn "No mirror responded, keeping the original mirrorlist."
fi

# Clean pacman config with Artix repos only: live ISOs may ship Arch [extra]/[community]
# (community no longer exists) which breaks syncing and causes package conflicts.
# The live system is throwaway, so just replace its pacman.conf (backup kept).
[[ -f /etc/pacman.conf.iso ]] || cp /etc/pacman.conf /etc/pacman.conf.iso
cat >/etc/pacman.conf <<'EOF'
[options]
HoldPkg     = pacman glibc
Architecture = auto
ParallelDownloads = 3
DisableDownloadTimeout
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[system]
Include = /etc/pacman.d/mirrorlist

[world]
Include = /etc/pacman.d/mirrorlist

[galaxy]
Include = /etc/pacman.d/mirrorlist
EOF

info "Updating keyring and installing missing tools in the live environment..."
pac -Sy --noconfirm || die "Could not sync Artix repositories."
pac -S --noconfirm --needed artix-keyring ||
	warn "Could not update artix-keyring, continuing with the ISO keyring."
declare -a missing=()
command -v mkfs.btrfs &>/dev/null || missing+=(btrfs-progs)
command -v mkfs.fat &>/dev/null || missing+=(dosfstools)
command -v sgdisk &>/dev/null || missing+=(gptfdisk)
if ((${#missing[@]})); then
	pac -S --noconfirm --needed "${missing[@]}" ||
		die "Could not install: ${missing[*]}"
fi
# Make sure every tool actually runs before anything destructive happens
for t in sgdisk mkfs.btrfs mkfs.fat wipefs pacman; do
	out=$("$t" --version 2>&1 || true)
	if grep -qE 'not found \(required by|error while loading shared libraries' <<<"$out"; then
		die "'$t' is broken in this live environment (library mismatch). Use the latest ISO."
	fi
done

RESUME=no
if mountpoint -q "$MNT" && [[ -f "$MNT/root/install.env" ]]; then
	warn "Found an unfinished installation in $MNT."
	read -rp "Resume it (skip partitioning and basestrap)? [Y/n]: " c
	[[ "$c" == [nN]* ]] || RESUME=yes
fi

if [[ $RESUME == no ]]; then
	# ----------------------------------------------------------------------------
	# Find existing Windows boot loaders (any ESP on any disk)
	# ----------------------------------------------------------------------------
	declare -a WIN_PARTS=() WIN_PARTUUIDS=()
	scan_windows() {
		local dev tmp
		tmp=$(mktemp -d)
		while read -r dev; do
			mount -o ro "$dev" "$tmp" 2>/dev/null || continue
			if [[ -f "$tmp/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
				WIN_PARTS+=("$dev")
				WIN_PARTUUIDS+=("$(blkid -s PARTUUID -o value "$dev")")
			fi
			umount "$tmp"
		done < <(lsblk -rpno NAME,PARTTYPE | awk -v g="$ESP_GUID" 'tolower($2)==g {print $1}')
		rmdir "$tmp"
	}
	scan_windows
	if ((${#WIN_PARTS[@]})); then
		info "Windows Boot Manager found on: ${WIN_PARTS[*]} — it will be added to the Limine menu."
	else
		warn "Windows Boot Manager not found (only Artix will be in the menu)."
	fi

	# ----------------------------------------------------------------------------
	# User input
	# ----------------------------------------------------------------------------
	echo
	info "Available disks:"
	lsblk -dpno NAME,SIZE,MODEL | grep -Ev 'loop|sr[0-9]|zram' || true
	echo
	default_disk=$(lsblk -dpno NAME | grep -m1 nvme || true)
	ask DISK "Target disk" "$default_disk"
	[[ -b "$DISK" ]] || die "$DISK is not a block device."

	win_on_disk=no
	for p in "${WIN_PARTS[@]}"; do
		[[ "/dev/$(lsblk -no PKNAME "$p")" == "$DISK" ]] && win_on_disk=yes
	done

	echo
	echo "Partitioning mode for $DISK:"
	echo "  1) Wipe the WHOLE disk (ESP $ESP_SIZE + btrfs)"
	echo "  2) Install into UNALLOCATED free space (existing partitions are kept)"
	if [[ $win_on_disk == yes ]]; then
		warn "Windows is on $DISK! Choose 2 (shrink a volume in Windows Disk Management first)."
		ask MODE "Mode" "2"
	else
		ask MODE "Mode" "1"
	fi
	[[ "$MODE" == 1 || "$MODE" == 2 ]] || die "Unknown mode: $MODE"

	ask HOSTNAME_ "Hostname" "artix"
	ask USERNAME "Username" "user"
	[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username."
	ask_pass USER_PASS "Password for $USERNAME"
	ask_pass ROOT_PASS "Password for root"
	ask TIMEZONE "Timezone" "$TIMEZONE"
	[[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Unknown timezone: $TIMEZONE"

	echo
	warn "Summary:"
	echo "  Disk:          $DISK (mode $MODE)"
	echo "  Host/user:     $HOSTNAME_ / $USERNAME"
	echo "  Timezone:      $TIMEZONE, locale $LANG_"
	echo "  Windows:       ${WIN_PARTS[*]:-none}"
	if [[ $MODE == 1 ]]; then
		[[ $win_on_disk == yes ]] && warn "THIS WILL DELETE WINDOWS ON $DISK!"
		read -rp "All data on $DISK will be destroyed. Type YES to continue: " c
		[[ "$c" == YES ]] || die "Aborted."
	else
		read -rp "Continue? [y/N]: " c
		[[ "$c" == [yY]* ]] || die "Aborted."
	fi

	# ----------------------------------------------------------------------------
	# Partitioning
	# ----------------------------------------------------------------------------
	umount -R "$MNT" 2>/dev/null || true

	if [[ $MODE == 1 ]]; then
		info "Partitioning $DISK..."
		wipefs -af "$DISK"
		sgdisk -Z "$DISK"
		sgdisk -o "$DISK"
	fi

	# Start 0 = beginning of the largest free block, so in mode 2 existing partitions stay intact.
	before=$(lsblk -rpno NAME "$DISK" | sort)
	sgdisk -n "0:0:+$ESP_SIZE" -t 0:ef00 -c 0:ARTIX_ESP "$DISK"
	sgdisk -n "0:0:0"          -t 0:8300 -c 0:ARTIX_ROOT "$DISK"
	partprobe "$DISK" 2>/dev/null || true
	udevadm settle
	sleep 1

	# Only look at partitions that did not exist before (mode 2 may have old ARTIX_* labels)
	new_parts=$(comm -13 <(echo "$before") <(lsblk -rpno NAME "$DISK" | sort))
	ESP_PART="" ROOT_PART=""
	for p in $new_parts; do
		case "$(lsblk -no PARTLABEL "$p")" in
		ARTIX_ESP) ESP_PART=$p ;;
		ARTIX_ROOT) ROOT_PART=$p ;;
		esac
	done
	[[ -b "$ESP_PART" && -b "$ROOT_PART" ]] || die "Could not find the newly created partitions."

	# Windows that lived on a wiped disk is gone
	if [[ $MODE == 1 ]]; then
		declare -a keep=()
		for i in "${!WIN_PARTS[@]}"; do
			[[ "/dev/$(lsblk -no PKNAME "${WIN_PARTS[$i]}" 2>/dev/null)" == "$DISK" ]] || keep+=("${WIN_PARTUUIDS[$i]}")
		done
		WIN_PARTUUIDS=("${keep[@]}")
	fi

	info "ESP: $ESP_PART, root: $ROOT_PART"
	mkfs.fat -F32 -n ARTIX_ESP "$ESP_PART"
	mkfs.btrfs -f -L ARTIX "$ROOT_PART"

	# ----------------------------------------------------------------------------
	# Btrfs subvolumes
	#   @ -> /    @home -> /home    @snapshots -> /.snapshots
	#   @var_log, @var_cache, @var_tmp — excluded from root snapshots
	# ----------------------------------------------------------------------------
	info "Creating subvolumes..."
	mount "$ROOT_PART" "$MNT"
	for sv in @ @home @snapshots @var_log @var_cache @var_tmp; do
		btrfs subvolume create "$MNT/$sv"
	done
	umount "$MNT"

	mount -o "$BTRFS_OPTS,subvol=@" "$ROOT_PART" "$MNT"
	mkdir -p "$MNT"/{boot,home,.snapshots,var/log,var/cache,var/tmp}
	mount -o "$BTRFS_OPTS,subvol=@home"      "$ROOT_PART" "$MNT/home"
	mount -o "$BTRFS_OPTS,subvol=@snapshots" "$ROOT_PART" "$MNT/.snapshots"
	mount -o "$BTRFS_OPTS,subvol=@var_log"   "$ROOT_PART" "$MNT/var/log"
	mount -o "$BTRFS_OPTS,subvol=@var_cache" "$ROOT_PART" "$MNT/var/cache"
	mount -o "$BTRFS_OPTS,subvol=@var_tmp"   "$ROOT_PART" "$MNT/var/tmp"
	mount -o fmask=0077,dmask=0077 "$ESP_PART" "$MNT/boot"

	# ----------------------------------------------------------------------------
	# Base system (basestrap copies the ranked mirrorlist into the target)
	# ----------------------------------------------------------------------------
	info "Installing base system (basestrap)..."
	for attempt in 1 2 3; do
		basestrap "$MNT" base base-devel runit elogind-runit \
			linux linux-headers linux-firmware amd-ucode mkinitcpio \
			btrfs-progs dosfstools efibootmgr \
			networkmanager networkmanager-runit dbus-runit \
			sudo git nano vim bash-completion && break
		((attempt < 3)) || die "basestrap failed (network?). Rerun the script."
		warn "basestrap failed (attempt $attempt/3), retrying in 5s..."
		sleep 5
	done

	info "Generating fstab..."
	fstabgen -U "$MNT" >>"$MNT/etc/fstab"
	# subvolid pins would break snapshot restore/rollback, keep only subvol=
	sed -i 's/subvolid=[0-9]*,\?//g; s/,\s/ /g' "$MNT/etc/fstab"

	# ----------------------------------------------------------------------------
	# Hand over to chroot
	# ----------------------------------------------------------------------------
	{
		printf 'HOSTNAME_=%q\n'   "$HOSTNAME_"
		printf 'USERNAME=%q\n'    "$USERNAME"
		printf 'USER_PASS=%q\n'   "$USER_PASS"
		printf 'ROOT_PASS=%q\n'   "$ROOT_PASS"
		printf 'TIMEZONE=%q\n'    "$TIMEZONE"
		printf 'LANG_=%q\n'       "$LANG_"
		printf 'KEYMAP=%q\n'      "$KEYMAP"
		printf 'CONSOLE_FONT=%q\n' "$CONSOLE_FONT"
		printf 'ROOT_UUID=%q\n'   "$(blkid -s UUID -o value "$ROOT_PART")"
		printf 'WIN_PARTUUIDS=(%s)\n' "${WIN_PARTUUIDS[*]:-}"
		printf 'TTL_FIX=%q\n'     "$TTL_FIX"
	} >"$MNT/root/install.env"
	chmod 600 "$MNT/root/install.env"
fi

cp /etc/pacman.d/mirrorlist "$MNT/etc/pacman.d/mirrorlist"
cp -L /etc/resolv.conf "$MNT/etc/resolv.conf"
cp /tmp/rank-mirrors.sh "$MNT/root/rank-mirrors.sh"

cat >"$MNT/root/chroot.sh" <<'CHROOT_EOF'
#!/usr/bin/env bash
set -euo pipefail
source /root/install.env
source /root/rank-mirrors.sh

c_grn=$'\e[1;32m'; c_ylw=$'\e[1;33m'; c_rst=$'\e[0m'
info() { printf '%s==>%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s==> WARNING:%s %s\n' "$c_ylw" "$c_rst" "$*"; }

# --- pacman: Artix lib32 + Arch [extra]/[multilib] ---------------------------
info "Configuring pacman (lib32, Arch extra/multilib)..."
sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 3/; s/^#Color/Color/' /etc/pacman.conf
grep -q '^DisableDownloadTimeout' /etc/pacman.conf || sed -i '/^\[options\]/a DisableDownloadTimeout' /etc/pacman.conf
sed -i '/^#\[lib32\]/{N;s/#//g}' /etc/pacman.conf
pac -Sy --noconfirm --needed artix-archlinux-support

cat >/etc/pacman.d/mirrorlist-arch <<'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.yandex.ru/archlinux/$repo/os/$arch
Server = https://mirror.truenetwork.ru/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://ftp.fau.de/archlinux/$repo/os/$arch
Server = https://mirror.netcologne.de/archlinux/$repo/os/$arch
Server = https://mirrors.dotsrc.org/archlinux/$repo/os/$arch
EOF
info "Ranking Arch mirrors..."
rank_mirrors /etc/pacman.d/mirrorlist-arch core 5 || warn "Arch mirror ranking failed, using the default list."

if ! grep -q '^\[extra\]' /etc/pacman.conf; then
	cat >>/etc/pacman.conf <<'EOF'

# Arch Linux repositories (artix-archlinux-support)
[extra]
Include = /etc/pacman.d/mirrorlist-arch

[multilib]
Include = /etc/pacman.d/mirrorlist-arch
EOF
fi
# If the clock jumped after basestrap (RTC in local time for Windows), the local master key
# is "created in the future" and gpg refuses to sign with it -> rebuild the keyring.
if ! pacman-key --populate archlinux; then
	warn "pacman keyring is broken (clock jump?), re-initializing it..."
	gpgconf --homedir /etc/pacman.d/gnupg --kill all 2>/dev/null || true
	rm -rf /etc/pacman.d/gnupg
	pacman-key --init
	pacman-key --populate artix archlinux
fi
pac -Syu --noconfirm

# --- packages ----------------------------------------------------------------
info "Installing packages (NVIDIA, Hyprland, SDDM, snapper, limine)..."
pac -S --noconfirm --needed \
	limine snapper inotify-tools rsync libnotify \
	nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings egl-wayland libva-nvidia-driver \
	hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk hyprpolkitagent \
	qt5-wayland qt6-wayland kitty wofi waybar dolphin xdg-utils xdg-user-dirs \
	sddm sddm-runit xorg-server \
	pipewire pipewire-pulse pipewire-alsa wireplumber \
	noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu \
	cronie cronie-runit

# --- locale / time / host ----------------------------------------------------
info "Locale, time, hostname..."
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/; s/^#\(ru_RU.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo "LANG=$LANG_" >/etc/locale.conf
printf 'KEYMAP=%s\nFONT=%s\n' "$KEYMAP" "$CONSOLE_FONT" >/etc/vconsole.conf
if [[ -f /etc/rc.conf ]]; then
	sed -i "s|^#\?KEYMAP=.*|KEYMAP=\"$KEYMAP\"|; s|^#\?FONT=.*|FONT=\"$CONSOLE_FONT\"|" /etc/rc.conf
fi
echo "$HOSTNAME_" >/etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME_.localdomain $HOSTNAME_
EOF
# Carrier tethering detection workaround, applied by runit at boot via sysctl.d
if [[ ${TTL_FIX:-no} == yes ]]; then
	echo 'net.ipv4.ip_default_ttl = 65' >/etc/sysctl.d/90-ttl.conf
fi
# limine-entry-tool / limine-snapper-sync identify the OS entry by machine-id
[[ -s /etc/machine-id ]] || dbus-uuidgen --ensure=/etc/machine-id

# --- users -------------------------------------------------------------------
info "Users..."
echo "root:$ROOT_PASS" | chpasswd
id "$USERNAME" &>/dev/null || useradd -m -G wheel,video,audio,input,storage -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

# --- mkinitcpio (NVIDIA early KMS, busybox hooks) ----------------------------
info "mkinitcpio..."
sed -i 's/^MODULES=.*/MODULES=(btrfs nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf
echo 'options nvidia_drm modeset=1 fbdev=1' >/etc/modprobe.d/nvidia.conf

CMDLINE="root=UUID=$ROOT_UUID rootflags=subvol=@ rw quiet loglevel=3 nvidia_drm.modeset=1 nvidia_drm.fbdev=1"

# --- snapper -----------------------------------------------------------------
info "snapper..."
if [[ ! -f /etc/snapper/configs/root ]]; then
	umount /.snapshots
	rmdir /.snapshots
	snapper --no-dbus -c root create-config /
	btrfs subvolume delete /.snapshots
	mkdir /.snapshots
	mount /.snapshots
fi
chmod 750 /.snapshots
chown :wheel /.snapshots
sed -i \
	-e 's/^ALLOW_GROUPS=.*/ALLOW_GROUPS="wheel"/' \
	-e 's/^SYNC_ACL=.*/SYNC_ACL="yes"/' \
	-e 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="10"/' \
	-e 's/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT="5"/' \
	-e 's/^TIMELINE_CREATE=.*/TIMELINE_CREATE="yes"/' \
	-e 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' \
	-e 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' \
	-e 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' \
	-e 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' \
	-e 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' \
	/etc/snapper/configs/root

# No systemd timers on runit -> cron jobs for timeline/cleanup
cat >/etc/cron.hourly/snapper-timeline <<'EOF'
#!/bin/sh
if [ -x /usr/lib/snapper/systemd-helper ]; then
	exec /usr/lib/snapper/systemd-helper --timeline
fi
exec snapper --no-dbus -c root create -c timeline -d timeline
EOF
cat >/etc/cron.daily/snapper-cleanup <<'EOF'
#!/bin/sh
if [ -x /usr/lib/snapper/systemd-helper ]; then
	exec /usr/lib/snapper/systemd-helper --cleanup
fi
snapper --no-dbus -c root cleanup number
snapper --no-dbus -c root cleanup timeline
EOF
chmod 755 /etc/cron.hourly/snapper-timeline /etc/cron.daily/snapper-cleanup

# --- limine config (shared by limine-entry-tool and limine-snapper-sync) ------
info "Limine config..."
cat >/etc/default/limine <<EOF
ESP_PATH="/boot"
TARGET_OS_NAME="Artix Linux"
KERNEL_CMDLINE[default]="$CMDLINE"
BOOT_ORDER="*, *fallback, Snapshots"
FIND_BOOTLOADERS=yes
ENABLE_UKI=no
ENABLE_LIMINE_FALLBACK=yes

# limine-snapper-sync
SNAPPER_CONFIG_NAME="root"
ROOT_SUBVOLUME_PATH="/@"
ROOT_SNAPSHOTS_PATH="/@snapshots"
MAX_SNAPSHOT_ENTRIES=10
LIMIT_USAGE_PERCENT=85
EOF
[[ -f /boot/limine.conf ]] || printf 'timeout: 5\n' >/boot/limine.conf

# --- AUR: limine-mkinitcpio-hook, limine-snapper-sync, yay-bin ---------------
info "Building AUR packages (GraalVM native-image — this takes a few minutes)..."
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/99-installer
chmod 440 /etc/sudoers.d/99-installer
BUILD_DIR="/home/$USERNAME/.cache/aur-build"
aur_ok=yes
for pkg in limine-mkinitcpio-hook limine-snapper-sync yay-bin; do
	if ! su - "$USERNAME" -c "
		set -e
		mkdir -p '$BUILD_DIR' && cd '$BUILD_DIR'
		rm -rf '$pkg'
		git clone --depth 1 'https://aur.archlinux.org/$pkg.git'
		cd '$pkg'
		makepkg -si --noconfirm --needed
	"; then
		warn "Failed to build $pkg"
		[[ $pkg == yay-bin ]] || aur_ok=no
	fi
done
rm -rf "$BUILD_DIR"
rm -f /etc/sudoers.d/99-installer

# --- bootloader ----------------------------------------------------------------
add_windows_entries() {
	local id name n=0
	for id in "${WIN_PARTUUIDS[@]}"; do
		[[ -n "$id" ]] || continue
		grep -qi "uuid($id)" /boot/limine.conf && continue
		((++n))
		name="Windows"
		((n > 1)) && name="Windows $n"
		cat >>/boot/limine.conf <<EOF

/$name
    comment: Windows Boot Manager
    protocol: efi
    path: uuid($id):/EFI/Microsoft/Boot/bootmgfw.efi
EOF
	done
}

if [[ $aur_ok == yes ]]; then
	info "Limine: install + generate menu entries (limine-entry-tool)..."
	sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf keyboard keymap consolefont block filesystems btrfs-overlayfs fsck)/' /etc/mkinitcpio.conf
	limine-install --fallback || warn "limine-install failed"
	limine-update || warn "limine-update failed"
fi

# Fallback: manual Limine setup if the AUR tooling failed
if ! grep -q 'protocol: linux' /boot/limine.conf; then
	warn "Writing limine.conf manually (no snapshot menu)."
	mkinitcpio -P
	mkdir -p /boot/EFI/BOOT /boot/EFI/limine
	cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
	cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/limine_x64.efi
	esp_dev=$(findmnt -no SOURCE /boot)
	esp_disk="/dev/$(lsblk -no PKNAME "$esp_dev")"
	esp_num=$(cat "/sys/class/block/$(basename "$esp_dev")/partition")
	efibootmgr --create --disk "$esp_disk" --part "$esp_num" \
		--label "Limine" --loader '\EFI\limine\limine_x64.efi' || warn "efibootmgr could not create a boot entry"
	cat >/boot/limine.conf <<EOF
timeout: 5

/Artix Linux
    comment: machine-id=$(cat /etc/machine-id)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: $CMDLINE
    module_path: boot():/initramfs-linux.img

/Artix Linux (fallback)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: $CMDLINE
    module_path: boot():/initramfs-linux-fallback.img
EOF
fi
add_windows_entries

# Helper to re-add Windows later (e.g. after reinstalling it)
cat >/usr/local/bin/limine-add-windows <<'EOF'
#!/usr/bin/env bash
# Finds Windows Boot Manager on any ESP and adds it to /boot/limine.conf
set -euo pipefail
((EUID == 0)) || exec sudo "$0" "$@"
tmp=$(mktemp -d)
while read -r dev; do
	mount -o ro "$dev" "$tmp" 2>/dev/null || continue
	if [[ -f "$tmp/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
		id=$(blkid -s PARTUUID -o value "$dev")
		if grep -qi "uuid($id)" /boot/limine.conf; then
			echo "Windows on $dev is already in limine.conf"
		else
			printf '\n/Windows\n    comment: Windows Boot Manager\n    protocol: efi\n    path: uuid(%s):/EFI/Microsoft/Boot/bootmgfw.efi\n' "$id" >>/boot/limine.conf
			echo "Added: Windows ($dev)"
		fi
	fi
	umount "$tmp"
done < <(lsblk -rpno NAME,PARTTYPE | awk 'tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {print $1}')
rmdir "$tmp"
EOF
chmod 755 /usr/local/bin/limine-add-windows

# --- Hyprland session with D-Bus (no systemd user session on runit) -------------
info "Hyprland / SDDM..."
hypr_exec=$(sed -n 's/^Exec=//p' /usr/share/wayland-sessions/hyprland.desktop 2>/dev/null | head -1)
cat >/usr/share/wayland-sessions/hyprland-artix.desktop <<EOF
[Desktop Entry]
Name=Hyprland (Artix)
Comment=Hyprland with D-Bus session
Exec=dbus-run-session ${hypr_exec:-Hyprland}
Type=Application
DesktopNames=Hyprland
EOF

mkdir -p /etc/sddm.conf.d
cat >/etc/sddm.conf.d/10-artix.conf <<'EOF'
[General]
DisplayServer=x11
Numlock=on
EOF

# User Hyprland config: stock config + NVIDIA env + pipewire + us/ru layout
HYPR_DIR="/home/$USERNAME/.config/hypr"
mkdir -p "$HYPR_DIR"
if [[ -f /usr/share/hypr/hyprland.conf && ! -f "$HYPR_DIR/hyprland.conf" ]]; then
	cp /usr/share/hypr/hyprland.conf "$HYPR_DIR/hyprland.conf"
	if command -v artix-pipewire-launcher &>/dev/null; then
		pw_line="exec-once = artix-pipewire-launcher"
	else
		pw_line=$'exec-once = /usr/bin/pipewire\nexec-once = /usr/bin/pipewire-pulse\nexec-once = /usr/bin/wireplumber'
	fi
	cat >>"$HYPR_DIR/hyprland.conf" <<EOF

# ---------------- added by artix installer ----------------
# NVIDIA
env = LIBVA_DRIVER_NAME,nvidia
env = __GLX_VENDOR_LIBRARY_NAME,nvidia
env = NVD_BACKEND,direct
env = ELECTRON_OZONE_PLATFORM_HINT,auto

# Audio (no systemd user services on runit)
$pw_line

# Polkit agent, bar
exec-once = /usr/lib/hyprpolkitagent/hyprpolkitagent
exec-once = waybar

# Keyboard layouts: Alt+Shift to switch
input:kb_layout = us,ru
input:kb_options = grp:alt_shift_toggle
EOF
fi
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config"

# --- runit services --------------------------------------------------------------
info "Enabling runit services..."
for s in dbus elogind NetworkManager sddm cronie; do
	if [[ -d /etc/runit/sv/$s ]]; then
		ln -sf "/etc/runit/sv/$s" /etc/runit/runsvdir/default/
	else
		warn "runit service $s not found"
	fi
done

# --- snap-pac + first snapshot ---------------------------------------------------
info "snap-pac and the first snapshot..."
pac -S --noconfirm --needed snap-pac || warn "snap-pac was not installed"
snapper --no-dbus -c root create -d "Fresh install" -c important
if command -v limine-snapper-sync &>/dev/null; then
	limine-snapper-sync || warn "limine-snapper-sync failed"
fi

rm -f /root/install.env /root/rank-mirrors.sh
info "Done inside chroot."
CHROOT_EOF
chmod 700 "$MNT/root/chroot.sh"

info "Entering chroot..."
artix-chroot "$MNT" /bin/bash /root/chroot.sh
rm -f "$MNT/root/chroot.sh" "$MNT/root/install.env" "$MNT/root/rank-mirrors.sh"

echo
info "Installation complete!"
echo "  Check the boot menu: cat $MNT/boot/limine.conf"
echo "  Then: umount -R $MNT && reboot"
echo "  In SDDM pick the \"Hyprland (Artix)\" session."
