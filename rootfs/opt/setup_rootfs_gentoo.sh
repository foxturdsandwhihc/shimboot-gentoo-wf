#!/bin/bash
#
# setup_rootfs_gentoo.sh
# Runs INSIDE the Gentoo chroot to finalize the system.
#
# shimboot-gentoo-2: clean rewrite focused on actually getting a TTY login
# prompt after the shim's bootloader pivots into us.

DEBUG="$1"
set -e
[ "$DEBUG" ] && set -x

RELEASE_NAME="$2"
PACKAGES="$3"
HOSTNAME="$4"
ROOT_PASSWD="$5"
USERNAME="$6"
USER_PASSWD="$7"
ENABLE_ROOT="$8"
DISABLE_BASE_PKGS="$9"
ARCH="${10}"

_log()  { printf '\033[1m[SETUP] %s\033[0m\n' "$*"; }
_warn() { printf '\033[1;33m[WARN]  %s\033[0m\n' "$*" >&2; }
_err()  { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; }
_dbg()  { [ "$DEBUG" ] && printf '\033[1;36m[DBG]   %s\033[0m\n' "$*"; return 0; }
_step() { printf '\n\033[1;32m  ---> %s\033[0m\n' "$*"; }

_log "shimboot-gentoo-2 :: in-chroot Gentoo setup"
_log "  hostname : ${HOSTNAME:-<prompt>} | username : ${USERNAME:-<prompt>} | arch : $ARCH"

# Hostname
_step "Hostname"
[ -z "$HOSTNAME" ] && read -rp "hostname: " HOSTNAME
echo "${HOSTNAME}" > /etc/hostname

cat > /etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME}
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF
mkdir -p /etc/conf.d
echo "hostname=\"${HOSTNAME}\"" > /etc/conf.d/hostname

# Timezone & locale
_step "Timezone (UTC) + locale (en_US.UTF-8)"
ln -sf /usr/share/zoneinfo/UTC /etc/localtime || true
echo "UTC" > /etc/timezone || true
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen 2>&1 | while IFS= read -r l; do _dbg "locale-gen: $l"; done || _warn "locale-gen failed"
eselect locale set "en_US.utf8" 2>/dev/null || true
echo 'LANG="en_US.UTF-8"' > /etc/env.d/02locale
env-update 2>&1 | while IFS= read -r l; do _dbg "env: $l"; done || true

# Keymap
cat > /etc/conf.d/keymaps <<'EOF'
keymap="us"
windowkeys="NO"
extended_keymaps=""
dumpkeys_charset=""
fix_euro="NO"
EOF

# OpenRC services
_step "Enabling OpenRC services"

_enable_svc() {
  local svc="$1" runlevel="${2:-default}"
  if [ ! -e "/etc/init.d/$svc" ]; then
    _warn "  service missing, skip: $svc"; return 0
  fi
  if rc-update show 2>/dev/null | awk '{print $1}' | grep -qx "$svc"; then
    _dbg "already enabled: $svc"; return 0
  fi
  if rc-update add "$svc" "$runlevel" 2>/dev/null; then
    _log "  enabled: $svc @ $runlevel"
  else
    _warn "  failed to enable: $svc"
  fi
}

# CRITICAL ON SHIMBOOT-GENTOO:
# udev/udev-trigger/udev-settle work IF and ONLY IF systemd-utils was built
# with the ChromeOS mountpoint-util patch (see build_rootfs_gentoo.sh →
# /etc/portage/patches/sys-apps/systemd-utils/01-mountpoint-util-chromeos.patch).
# Without that patch they fail with "Protocol driver not attached" on the
# dedede 5.4.85 kernel and /dev/tty1 is never created → no agetty → blank
# screen.  We assume the patched build was successful (build_rootfs_gentoo.sh
# aborts otherwise) and enable the full udev stack.
_enable_svc sysfs         sysinit
_enable_svc devfs         sysinit
_enable_svc dmesg         sysinit
_enable_svc udev          sysinit
_enable_svc udev-trigger  sysinit
_enable_svc udev-settle   sysinit

_enable_svc hostname     boot
_enable_svc bootmisc     boot
_enable_svc modules      boot
_enable_svc hwclock      boot
_enable_svc syslog       boot
_enable_svc loopback     boot
_enable_svc procfs       boot
_enable_svc binfmt       boot
_enable_svc localmount   boot
_enable_svc fsck         boot
_enable_svc root         boot
_enable_svc swap         boot
_enable_svc swclock      boot
_enable_svc termencoding boot

_enable_svc dbus           default
_enable_svc NetworkManager default
_enable_svc wpa_supplicant default
_enable_svc crond          default
_enable_svc local          default

rc-update show 2>&1 | while IFS= read -r l; do _dbg "  $l"; done

# kill-frecon OpenRC service
_step "Installing kill-frecon OpenRC service"
cat > /etc/init.d/kill-frecon <<'SVC'
#!/sbin/openrc-run
description="Kill frecon-lite so kernel framebuffer / gettys can claim the console"

depend() {
  after  dmesg sysfs devfs
  before bootmisc localmount
  keyword -shutdown
}

start() {
  ebegin "Killing frecon-lite (free framebuffer for getty/Xorg)"
  if [ -x /usr/local/bin/kill_frecon ]; then
    /usr/local/bin/kill_frecon
  else
    umount -l /dev/console 2>/dev/null || true
    pkill -TERM frecon-lite 2>/dev/null || true
    sleep 1
    pkill -KILL frecon-lite 2>/dev/null || true
  fi
  eend 0
}

stop() { return 0; }
SVC
chmod +x /etc/init.d/kill-frecon
_enable_svc kill-frecon boot

# /etc/inittab — THE fix for the blank screen
_step "Writing /etc/inittab (gettys on tty1..tty6)"

AUTOLOGIN_TTY1="${AUTOLOGIN_TTY1---autologin root}"

cat > /etc/inittab <<INITTAB
# /etc/inittab -- shimboot-gentoo-2

id:3:initdefault:

si::sysinit:/sbin/openrc sysinit
rc::bootwait:/sbin/openrc boot

l0:0:wait:/sbin/openrc shutdown
l0s:0:wait:/sbin/halt -dhnp
l1:S1:wait:/sbin/openrc single
l2:2:wait:/sbin/openrc nonetwork
l3:3:wait:/sbin/openrc default
l4:4:wait:/sbin/openrc default
l5:5:wait:/sbin/openrc default
l6:6:wait:/sbin/openrc reboot
l6r:6:wait:/sbin/reboot -dkn

su0:S:wait:/sbin/openrc single
su1:S:wait:/sbin/sulogin

ca:12345:ctrlaltdel:/sbin/shutdown -r now "Ctrl-Alt-Del pressed"
pf::powerwait:/sbin/halt -p
pn::powerfailnow:/sbin/halt --powerfail
po::powerokwait:/sbin/openrc shutdown

# Virtual consoles -- Ctrl+Alt+F1..F6 to switch.
c1:2345:respawn:/sbin/agetty ${AUTOLOGIN_TTY1} --noclear --keep-baud 38400 tty1 linux
c2:2345:respawn:/sbin/agetty --noclear --keep-baud 38400 tty2 linux
c3:2345:respawn:/sbin/agetty --noclear --keep-baud 38400 tty3 linux
c4:2345:respawn:/sbin/agetty --noclear --keep-baud 38400 tty4 linux
c5:2345:respawn:/sbin/agetty --noclear --keep-baud 38400 tty5 linux
c6:2345:respawn:/sbin/agetty --noclear --keep-baud 38400 tty6 linux

#s0:2345:respawn:/sbin/agetty -L 115200 ttyS0 vt100
INITTAB
_log "/etc/inittab installed (autologin tty1 = ${AUTOLOGIN_TTY1:-disabled})"

# securetty
_step "Updating /etc/securetty for tty1..tty6"
{
  echo "# shimboot-gentoo-2"
  echo "console"
  for n in 1 2 3 4 5 6; do echo "tty$n"; done
  [ -f /etc/securetty ] && grep -vE '^(console|tty[1-6]|#)' /etc/securetty 2>/dev/null || true
} > /etc/securetty.new
mv /etc/securetty.new /etc/securetty
chmod 0600 /etc/securetty

# agetty must exist
if ! command -v agetty >/dev/null 2>&1; then
  _warn "agetty missing -- installing sys-apps/util-linux from binhost"
  emerge --ask=n -q --getbinpkg --usepkgonly sys-apps/util-linux 2>&1 | \
    while IFS= read -r l; do _dbg "emerge: $l"; done || \
    _err "FAILED to install util-linux -- TTYs will NOT work!"
fi
command -v agetty >/dev/null 2>&1 && _log "agetty: $(command -v agetty)" || \
  _err "agetty STILL missing -- boot will hang at blank screen"

# zram swap
_step "zram swap"
mkdir -p /etc/conf.d
if [ -f /etc/init.d/zram-init ]; then
  cat > /etc/conf.d/zram-init <<'ZRAM'
load_on_start=yes
unload_on_stop=yes
num_devices=1
type0=swap
flag0=
size0=`LC_ALL=C free -m | awk '/^Mem:/{print int($2/2)}'`
maxs0=1
algo0=lzo
labl0=zram_swap
ulink0=
notrim0=
mlim0=
ZRAM
  _enable_svc zram-init boot
elif [ -f /etc/init.d/zram ]; then
  _enable_svc zram boot
else
  _warn "no zram service available"
fi

# NetworkManager
_step "NetworkManager"
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/any-user.conf <<'NM'
[main]
auth-polkit=false
NM
cat > /etc/NetworkManager/conf.d/wifi.conf <<'WIFI'
[device]
wifi.backend=wpa_supplicant
WIFI

# sudo
_step "sudo (wheel)"
mkdir -p /etc/sudoers.d
cat > /etc/sudoers.d/00-wheel <<'S'
%wheel ALL=(ALL:ALL) ALL
Defaults !requiretty
S
chmod 0440 /etc/sudoers.d/00-wheel

# Extra packages
if [ -n "$PACKAGES" ] && [ -z "$DISABLE_BASE_PKGS" ]; then
  _step "Extra packages: $PACKAGES"
  emerge --ask=n --getbinpkg --usepkgonly --keep-going $PACKAGES 2>&1 | \
    while IFS= read -r l; do _dbg "emerge: $l"; done || \
    _warn "some extra packages failed"
fi

# User account
_step "User account"
[ -z "$USERNAME" ] && read -rp "username: " USERNAME

USER_GROUPS="wheel audio video usb plugdev netdev users"
for g in $USER_GROUPS; do
  getent group "$g" >/dev/null 2>&1 || groupadd -r "$g" 2>/dev/null || true
done
USER_GROUP_CSV="$(printf '%s' "$USER_GROUPS" | tr ' ' ',')"

if id "$USERNAME" >/dev/null 2>&1; then
  usermod -aG "$USER_GROUP_CSV" "$USERNAME" || _warn "usermod failed"
else
  useradd -m -s /bin/bash -G "$USER_GROUP_CSV" "$USERNAME" || \
    { _err "useradd failed for $USERNAME"; exit 1; }
fi

_set_password() {
  local user="$1" password="$2"
  if [ -z "$password" ]; then
    while ! passwd "$user"; do _warn "passwd retry for $user"; done
  else
    echo "${user}:${password}" | chpasswd 2>/dev/null && return 0
    yes "$password" | passwd "$user" >/dev/null 2>&1 || _err "passwd failed for $user"
  fi
}

if [ "$ENABLE_ROOT" ]; then
  _step "Enabling root login"
  passwd -u root 2>/dev/null || true
  _set_password root "$ROOT_PASSWD"
else
  _step "Locking root account"
  passwd -l root 2>/dev/null || _warn "could not lock root"
fi

_step "User password"
_set_password "$USERNAME" "$USER_PASSWD"

# Greeter
_step "Installing greeter into root + user .bashrc"
for home in /root "/home/$USERNAME"; do
  [ -d "$home" ] || continue
  touch "$home/.bashrc"
  if ! grep -q '/usr/local/bin/shimboot_greeter' "$home/.bashrc" 2>/dev/null; then
    {
      echo ""
      echo "# shimboot greeter"
      echo "[ -t 0 ] && [ -x /usr/local/bin/shimboot_greeter ] && /usr/local/bin/shimboot_greeter"
    } >> "$home/.bashrc"
    _log "greeter -> $home/.bashrc"
  fi
done
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME" 2>/dev/null || true
touch /etc/shimboot-firstboot

# Cleanup
_step "Cleanup"
rm -rf /var/tmp/portage/* /var/cache/distfiles/* /var/cache/binpkg/* 2>/dev/null || true
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* /usr/share/gtk-doc/* 2>/dev/null || true
find /usr/share/locale -mindepth 1 -maxdepth 1 -not -name 'en_US' \
  -not -name 'locale.alias' -exec rm -rf {} + 2>/dev/null || true
find /usr/bin /usr/sbin /bin /sbin -type f -exec strip --strip-debug {} + 2>/dev/null || true
find /usr/lib /usr/lib64 -name '*.a' -delete 2>/dev/null || true
find / -xdev -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find / -xdev -name '*.pyc' -delete 2>/dev/null || true

_log ""
_log "Gentoo in-chroot setup COMPLETE"
_log "  user        : $USERNAME"
_log "  hostname    : $HOSTNAME"
_log "  root login  : $([ -n "$ENABLE_ROOT" ] && echo enabled || echo locked)"
_log "  TTYs        : agetty on tty1..tty6 (autologin tty1 = ${AUTOLOGIN_TTY1:-no})"
_log "  framebuffer : kill-frecon runs in 'boot' runlevel before gettys"
