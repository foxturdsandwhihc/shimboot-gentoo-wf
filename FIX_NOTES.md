# shimboot-gentoo-2 — Option 2 fix: patched systemd-utils

## TL;DR

The boot was hanging at a black screen because every `udev` operation hit
"Protocol driver not attached". Root cause: Gentoo's `virtual/udev` resolves
to `sys-apps/systemd-utils[udev]`, which uses systemd's `mount_nofollow()`:

```c
fd = open(target, O_PATH|O_CLOEXEC|O_NOFOLLOW);
return mount_fd(source, fd, ...);
```

The dedede ChromeOS 5.4.85 kernel handles `/proc/self/fd/<fd>` differently
and `mount_fd()` fails with `ENOTCONN`. Without working udev, `/dev/tty1`
never appears, agetty has nothing to attach to, and the screen stays black
after `kill-frecon`.

The fix (used by ading2210/chromeos-systemd, PopCat19/nixos-shimboot, the
Arch shimboot folks): **patch `mount_nofollow()` to call `mount()` directly**.

This repo now does that. The patch is auto-applied by Portage at build time
via `/etc/portage/patches/sys-apps/systemd-utils/`.

## What changed

### New files

* `patches/systemd-mountpoint-util-chromeos.patch` — the actual code patch.
  Identical to the one in `PopCat19/nixos-shimboot`, originally derived from
  `ading2210/chromeos-systemd`. Replaces `mount_nofollow()`'s
  `open() + mount_fd()` with `mount(source, target, ...)`.

### Modified files

* `build_rootfs_gentoo.sh`:
  * Drops the patch into `/etc/portage/patches/sys-apps/systemd-utils/`
    inside the chroot. EAPI 8's default `src_prepare()` calls `eapply_user`
    so the patch gets applied automatically every time `systemd-utils` is
    built from source.
  * Adds `>=sys-apps/systemd-utils-260` to `package.mask`. Systemd 260
    raised the kernel baseline to 5.10 and replaced `mount_fd()` with
    `open_tree()`/`move_mount()` — neither is in dedede's 5.4.85 kernel,
    so 260+ won't work even with the patch. We pin to 259.x.
  * Allows `=sys-apps/systemd-utils-259*` via `package.accept_keywords`
    (some sub-versions are `~amd64` keyworded).
  * Adds a per-package env wiring (`/etc/portage/env/` +
    `/etc/portage/package.env/`) that strips `getbinpkg` from FEATURES for
    `systemd-utils` only, forcing a from-source build (so the patch
    actually runs).
  * Adds a dedicated build pass `emerge --usepkg=n --buildpkg
    sys-apps/systemd-utils` *before* the main runtime-package install
    loop. The result is cached as a binpkg too, so the subsequent
    `RUNTIME_PKGS` pass that hits `virtual/udev` just consumes it.
  * Greps the build log for the `mount_fd defined but not used` warning
    as a quick sanity check that the patch actually landed in the binary.

* `rootfs/opt/setup_rootfs_gentoo.sh`:
  * **Re-enables** `udev`, `udev-trigger`, `udev-settle` in the `sysinit`
    runlevel. They were disabled in the previous turn as a workaround for
    the underlying systemd bug; with the patch they will succeed and
    `/dev/tty*` nodes will be created normally.
  * Everything else from the previous turn (sysvinit-format `/etc/inittab`
    with `agetty` on tty1..tty6, autologin root on tty1, `securetty`
    update, `kill-frecon` OpenRC service in `boot` runlevel) is unchanged.

* `rootfs/usr/local/bin/kill_frecon`: unchanged from previous turn.

## How to build

Full rebuild (recommended, ~10-15 min on a fast box, ~5 of which is the
new systemd-utils source build):

```bash
cd /home/user/shimboot-gentoo-2
sudo ./build_complete.sh dedede \
    distro=gentoo \
    hostname=shimboot-gentoo \
    username=user \
    user_passwd=shimboot \
    enable_root=1
```

If you already have a cached rootfs and want to re-do *just* the
systemd-utils build + setup pass, you can re-run the in-chroot setup
script after manually emerging the patched systemd-utils:

```bash
R=/path/to/cached/rootfs
# Drop the patch + portage config into the existing rootfs
sudo mkdir -p $R/etc/portage/patches/sys-apps/systemd-utils
sudo cp patches/systemd-mountpoint-util-chromeos.patch \
    $R/etc/portage/patches/sys-apps/systemd-utils/01-mountpoint-util-chromeos.patch
sudo bash -c "cat > $R/etc/portage/package.mask/systemd-utils-pin <<'EOF'
>=sys-apps/systemd-utils-260
EOF"
sudo bash -c "cat > $R/etc/portage/package.accept_keywords/systemd-utils-pin <<'EOF'
=sys-apps/systemd-utils-259*
EOF"

# Bind-mount and chroot to rebuild systemd-utils
sudo mount --rbind /proc $R/proc
sudo mount --rbind /sys  $R/sys
sudo mount --rbind /dev  $R/dev
sudo chroot $R emerge --ask=n --verbose --usepkg=n --buildpkg \
    --keep-going sys-apps/systemd-utils

# Re-run the setup script to (re-)enable udev services
sudo cp rootfs/opt/setup_rootfs_gentoo.sh $R/opt/
sudo chmod +x $R/opt/setup_rootfs_gentoo.sh
sudo chroot $R /opt/setup_rootfs_gentoo.sh \
    '' gentoo '' shimboot-gentoo '' user shimboot 1 '' amd64

sudo umount -l $R/proc $R/sys $R/dev

# Re-pack the image
sudo ./build.sh out/shimboot_dedede.bin path/to/dedede.bin $R
```

## Verifying the patch actually applied

After build, in the chroot or on the running system:

```bash
# 1. Check the version
emerge --info sys-apps/systemd-utils | grep ^"sys-apps/systemd-utils"
# Expected: 259.x (NOT 260.x)

# 2. Check the patch left its fingerprint in the build log
grep -r 'mount_fd.*defined but not used' /var/log/portage/sys-apps/
# Expected: a hit (mount_fd() is now unused because mount_nofollow()
# was rewritten to call mount() directly)

# 3. Confirm by symbol comparison: the patched binary should NOT
#    reference open(O_PATH) inside mount_nofollow:
strings /usr/lib/systemd/systemd-udevd | grep -c "mount_fd\|O_PATH"
# Both pre- and post- patch will have the strings (they appear in other
# code paths) — this isn't a definitive check. The build-log grep above
# is the reliable check.
```

## What you should see on next boot

```
* Mounting /run ...                                   [ ok ]
...
* Starting udev ...                                   [ ok ]
* Generating a rule to create a /dev/root symlink ... [ ok ]
* Populating /dev with existing devices through uevents ... [ ok ]
                                                      [ ok ]   ← was [ !! ] before
* udev-trigger started successfully                   ← previously failed
...
* Killing frecon-lite (free framebuffer for getty/Xorg) ... [ ok ]
...

shimboot-gentoo login: root (automatic login on tty1)
[shimboot greeter banner]
shimboot-gentoo ~ #
```

* `Ctrl+Alt+F2`..`F6` → fresh login prompts on tty2..tty6.

## If it STILL hangs at a black screen

Use the bootloader's `rescue 2` (rescue mode for OS #2) and check the build
result inside the rootfs:

```bash
# Check version actually installed
emerge --info sys-apps/systemd-utils 2>&1 | head -20

# Check that the patch applied in the build log
ls -la /var/log/portage/sys-apps/systemd-utils*/
zgrep -i "mount_fd.*unused\|patching file.*mountpoint-util" \
    /var/log/portage/sys-apps/systemd-utils*/*.log* 2>/dev/null | head -5

# Manually invoke udev-trigger to see the live error
udevadm trigger --type=devices --action=add 2>&1 | head -20
udevadm settle 2>&1 | head -20
ls -la /dev/tty1 /dev/fb0
```

If `udev-trigger` still says "Protocol driver not attached", the patch did
not get into the installed binary. Most likely cause: the binhost binpkg got
installed instead of a from-source build. Force a rebuild:

```bash
emerge --ask=n --usepkg=n --buildpkg --oneshot sys-apps/systemd-utils
```

then reboot.

## References

* ading2210/chromeos-systemd — original patch + Debian build pipeline
  https://github.com/ading2210/chromeos-systemd
* PopCat19/nixos-shimboot — same patch, NixOS deployment, same kernel constraint
  https://github.com/PopCat19/nixos-shimboot
* shimboot#405 — full discussion of the kernel-baseline / patch story
  https://github.com/ading2210/shimboot/issues/405
