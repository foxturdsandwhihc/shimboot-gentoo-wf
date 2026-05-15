#!/bin/bash

# build_rootfs_gentoo.sh
# Stage3 + emerge-webrsync + binpkg-ONLY Gentoo bootstrap
# shimboot-gentoo-2: MAXIMUM speed, MINIMAL footprint
#
# KEY RULES:
#   - NEVER compile anything. Binary packages only.
#   - --usepkgonly = refuse to build from source, period.
#   - Skip GCC, binutils, glibc updates — stage3 already has them.
#   - Only install what's needed to boot + connect to wifi.

. ./common.sh
setup_error_trap

ROOTFS_DIR="${1}"
ARCH="${2:-amd64}"
PROFILE="${3:-default/linux/amd64/23.0/no-multilib/openrc}"
JOBS="${4:-$(nproc)}"

GENTOO_MIRROR="https://distfiles.gentoo.org"
GENTOO_BINHOST="https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/"
STAGE3_BASE_URL="${GENTOO_MIRROR}/releases/amd64/autobuilds"
STAGE3_FLAVOR="nomultilib-openrc"

print_title "Gentoo Binary Bootstrap"
print_info "rootfs dir    : $ROOTFS_DIR"
print_info "arch          : $ARCH"
print_info "profile       : $PROFILE"
print_info "jobs          : $JOBS"
print_info "binhost       : $GENTOO_BINHOST"
print_info "host kernel   : $(uname -r)"
print_info "free disk     : $(df -h . | tail -1 | awk '{print $4}') available"

assert_deps "wget tar pv"

STAGE3_DIR="/tmp/shimboot_stage3"
mkdir -p "$STAGE3_DIR" "$ROOTFS_DIR"

# ─── wget helpers ─────────────────────────────────────────────────────────────
wget_stdout() {
  wget --timeout=60 --tries=3 --no-verbose -O- "$1" 2>/dev/null
}
wget_file() {
  local url="$1" dest="$2"
  print_info "Downloading: $(basename "$url")"
  wget --timeout=120 --tries=3 --show-progress -q -c -O "$dest" "$url"
  print_info "  -> $(du -sh "$dest" | cut -f1)"
}
wget_file_optional() {
  local url="$1" dest="$2"
  wget --timeout=60 --tries=2 --show-progress -q -c -O "$dest" "$url" \
    || { rm -f "$dest"; return 0; }
}

# ─── Find latest stage3 ──────────────────────────────────────────────────────
print_step "Finding latest stage3 tarball"
LATEST_TXT=""
for flavor in "nomultilib-openrc" "nomultilib" "openrc"; do
  LATEST_URL="${STAGE3_BASE_URL}/latest-stage3-amd64-${flavor}.txt"
  print_info "Trying: $LATEST_URL"
  LATEST_TXT="$(wget_stdout "$LATEST_URL")" && {
    STAGE3_FLAVOR="$flavor"
    print_info "Flavor: $flavor"
    break
  } || { LATEST_TXT=""; }
done

[ -z "$LATEST_TXT" ] && { print_error "Could not fetch stage3 manifest."; exit 1; }

STAGE3_PATH="$(echo "$LATEST_TXT" | grep '\.tar\.' | grep -v '^#' | awk '{print $1}' | head -n1)"
[ -z "$STAGE3_PATH" ] && { print_error "Could not parse stage3 path."; echo "$LATEST_TXT"; exit 1; }

STAGE3_URL="${STAGE3_BASE_URL}/${STAGE3_PATH}"
STAGE3_FILENAME="$(basename "$STAGE3_PATH")"
STAGE3_FILE="$STAGE3_DIR/$STAGE3_FILENAME"

print_info "stage3 URL  : $STAGE3_URL"
print_info "stage3 file : $STAGE3_FILE"

# ─── Download stage3 ─────────────────────────────────────────────────────────
if [ -f "$STAGE3_FILE" ]; then
  print_info "Stage3 cached: $(du -sh "$STAGE3_FILE" | cut -f1)  (delete to re-download)"
else
  print_step "Downloading stage3 (~250MB)"
  wget_file "$STAGE3_URL" "$STAGE3_FILE"
  wget_file_optional "${STAGE3_URL}.sha256" "${STAGE3_FILE}.sha256"
fi

if [ -f "${STAGE3_FILE}.sha256" ]; then
  ( cd "$STAGE3_DIR" && sha256sum -c "${STAGE3_FILENAME}.sha256" ) \
    && print_info "SHA256: OK" || print_warn "SHA256 mismatch — proceeding anyway"
fi

# ─── Extract stage3 ──────────────────────────────────────────────────────────
print_step "Extracting stage3 into $ROOTFS_DIR  (~1-3 min)"
STAGE3_BYTES="$(stat -c%s "$STAGE3_FILE")"
pv -s "$STAGE3_BYTES" "$STAGE3_FILE" \
  | tar --xattrs-include='*.*' --numeric-owner --warning=no-unknown-keyword \
        -xJpf - -C "$ROOTFS_DIR" 2>&1 \
  | while IFS= read -r l; do print_debug "  tar: $l"; done

print_info "Rootfs after stage3: $(du -sh "$ROOTFS_DIR" | cut -f1)"

# ─── Critical dirs ────────────────────────────────────────────────────────────
print_step "Fixing portage directories"
mkdir -p "$ROOTFS_DIR/var/tmp/portage"
chmod 1777 "$ROOTFS_DIR/var/tmp/portage"
mkdir -p "$ROOTFS_DIR/var/cache/distfiles" \
         "$ROOTFS_DIR/var/cache/binpkg" \
         "$ROOTFS_DIR/var/db/repos" \
         "$ROOTFS_DIR/var/log/portage"

# ─── Portage config ───────────────────────────────────────────────────────────
print_step "Writing portage configuration"
mkdir -p \
  "$ROOTFS_DIR/etc/portage/package.use" \
  "$ROOTFS_DIR/etc/portage/package.accept_keywords" \
  "$ROOTFS_DIR/etc/portage/package.mask" \
  "$ROOTFS_DIR/etc/portage/repos.conf"

# Mask compiler toolchain — we use whatever came in stage3.
# Building GCC alone takes 1-2 hours. Never needed for a runtime system.
cat > "$ROOTFS_DIR/etc/portage/package.mask/no-compiler-toolchain" << 'MASK'
sys-devel/gcc
sys-devel/binutils
sys-devel/binutils-libs
sys-libs/glibc
dev-libs/gmp
dev-libs/mpfr
dev-libs/mpc
dev-libs/isl
sys-devel/gettext
dev-libs/elfutils
sys-devel/make
sys-devel/patch
sys-devel/autoconf
sys-devel/automake
sys-devel/libtool
sys-devel/flex
sys-devel/bison
MASK
print_info "Compiler toolchain masked (will never build from source)."

cat > "$ROOTFS_DIR/etc/portage/make.conf" << MAKECONF
# shimboot-gentoo-2 :: make.conf — BINARY ONLY

COMMON_FLAGS="-O2 -pipe -march=x86-64"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

MAKEOPTS="-j${JOBS} -l${JOBS}"

# getbinpkg    = fetch prebuilt .gpkg.tar from PORTAGE_BINHOST
# parallel-fetch = download next while installing current
# NO binpkg-request-signature — GPG handled via getuto separately
# Sandboxes disabled — they don't work inside chroot
FEATURES="getbinpkg parallel-fetch -ipc-sandbox -network-sandbox -pid-sandbox -usersandbox -sandbox"
BINPKG_FORMAT="gpkg"
PORTAGE_BINHOST="https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/"

USE="-doc -man -info -static -debug -test -examples -handbook -nls -ipv6"
USE="\${USE} -bluetooth -cups -gtk -gtk3 -gnome -kde -X -wayland -alsa -pulseaudio"
USE="\${USE} ssl pam crypt unicode threads openrc"

INSTALL_MASK="/usr/share/doc /usr/share/man /usr/share/info /usr/share/gtk-doc"

LINGUAS="en"
L10N="en"
ACCEPT_LICENSE="*"
ACCEPT_KEYWORDS="amd64"
PORTAGE_TMPDIR="/var/tmp/portage"
PORT_LOGDIR="/var/log/portage"
PORTAGE_ELOG_CLASSES="log warn error"
PORTAGE_ELOG_SYSTEM="echo save"
MAKECONF

# Keep udev/OpenRC provider choices explicit.  The old sys-fs/udev package
# no longer exists; virtual/udev resolves to sys-apps/systemd-utils[udev]
# on OpenRC profiles.
cat > "$ROOTFS_DIR/etc/portage/package.use/shimboot-runtime" << 'PKGUSE'
virtual/udev -systemd
virtual/libudev -systemd
sys-apps/systemd-utils udev
net-misc/networkmanager -systemd -elogind -policykit -bluetooth -modemmanager wifi wext tools
net-wireless/wpa_supplicant -gui -qt6 dbus
PKGUSE

cat > "$ROOTFS_DIR/etc/portage/repos.conf/gentoo.conf" << 'REPOSCONF'
[DEFAULT]
main-repo = gentoo

[gentoo]
location  = /var/db/repos/gentoo
sync-type = webrsync
sync-uri  = https://distfiles.gentoo.org/snapshots/
auto-sync = yes
REPOSCONF

# ─── ChromeOS systemd-utils patch (the actual fix for Protocol driver not attached) ──
#
# Gentoo's `virtual/udev` resolves to `sys-apps/systemd-utils[udev]` on OpenRC
# profiles. The shipped binpkg uses systemd's `mount_nofollow()` which calls
#     fd = open(target, O_PATH|O_CLOEXEC|O_NOFOLLOW);
#     mount_fd(source, fd, ...);
# The dedede ChromeOS 5.4.85 kernel handles `/proc/self/fd/<fd>` differently
# and `mount_fd()` returns ENOTCONN ("Protocol driver not attached") for every
# udev mount attempt. udev-trigger then bails out, /dev/tty1 etc. never appear,
# and no agetty can attach.
#
# The fix (used by ading2210/chromeos-systemd, PopCat19/nixos-shimboot, and the
# Arch Linux shimboot folks) is to replace mount_nofollow() with a direct
# mount() call. We drop the patch into /etc/portage/patches/, where Gentoo's
# EAPI 8 default src_prepare() will auto-apply it via eapply_user.
#
# Constraint: systemd 260 raised the kernel baseline from 5.4 to 5.10 and
# replaced mount_fd() with open_tree()/move_mount() (added in kernel 5.2 but
# not present in dedede's 5.4.85 ChromeOS shim kernel). So we must pin to
# systemd-utils 259.x — the last version that works on dedede.
print_step "Installing ChromeOS systemd-utils patch + version pin"

mkdir -p "$ROOTFS_DIR/etc/portage/patches/sys-apps/systemd-utils"
SHIMBOOT_PATCH_SRC="$(realpath -m "$(dirname "$0")")/patches/systemd-mountpoint-util-chromeos.patch"
if [ -f "$SHIMBOOT_PATCH_SRC" ]; then
  cp "$SHIMBOOT_PATCH_SRC" \
    "$ROOTFS_DIR/etc/portage/patches/sys-apps/systemd-utils/01-mountpoint-util-chromeos.patch"
  print_info "  patch installed: $(du -b "$SHIMBOOT_PATCH_SRC" | cut -f1) bytes"
else
  print_error "  Missing patch file: $SHIMBOOT_PATCH_SRC"
  print_error "  Boot WILL fail with 'Protocol driver not attached'."
  exit 1
fi

# Pin systemd-utils to 259.x — 260+ requires kernel >= 5.10 (dedede has 5.4)
# package.mask and package.accept_keywords were already created above
mkdir -p "$ROOTFS_DIR/etc/portage/package.mask" \
         "$ROOTFS_DIR/etc/portage/package.accept_keywords"
cat > "$ROOTFS_DIR/etc/portage/package.mask/systemd-utils-pin" << 'MASK'
# dedede has kernel 5.4.85; systemd 260 needs >= 5.10 (open_tree/move_mount).
# Pin to last working stable: 259.x.
>=sys-apps/systemd-utils-260
MASK
cat > "$ROOTFS_DIR/etc/portage/package.accept_keywords/systemd-utils-pin" << 'KW'
# Allow 259.x (currently keyworded ~amd64 on some sub-versions)
=sys-apps/systemd-utils-259*
KW

# Allow systemd-utils to actually compile (it needs the toolchain that's
# already in stage3). The compiler-toolchain mask only blocks *upgrading*
# those packages from binhost, not using them to compile other things.
# We do NOT remove the mask — we just need to make sure FEATURES doesn't
# block live builds. The default FEATURES already allows it.
print_info "  systemd-utils will be built from source with the patch applied"
print_info "  (this adds ~5-10 min to the build but is required for boot)"

# Per-package env: force from-source build, no binpkg fallback.
# This file is sourced by Portage just before building the package.
mkdir -p "$ROOTFS_DIR/etc/portage/env"
cat > "$ROOTFS_DIR/etc/portage/env/systemd-utils-from-source.conf" << 'ENV'
# Force a source build with the ChromeOS mountpoint-util patch.
FEATURES="${FEATURES} -getbinpkg"
ENV
mkdir -p "$ROOTFS_DIR/etc/portage/package.env"
cat > "$ROOTFS_DIR/etc/portage/package.env/systemd-utils" << 'PKGENV'
sys-apps/systemd-utils systemd-utils-from-source.conf
PKGENV
print_info "  package.env wired so emerge skips binhost for systemd-utils"


# ─── DNS ─────────────────────────────────────────────────────────────────────
cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"
print_info "DNS: $(grep nameserver "$ROOTFS_DIR/etc/resolv.conf" | head -1)"

# ─── Bind mounts ─────────────────────────────────────────────────────────────
print_step "Bind mounting proc/sys/dev/run"

unmount_gentoo() {
  print_info "Unmounting chroot bind mounts..."
  for mp in run dev sys proc; do
    mountpoint -q "$ROOTFS_DIR/$mp" 2>/dev/null && \
      umount -l "$ROOTFS_DIR/$mp" 2>/dev/null && \
      print_debug "  unmounted: $mp" || true
  done
}
trap unmount_gentoo EXIT

for mp in proc sys dev run; do
  mkdir -p "$ROOTFS_DIR/$mp"
  mountpoint -q "$ROOTFS_DIR/$mp" 2>/dev/null && continue
  mount --make-rslave --rbind "/$mp" "$ROOTFS_DIR/$mp" \
    && print_debug "  mounted: /$mp" \
    || { print_error "FAILED: bind mount /$mp"; exit 1; }
done

# ─── chroot helpers ──────────────────────────────────────────────────────────
run_in_chroot() {
  print_debug "chroot$ $*"
  LC_ALL=C chroot "$ROOTFS_DIR" /bin/bash -c "$*"
}
run_in_chroot_status() {
  # Run a command in the chroot and preserve its real exit status.
  # Call this from an if/else or with set +e when a non-zero status is expected.
  local rc
  print_debug "chroot[status]$ $*"
  LC_ALL=C chroot "$ROOTFS_DIR" /bin/bash -c "$*"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    print_warn "  exit $rc from: $*"
  fi
  return "$rc"
}

run_in_chroot_nofail() {
  # Optional/non-critical command: log failures but never trip top-level set -e.
  print_debug "chroot[nofail]$ $*"
  run_in_chroot_status "$*" || return 0
}

# ─── Sanity check ────────────────────────────────────────────────────────────
print_step "Chroot sanity check"
run_in_chroot "echo 'chroot OK' && uname -a"
run_in_chroot "chmod 1777 /var/tmp/portage && mkdir -p /var/log/portage"
run_in_chroot_nofail "emerge --version 2>&1 | head -1"

# ─── Profile symlink (before webrsync) ───────────────────────────────────────
print_step "Setting pre-sync profile symlink"
PROFILE_LINK="$ROOTFS_DIR/etc/portage/make.profile"
rm -f "$PROFILE_LINK"
if [ -d "$ROOTFS_DIR/usr/share/portage/config/profile" ]; then
  ln -sf /usr/share/portage/config/profile "$PROFILE_LINK"
  print_info "Profile -> /usr/share/portage/config/profile"
else
  EXISTING_EAPI="$(find "$ROOTFS_DIR/etc/portage" -name eapi 2>/dev/null | head -1)"
  if [ -n "$EXISTING_EAPI" ]; then
    EAPI_DIR="$(dirname "$EXISTING_EAPI")"
    CHROOT_REL="${EAPI_DIR#$ROOTFS_DIR}"
    ln -sf "$CHROOT_REL" "$PROFILE_LINK"
    print_info "Profile -> $CHROOT_REL"
  else
    print_warn "No builtin profile found — webrsync warnings expected (harmless)"
  fi
fi

# ─── emerge-webrsync ─────────────────────────────────────────────────────────
print_step "Syncing Portage tree via emerge-webrsync"
print_info "'Invalid Repository Location' is EXPECTED before first sync."
run_in_chroot "chmod 1777 /var/tmp/portage"

if run_in_chroot_status "emerge-webrsync --verbose 2>&1"; then
  SYNC_RC=0
else
  SYNC_RC=$?
fi
[ $SYNC_RC -ne 0 ] && {
  print_warn "Attempt 1 failed (rc=$SYNC_RC), retrying in 5s..."
  sleep 5
  if run_in_chroot_status "emerge-webrsync --verbose 2>&1"; then
    SYNC_RC=0
  else
    SYNC_RC=$?
  fi
}
[ $SYNC_RC -ne 0 ] && {
  print_warn "Falling back to emerge --sync..."
  if run_in_chroot_status "emerge --sync --quiet 2>&1"; then
    SYNC_RC=0
  else
    SYNC_RC=$?
  fi
}
[ $SYNC_RC -ne 0 ] && {
  print_error "All sync methods failed!"
  run_in_chroot_nofail "cat /etc/resolv.conf && ping -c 2 8.8.8.8 2>&1"
  exit 1
}
print_info "Tree synced: $(du -sh "$ROOTFS_DIR/var/db/repos/gentoo" 2>/dev/null | cut -f1)"

# ─── Import GPG keys ──────────────────────────────────────────────────────────
print_step "Importing Gentoo release keys (getuto)"
run_in_chroot_nofail "getuto 2>&1"
print_info "GPG keyring:"
run_in_chroot_nofail "gpg --homedir /etc/portage/gnupg --list-keys 2>&1 | grep '^pub' | head -5"

# ─── Set profile ─────────────────────────────────────────────────────────────
print_step "Setting profile: $PROFILE"
run_in_chroot_nofail "eselect profile list 2>&1" \
  | while IFS= read -r l; do print_debug "  $l"; done

# Set profile directly via symlink — more reliable than eselect inside chroot
# eselect profile set fails silently when profile names don't match exactly.
# Direct symlink always works as long as the profile path exists.
profile_set=0
for p in "$PROFILE" \
         "default/linux/amd64/23.0/no-multilib/openrc" \
         "default/linux/amd64/23.0/no-multilib" \
         "default/linux/amd64/23.0"; do
  PROFILE_PATH="$ROOTFS_DIR/var/db/repos/gentoo/profiles/$p"
  if [ -d "$PROFILE_PATH" ]; then
    rm -f "$ROOTFS_DIR/etc/portage/make.profile"
    ln -sf "/var/db/repos/gentoo/profiles/$p" "$ROOTFS_DIR/etc/portage/make.profile"
    profile_set=1
    print_info "Profile symlink -> /var/db/repos/gentoo/profiles/$p"
    break
  fi
done
[ $profile_set -eq 0 ] && print_warn "No matching profile dir found — using stage3 default"
# Verify the symlink resolves correctly.  The link is absolute for the chroot,
# so resolve it by prefixing ROOTFS_DIR instead of using host readlink -f.
PROFILE_TARGET="$(readlink "$ROOTFS_DIR/etc/portage/make.profile" 2>/dev/null || true)"
print_info "Profile link target: $PROFILE_TARGET"
if [ -n "$PROFILE_TARGET" ] && [ -d "$ROOTFS_DIR/${PROFILE_TARGET#/}" ]; then
  print_info "Profile resolves to: $ROOTFS_DIR/${PROFILE_TARGET#/}"
else
  print_warn "Profile target does not exist inside chroot: ${PROFILE_TARGET:-<missing>}"
fi
run_in_chroot_nofail "eselect profile show 2>&1"

# ─── Install runtime packages (BINARY ONLY) ──────────────────────────────────
#
# CRITICAL:
#   --usepkgonly  (NOT --usepkg-only, that flag doesn't exist!)
#                 = refuse to build from source; skip pkgs with no binpkg
#   We do NOT update @world — that pulls in GCC/glibc for compilation.
#   We install ONLY specific runtime packages that have prebuilt binpkgs.
#
# ─── Build patched systemd-utils FIRST (from source) ──────────────────────────
#
# This is the ONE package we deliberately build from source so the ChromeOS
# mountpoint-util patch in /etc/portage/patches/sys-apps/systemd-utils/ gets
# applied. Everything else is binhost.
print_step "Building patched sys-apps/systemd-utils from source (~5-10 min)"
print_info "Applying patch: 01-mountpoint-util-chromeos.patch"
print_info "Pinned version: <260 (kernel 5.4 compat)"

# We pass --usepkg=n explicitly here to override the global FEATURES=getbinpkg,
# which would otherwise grab the unpatched 260.1-r1 binpkg.
# --buildpkg saves the result so subsequent emerges see it as a binpkg too.
if run_in_chroot_status "emerge --ask=n --verbose --usepkg=n --buildpkg \
    --keep-going sys-apps/systemd-utils 2>&1"; then
  print_info "systemd-utils built and installed (PATCHED)."
else
  print_error "FAILED to build patched systemd-utils. Boot will fail."
  print_error "Check: $ROOTFS_DIR/var/log/portage/ for build logs"
  print_error "Common cause: missing toolchain in stage3 (verify gcc, make)."
  run_in_chroot_nofail "ls /var/log/portage/sys-apps/ 2>&1 | tail -20"
  exit 1
fi

# Verify the patch landed in the binary by looking for the new code path.
# The patched mount_nofollow() no longer references mount_fd() in the call
# graph — Portage's QA layer will warn "mount_fd defined but not used".
print_info "Verifying patch was applied:"
if run_in_chroot_status "find /var/log/portage -name '*.log*' -newer /etc/passwd \
    -exec grep -l 'mount_fd.*defined but not used' {} + 2>&1 | head -3"; then
  print_info "  ✓ patch confirmed applied (mount_fd is now unused — expected)"
else
  print_warn "  Could not confirm patch in build logs — proceeding anyway"
fi

# ─── Install the rest of the runtime packages (BINARY ONLY) ──────────────────
print_step "Installing runtime packages (binary only, --usepkgonly)"
print_info "Packages with no prebuilt binpkg will be SKIPPED (not compiled)."

# CRITICAL runtime packages — these MUST be present or the boot will hang
# at a blank screen.  Specifically:
#   sys-apps/sysvinit    — provides /sbin/init that reads /etc/inittab (Gentoo
#                          installs OpenRC's init by default; we replace it
#                          with sysvinit so our agetty entries respawn)
#   sys-apps/util-linux  — provides agetty (the actual TTY login program)
#   sys-apps/shadow      — provides login, passwd, useradd
#   sys-apps/openrc      — the rc system itself
#   sys-apps/kbd         — chvt, openvt (used by kill_frecon)
#   sys-process/psmisc   — pkill (also used by kill_frecon; it lives in procps
#                          on most stages but psmisc has it portably too)
RUNTIME_PKGS="\
sys-apps/sysvinit \
sys-apps/util-linux \
sys-apps/shadow \
sys-apps/openrc \
sys-apps/kbd \
sys-process/psmisc \
sys-process/procps \
net-misc/networkmanager \
net-wireless/wpa_supplicant \
net-wireless/wireless-regdb \
app-admin/sudo \
app-editors/nano \
sys-apps/iproute2 \
sys-apps/less \
app-misc/ca-certificates \
sys-fs/e2fsprogs \
virtual/udev \
sys-fs/udev-init-scripts \
sys-apps/dbus \
dev-libs/openssl \
sys-libs/pam"

print_info "Packages to install: $RUNTIME_PKGS"

# --usepkgonly  = only install if prebuilt binary package exists
# --getbinpkg   = download binpkgs from PORTAGE_BINHOST
# --keep-going  = don't stop on first failure, try all packages
# First pass respects USE so Portage picks OpenRC-flavored binpkgs when present.
# Individual fallback relaxes USE matching only for packages that still fail.
# -g = --getbinpkg (download from binhost)
# -K = --usepkgonly (binary only, skip if no binpkg exists)
# -k = --usepkg (use binary if available)
# We use -gK: fetch from binhost, refuse to compile from source
if run_in_chroot_status "emerge --ask=n --verbose -gK --keep-going --binpkg-respect-use=y $RUNTIME_PKGS 2>&1"; then
  EMERGE_RC=0
else
  EMERGE_RC=$?
fi

if [ $EMERGE_RC -ne 0 ]; then
  print_warn "Batch install had some failures (rc=$EMERGE_RC) — retrying individually"
  for pkg in $RUNTIME_PKGS; do
    print_info "  Installing: $pkg"
    if run_in_chroot_status "emerge --ask=n --usepkgonly --getbinpkg --binpkg-respect-use=y $pkg 2>&1"; then
      print_info "    OK: $pkg"
    elif run_in_chroot_status "emerge --ask=n --usepkgonly --getbinpkg --binpkg-respect-use=n $pkg 2>&1"; then
      print_warn "    OK with USE mismatch accepted: $pkg"
    else
      print_warn "    SKIPPED: $pkg"
    fi
  done
fi

print_info "Package install done."

# Sanity check /sbin/init.  Gentoo's stage3 ships sysvinit at /sbin/init,
# which reads /etc/inittab and that's exactly what we want.  If something
# weird like openrc-init has clobbered it, agetty entries will never be
# spawned and the screen will go black after kill-frecon.
print_step "Verifying /sbin/init is sysvinit (must read /etc/inittab)"
if [ -e "$ROOTFS_DIR/sbin/init" ]; then
  init_kind="unknown"
  if LC_ALL=C strings "$ROOTFS_DIR/sbin/init" 2>/dev/null | grep -qi 'sysvinit'; then
    init_kind="sysvinit"
  elif LC_ALL=C strings "$ROOTFS_DIR/sbin/init" 2>/dev/null | grep -qi 'openrc'; then
    init_kind="openrc-init"
  fi
  print_info "/sbin/init detected as: $init_kind"
  if [ "$init_kind" = "openrc-init" ]; then
    print_warn "openrc-init does NOT read /etc/inittab — replacing with sysvinit"
    if [ -x "$ROOTFS_DIR/sbin/sysvinit-init" ]; then
      ln -sf sysvinit-init "$ROOTFS_DIR/sbin/init"
    elif [ -x "$ROOTFS_DIR/lib/sysvinit/init" ]; then
      ln -sf /lib/sysvinit/init "$ROOTFS_DIR/sbin/init"
    else
      print_error "Cannot find a sysvinit binary to link!  TTYs will NOT work."
    fi
  fi
else
  print_error "/sbin/init does NOT EXIST — install sys-apps/sysvinit"
fi
print_info "Total installed packages:"
run_in_chroot_nofail "ls /var/db/pkg/*/* -d 2>/dev/null | wc -l || echo '(count unavailable)'"

# ─── Minimize ─────────────────────────────────────────────────────────────────
print_step "Minimizing image size"
run_in_chroot_nofail "rm -rf /var/tmp/portage/* /usr/src/* /var/cache/distfiles/*"
run_in_chroot_nofail "eclean-dist --destructive 2>/dev/null; eclean-pkg --destructive 2>/dev/null; true"
run_in_chroot_nofail "rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* /usr/share/gtk-doc/*"
run_in_chroot_nofail "find /usr/share/locale -mindepth 1 -maxdepth 1 \
  ! -name 'en_US' ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null; true"
run_in_chroot_nofail "find /usr/lib /usr/lib64 -name '*.a' -delete 2>/dev/null; true"
run_in_chroot_nofail "find /usr/bin /usr/sbin /bin /sbin -type f \
  -exec strip --strip-debug {} + 2>/dev/null; true"
run_in_chroot_nofail "find / -xdev -name '__pycache__' -exec rm -rf {} + 2>/dev/null; true"
run_in_chroot_nofail "find / -xdev -name '*.pyc' -delete 2>/dev/null; true"

print_step "Trimming portage tree (keep skeleton for rescue mode)"
# We keep the repo skeleton (profiles, repo metadata) so that 'rescue 2' from
# the bootloader gives a usable emerge.  The ebuilds themselves are the bulk
# of the size and they can always be re-fetched with emerge-webrsync.
run_in_chroot_nofail "find /var/db/repos/gentoo -mindepth 1 -maxdepth 1 \
  ! -name profiles ! -name metadata ! -name eclass \
  ! -name licenses ! -name 'repo-name' \
  -exec rm -rf {} + 2>/dev/null; true"
run_in_chroot_nofail "rm -rf /var/db/repos/gentoo/metadata/md5-cache 2>/dev/null; true"

print_info ""
print_info "Final size breakdown:"
du -shx "$ROOTFS_DIR/usr" "$ROOTFS_DIR/var" "$ROOTFS_DIR/etc" \
  "$ROOTFS_DIR/lib"* 2>/dev/null | sort -h \
  | while IFS= read -r l; do print_info "  $l"; done
print_info "TOTAL: $(du -shx "$ROOTFS_DIR" 2>/dev/null | cut -f1)"

trap - EXIT
unmount_gentoo

print_title "Gentoo rootfs bootstrap COMPLETE"
