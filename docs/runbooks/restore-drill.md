# Runbook: restore drill

**An unverified backup is a hope, not a backup.** ADR-006 says recovery here is restore-based rather
than failover-based — which is only a claim until it's been timed.

Run this quarterly, and after any change to the backup setup.

---

## ⚠️ Before you start

**A restored guest comes back with the same static IP as the original.** The address lives in netplan
inside the disk; cloud-init won't help, because it's first-boot only and the guest has already
booted.

So: restore to a **temporary VMID**, keep the **NIC disconnected**, and verify through the host.
Never restore over the original.

## Procedure

**1. Pre-flight**

```bash
ssh root@192.168.0.11
pvesm status                              # free space on local-zfs
qm list; pct list                         # confirm 999 is unused
pvesm list pbs-local | grep 'vm/<id>/'    # available snapshots
```

**2. Restore — start the timer**

```bash
date
qmrestore pbs-local:backup/vm/<id>/<timestamp> 999 \
  --storage local-zfs \
  --unique 1
```

`qmrestore` does **not** auto-start. `--unique 1` generates a fresh MAC so it can't collide at
layer 2.

**3. Disconnect the NIC before booting**

```bash
qm config 999 | grep net0
qm set 999 --net0 <that-value>,link_down=1
qm config 999 | grep net0        # CONFIRM link_down=1 is present
qm start 999
```

**4. Verify the data from the host** — more reliable than logging in

```bash
qm stop 999
zfs list -t volume | grep 999
partprobe /dev/zvol/rpool/data/vm-999-disk-0
mkdir -p /mnt/restore-test
mount -o ro /dev/zvol/rpool/data/vm-999-disk-0-part1 /mnt/restore-test
```

`-part1` is root on Ubuntu cloud images. Mount **read-only**.

```bash
cat /mnt/restore-test/etc/hostname
ls -la /mnt/restore-test/home/ubuntu/stacks/<stack>/
ls    /mnt/restore-test/home/ubuntu/stacks/<stack>/config/
ls    /mnt/restore-test/etc/systemd/system/ | grep <unit>
```

Check **file dates match what you expect** — it proves you restored the snapshot you meant to.

**5. Clean up**

```bash
umount /mnt/restore-test && rmdir /mnt/restore-test
qm destroy 999 --purge
qm list
```

**6. Log it below.** If anything failed, fixing it is this week's top task.

---

## Known gap: you can't log into a restored guest

Cloud-init sets **no password** on `ubuntu`, and `common` sets `PasswordAuthentication no`. A
restored guest with broken networking has no SSH and no usable console login.

Recovery if you need a shell (BIOS boot, so this is the generic locked-out procedure):

1. `qm reset 999`, console already open and focused
2. **Esc** repeatedly → SeaBIOS boot menu → **`1`** for the virtio disk
3. Hold **Shift** immediately → GRUB menu *(noVNC often swallows modifiers — expect to retry)*
4. Highlight *Ubuntu*, press **`e`**
5. Append ` init=/bin/bash` to the `linux /boot/vmlinuz…` line
6. **Ctrl+X**, then:
   ```bash
   mount -o remount,rw /
   passwd ubuntu
   sync
   ```
7. `qm reset 999` from the host, log in with the new password

⬜ Worth fixing properly: a console password via cloud-init on future VMs, or a rescue ISO kept on
`local`.

---

## Drill log

| Date | Restored | Restore time | Total | Result |
|---|---|---|---|---|
| 2026-08-11 | media-vm (122), 60 GB, snapshot `2026-08-10T20:47:22Z` | **12m 11s** | **25m 07s** | ✅ Pass |

### 2026-08-11 — notes

**Verified:** all six *arr config directories present (bazarr, jellyseerr, prowlarr, qbittorrent,
radarr, sonarr) · `.env` intact with mode `0600` and owner preserved · `qbit-watchdog.service` and
`.timer` restored · file mtimes matched the expected snapshot.

**Faster than expected.** I'd assumed the USB 2.0-attached backup pool would bottleneck at ~40 MB/s
and take 25+ minutes. PBS only transfers the chunks it needs, so 60 GB restored in 12 minutes.

**Not tested:**
- That services actually **start** — no network by design
- **family-vm**, whose backups are ~900 GB because they include the 800 GB Immich disk. A very
  different proposition and the one that matters most. ⬜ Test separately.
- **Cross-node restore** (restoring a k8plus guest onto g11)
- **Off-site restore** — there is no off-site copy; see the deferral in Project Memory

**Found:** the no-console-login gap above. Nothing failed, but that's the thing to fix.
