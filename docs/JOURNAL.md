# 🛠️ Homelab Build Journal

This is my running log of building the homelab — every command, every thing that
broke, and the fix that actually worked. It's written for future-me: when something
breaks again at 1am, I want to **Ctrl-F the error** ("401", "no route to host",
"NO-CARRIER") and jump straight to what solved it last time.

**How to read this**
- Newest session is at the top.
- Each session: what I set out to do, the exact commands, what went wrong, and how I
  fixed it.
- The 🔥 **Gotchas index** at the very bottom is the fast lookup for "this happened again."

> Public copy — my real domains are redacted to `your-domain.example` /
> `your-mail.example`. The un-redacted version lives in my private notes repo.

**Fleet quick reference**

| Node | IP | Role | Status |
|---|---|---|---|
| k8plus | 192.168.0.11 | family-prod (Jellyfin, Nextcloud, **Immich**, media, PBS) | 🟢 live · clustered |
| g11 | 192.168.0.12 | core-infra (**DNS, proxy, monitoring, GitLab** — done) | 🟢 live · clustered |
| macbook | 192.168.0.13 | lab (disposable K3s node — coming) | 🟢 live · clustered |
| Z13 (control) | 192.168.0.239 (DHCP) | Ansible control node (WSL) | 🟢 |
| VMs | family-vm .21 · media-vm .22 · **runner-vm .25** · monitor-vm .31 · gitlab-vm .32 | Docker hosts | 🟢 live |

- **LAN / subnet:** 192.168.0.0/24, gateway 192.168.0.1
- **Switch:** **MikroTik CRS310-8G+2S+** (RouterOS, managed) in place → VLAN segmentation in progress (JetKVM out-of-band console on k8plus)
- **Web:** your-domain.example (Cloudflare Tunnel) · **Email:** Proton Mail on your-mail.example
- **Cluster:** 3-node Proxmox VE 9, quorate (survives losing any one node)
- **Repo:** homelab-infra (public) ← the whole build as code

---

## Session 12 — 2026-07-31 · First CI pipeline (and the DNS layer I forgot about)

**Goal:** a work-day session, remote over Tailscale — get a first `.gitlab-ci.yml` running on
the self-hosted runner.

**Outcome:** ✅ Pipeline #1 green after one fix. The runner, tag matching, docker executor and
internal DNS resolution are all proven end to end. Real lint jobs next.

### What I did

1. **Decided the CI split.** GitHub Actions (`.github/workflows/validate.yml`) already runs
   `terraform fmt`, yamllint, shellcheck and an Ansible syntax check — it stays as the public
   smoke test and green badge. **GitLab CI does the deeper work that benefits from being on the
   LAN**: `ansible-lint`, `tflint`, `terraform validate`, and eventually `--check` dry-runs
   against real hosts. Two CI systems checking identical things would just drift apart.
2. **Wrote the smallest possible pipeline first** — one `hello` job on `alpine:3.20` that echoes
   and runs `ls -la`. Deliberately useless: the point was to prove GitLab → runner → container →
   result works before adding anything that could fail for its own reasons. Debugging one trivial
   job is far easier than debugging four real ones at once.
3. **Fixed container DNS on runner-vm** (below), then pipeline #1 passed.

### Errors & fixes 🔥

**Pipeline #1 failed before `script:` ever ran — `Could not resolve host: git.lab`.**

```
Initialized empty Git repository in /builds/jchoo/homelab-infra/.git/
fatal: unable to access 'http://git.lab/jchoo/homelab-infra.git/': Could not resolve host: git.lab
ERROR: Job failed: exit code 128
```

Two things worth extracting from this.

**First: every job silently clones the repo before your `script:` runs.** A fresh container has
nothing in it, so the runner fetches the code first. If that fetch fails the job dies before your
own commands get a turn — which is why the `echo` never appeared in the log.

**Second, and the real lesson: runner-vm could resolve `git.lab`, but containers running on it
could not.** Those are two different network contexts and they do **not** share a resolver:

```
runner-vm            ← own /etc/resolv.conf, reaches AdGuard fine
  └── job container  ← gets DNS from the Docker daemon, not from the VM
```

Cause: Ubuntu cloud images run **systemd-resolved**, so `/etc/resolv.conf` contains the loopback
stub `nameserver 127.0.0.53`. The VM is fine — it asks the local stub, which forwards upstream.
But when Docker builds a container's resolv.conf it **strips loopback addresses** (inside a
container, `127.0.0.53` means the container itself, which runs no resolver), finds nothing left,
and falls back to a hardcoded public default — usually `8.8.8.8`. Google has never heard of
`git.lab`.

Reproduce the whole bug in two lines on the same machine:

```bash
getent hosts git.lab                                 # works
docker run --rm alpine:3.20 getent hosts git.lab     # fails
docker run --rm alpine:3.20 cat /etc/resolv.conf     # shows 8.8.8.8
```

Fix — give the Docker **daemon** an explicit resolver, so every container inherits it:

```json
// /etc/docker/daemon.json
{ "dns": ["192.168.0.31", "1.1.1.1"] }
```

```bash
python3 -m json.tool /etc/docker/daemon.json   # VALIDATE FIRST — bad JSON = Docker won't start
sudo systemctl restart docker
docker run --rm alpine:3.20 getent hosts git.lab
```

AdGuard first (it holds the `*.lab` rewrites), `1.1.1.1` as the public fallback.

**Why this fix and not the alternative:** I could have pointed the runner's clone URL at
`http://192.168.0.32:8929` and skipped DNS entirely. That fixes *this* symptom only — the next
job that needs `grafana.lab` breaks again. Fixing the daemon fixes the whole class, once.

Note the layering: yesterday's Terraform `dns{}` change fixes the **VM's** resolver via cloud-init.
This fixes the **container's** resolver via the Docker daemon. **Fixing one does not fix the other**,
and both were needed.

**`nano /etc/docker/daemon.json` → "Permission denied" only when saving.** `/etc` is root-owned;
nano lets you type and then refuses at write time. `sudo nano …`. (For longer files: at the
Ctrl+O prompt, change the target to `/tmp/…`, save there, then `sudo cp` it into place.)

### ansible-lint: 46 findings → 0, at the `production` profile

Added the job with `allow_failure: true` so findings could be triaged instead of blocking. Sorted
them into *real bugs*, *style I agree with*, and *style I don't* — the last silenced deliberately in
a committed config with the reasoning in a comment. A linter you've muted **on purpose**, visibly,
beats one you ignore or one that nags you into worse code.

**Two genuine bugs surfaced.**

**1. `requirements.yml` was incomplete** — `syntax-check` couldn't resolve
`ansible.posix.authorized_key`. It works on my control node because the full `ansible` pip package
bundles hundreds of collections; the repo only declared `community.docker`. Anyone cloning and
following the README would have failed. A reproducibility bug, caught on the first clean-machine
run — precisely what CI is for. (CI itself also needs
`ansible-galaxy collection install -r ansible/requirements.yml`; `pip install ansible-lint` only
brings `ansible-core`, the engine, with no collections.)

**2. The tailscale `when:` guard had never worked.** The best find of the day:

```yaml
when: ts_status.rc != 0 or '"NeedsLogin" in ts_status.stdout' or '"Stopped" in ts_status.stdout'
```

`when:` is **already** a Jinja expression context — Ansible implicitly wraps it in `{{ }}`. Those
quoted sections therefore aren't expressions, they're **string literals**, and a non-empty string is
truthy. The condition was permanently `True` and the join task ran on every single play regardless
of Tailscale's state. Correct version:

```yaml
  when: >
    ts_status.rc != 0
    or 'NeedsLogin' in ts_status.stdout
    or 'Stopped' in ts_status.stdout
```

**Second guard bug in this same role** (the first was `creates: tailscaled.state`, Session 9). Same
shape twice: the task *looked* protected but wasn't. Rule going forward — **verify a guard by running
against an already-converged host and confirming it reports `skipped`.** Reading it is not enough.

**Other real fixes:** `risky-file-permissions` ×3 (`copy`/`template` with no `mode:` → permissions
depend on the remote umask, which is non-deterministic; one was `/etc/network/interfaces`);
`no-changed-when` ×2; and `risky-shell-pipe` on `curl … | sh` — **in a pipeline the exit code is the
last command's**, so a failed curl feeds empty input to `sh`, which exits 0 and Ansible reports
success having installed nothing. Fixed with `set -o pipefail &&` plus `executable: /bin/bash`
(pipefail isn't POSIX sh; Ubuntu's `/bin/sh` is dash).

**Handler renames need care.** The 5 `name[casing]` findings were all handlers. Handler names are
their API — tasks trigger them by exact string, so renaming one without updating every `notify:`
breaks the link **silently**: the handler just never fires. On `proxmox_network` that means
`/etc/network/interfaces` gets rewritten and never reloaded. Rename both sides in one commit, then
`grep -rn "notify:" ansible/` to prove nothing dangles.

**Profiles are a ladder — pin your rung.** ansible-lint escalates through `min` → `basic` →
`moderate` → `safety` → `shared` → `production`, promoting you as you clear each, so clearing a tier
*reveals the next* and the count doesn't fall monotonically. Fine for learning, bad for a gate:
strictness would drift upward on its own and a tool upgrade could redden a build with no code change.
Fixed the bar with `profile: production` in `.ansible-lint`.

**Vault warnings are a feature, not a problem.** ansible-lint can't decrypt `vault.yml` in CI (no
password) and skips two rules on it. That warning is *proof the file is genuinely encrypted* — so a
separate "is the vault encrypted?" job is unnecessary.

### CI plumbing gotchas
- **`before_script` and `script` are concatenated into ONE shell**, so a `cd` in the former leaks
  into the latter. Use paths relative to the repo root; `(cd dir && cmd)` in a subshell if needed.
- **ansible-lint and yamllint discover config differently** — ansible-lint walks *up* from cwd to
  find `.ansible-lint`; yamllint checks only the *current* directory. `cd ansible && ansible-lint`
  found one and not the other. `ansible-lint ansible/` from the root fixed it. "Config isn't being
  picked up" is usually a working-directory problem, not a syntax one.
- **Pinning one package while its dependencies float is worse than pinning nothing.**
  `ansible-lint==24.9.2` with an unpinned `ansible-core` resolved to an incompatible pair and the
  tool crashed on import. A traceback entirely inside `site-packages` = dependency problem, not your
  code. **Pin what you've verified, not what you guessed**: let the resolver find a working set, read
  the versions off a green run, then freeze that combination.

### Codified the DNS fix into the `docker` role

The morning's `daemon.json` was a hand-edit on one VM — it would vanish on a rebuild and CI would
break again with the same baffling error. Turned it into role code, and found the role was already
part of the problem: it hardcoded `DNS=192.168.0.1 1.1.1.1` into
`/etc/systemd/resolved.conf.d/dns.conf`, so **every `--tags docker` run silently reverted the
Terraform change to AdGuard.** Two sources of truth disagreeing, with Ansible winning because it
runs last.

Four pieces: a new `roles/docker/defaults/main.yml` holding `docker_dns_servers`, both DNS layers
now rendering from that one list, and a `Restart docker` handler. One list, two formats —
`| join(' ')` for the `[Resolve]` stanza, `| to_json` for `daemon.json`.

Best bit is `validate:` on the daemon.json copy:

```yaml
    validate: python3 -m json.tool %s
```

Ansible renders to a temp file, runs that command with `%s` = the temp path, and **only moves the
file into place if it exits 0**. Malformed JSON becomes a failed task on a still-working host
instead of a Docker daemon that won't start. Directly closes this morning's footgun.

**⭐ The router does NOT resolve `*.lab`.** I'd added a `host_vars/monitor-vm.yml` override pointing
that host at `192.168.0.1`, reasoning that monitor-vm shouldn't depend on the AdGuard it hosts. Then
one command across the fleet settled it:

```bash
ansible docker_hosts -m command -a "docker run --rm alpine:3.20 getent hosts git.lab"
```

Four hosts returned `192.168.0.31 git.lab`. monitor-vm — the only one on `.1` — returned `rc=2`,
name not found. **The router advertises AdGuard over DHCP but its own resolver forwards to its WAN
upstream**, so anything explicitly pointed at `.1` loses every internal name. Deleted the override.

Two lessons. First, always point resolvers at `192.168.0.31` directly — which makes the Terraform
`dns{}` change load-bearing rather than cosmetic. Second, the override traded a *theoretical*
robustness worry (a few seconds of self-reference during a restart, with `1.1.1.1` as fallback) for
a *concrete* permanent loss of `*.lab` on the host running Grafana, Loki, NPM and uptime-kuma. Bad
trade — and one `getent` across five hosts beat all the reasoning about it.

### Left open
- More jobs: `terraform validate` (`init -backend=false`), `tflint`.
- Drop the checks now duplicated in `.github/workflows/validate.yml`, and its inline
  `config_data:` now that `.yamllint` is a real file.
- Rename `compose_stack`'s interface vars, then remove the `var-naming` skip.
- Move Tailscale to its apt repo (retires `curl | sh` properly).
- **Pull mirroring is not available on GitLab CE** — the project's Mirroring settings offer *Push*
  only. So "GitHub source, GitLab pull-mirror" (Session 11) is not implementable as written.
  Note that push-mirroring still satisfies ADR-004: GitHub keeps a continuously-updated full copy,
  so the code that rebuilds the homelab never depends on the homelab. Leading option is instead to
  add **two push URLs to `origin`** so one `git push` publishes to both. ⚠️ Adding *any* explicit
  push URL stops git using the fetch URL for pushes — so both must be added, or one silently stops
  receiving commits.

---

## Session 11 — 2026-07-30 · GitLab Runner, a repo audit, and a backup pool that suspended itself

**Goal:** an at-home housekeeping session — clear the docs/commit backlog and reconcile
Terraform drift. The `backup` pool alerted partway through and took over.

**Outcome:** ✅ GitLab Runner deployed + registered (CI is unblocked). ✅ `backup` pool
recovered from `SUSPENDED`. ✅ Repo audit + `current-state.md` rewritten after a week of drift.
⬜ The backup disk still needs a *physical* move off a USB 2.0 hub.

### What I did

1. **GitLab Runner** — deployed as a compose stack on `runner-vm` (.25, vmid 123) with the
   docker executor via `docker.sock`, registered with the `glrt-…` token. Next: a first
   `.gitlab-ci.yml` doing IaC lint.
2. **Repo audit.** Deleted two strays: `leak-test.txt` (a fake Proxmox token I'd used to test
   the pre-commit hook) and `scripts/root@192.168.0.221` — a byte-identical copy of
   `macbook-backup.sh` created by an `scp` typo. **Missing the colon after the host turns
   `scp file root@ip` into a plain local copy named after the host.** Committed as `housekeep`.
3. **Found the remotes had diverged.** `git push` only goes to `origin`, so `gitlab/main` had
   silently fallen a commit behind `origin/main`. Since GitLab is about to run CI, a stale
   mirror means pipelines execute against old code. **Decision: GitHub = source of truth,
   GitLab = pull-mirror** (Settings → Repository → Mirroring). Pull-mirroring also means no
   inbound webhook is needed, so GitLab can stay off the public internet.
4. **`current-state.md` rewritten** — it was dated 07-23 and still claimed G11/MacBook were
   unbuilt and Immich was "waiting on the SSD."
5. **Terraform drift, measured properly** — read `terraform.tfstate` against `family-vms.tf`
   instead of guessing. Only media-vm and monitor-vm have drifted, and it's **two** changes,
   not one: `dns` (empty) *and* `cpu.type` (`qemu64` → `host`). Also confirmed `runner-vm` was
   already in state. Changed `dns.servers` to `["192.168.0.31", "1.1.1.1"]` so AdGuard resolves
   `*.lab` directly instead of relying on the router to forward. **Edited, not yet applied.**

### Errors & fixes 🔥

**`backup` pool `SUSPENDED` — and why "the disk just got renamed" was the wrong diagnosis.**

Grafana showed `k8plus / backup = PROBLEM`. The disk had moved from `sdc` to `sde`, so the
obvious guess was a naming problem. That guess is wrong twice over, and both halves are worth
remembering:

- **ZFS identifies vdevs by a GUID written into the disk label, not by `/dev/sdX`.** A rename
  alone can never fault a pool — that's the whole reason you can move a pool between controllers.
- **A device sitting still never gets renamed.** Kernel names are assigned at enumeration, so
  `sdc` → `sde` means the disk was *re-enumerated* — it dropped off the bus and came back.
  **The rename is the fingerprint of the drop, not the cause of the fault.**

`dmesg -T` settled it — four devices disconnecting in the *same second*:

```
usb 7-1:     USB disconnect, device number 12   ← hub
usb 7-1.3:   USB disconnect, device number 13   ← My Passport (backup pool)
usb 7-1.4:   USB disconnect, device number 14   ← second hub
usb 7-1.4.2: USB disconnect, device number 15   ← PD3.0 device
```

A failing disk drops *itself*; it doesn't take a hub and a power-delivery device with it.
**The hub reset and the disk was collateral.** Root cause: the backup disk had ended up behind
a bus-powered **USB 2.0** hub.

The by-id name confirmed it independently. The pool recorded its vdev as
`ata-WDC_WD10SDZM-…`, but the only link that existed was `usb-WD_My_Passport_2606_…`.
**An `ata-*` by-id name only appears when the kernel can do ATA passthrough, which needs UAS
over USB 3.** Behind a USB 2.0 hub it falls back to plain `usb-storage`, loses the ATA identity,
and gets a generic `usb-*` name. So a vdev path that silently changed `ata-…` → `usb-…` is a
**link-speed regression**, not a cosmetic one. Confirm in `dmesg`: `super-speed` + `uas` = USB 3;
`high-speed` + `usb-storage` = USB 2.0 (~40 MB/s ceiling, and a much tighter power budget).

Pool health was fine — `READ 3, WRITE 0, CKSUM 0`. Zero checksum errors means ZFS never
received data that failed verification. **`SUSPENDED` is a safety brake, not damage:** the
default `failmode=wait` freezes all pool I/O rather than returning errors to applications, and
it does **not** self-recover when the device reappears. It needs an explicit clear:

```bash
zpool clear backup     # → ONLINE
```

Still to do (physical): `zpool export backup` → move the disk to a **direct** port on k8plus →
`zpool import -d /dev/disk/by-id backup` → verify `dmesg` says `super-speed` → add
`usbcore.autosuspend=-1` to the kernel cmdline → reboot → `zpool scrub backup` → re-enable PBS.

**Terraform's `~ update in-place` says nothing about guest downtime.** The plan for
`cpu.type: qemu64 → host` renders as an in-place update, which reads as harmless. It isn't:
*in-place* only means the **resource** isn't destroyed and recreated. QEMU builds the virtual
CPU when the VM process starts, so the CPU model cannot change on a running guest — the
provider must stop and start it. `reboot_after_update = false` does not make it hot-applicable;
it just suppresses the convenience reboot and leaves running state out of sync with config.
Ask "can the hypervisor actually change this on a live VM?" before trusting the plan verb.
Relevant here because monitor-vm runs AdGuard — power-cycling it drops LAN DNS for the house.

**cloud-init DNS is first-boot only.** Changing `dns {}` in Terraform rewrites the cloud-init
drive but does nothing to an already-booted VM. `runner-vm` has booted, so it needs the live
fix (netplan / `resolvectl`). Same class of bug as the 07-25 "static IP but no DNS" incident.

**Jellyfin playback failed after the same disk shuffle — and the first diagnosis was wrong.**
The 2 TB media disk had moved `sda` → `sdc`, so the obvious guess was a `/dev/sdX` entry in
fstab. It wasn't: that mount has been `UUID=621B-F154` since Session 3. The real cause is
subtler — **`nofail` means "don't block boot if this is missing," not "mount it when it turns
up."** There is no hotplug trigger. So when the disk came back under a new letter, nothing
re-ran the mount and `/mnt/media` sat there as an empty directory. Jellyfin still *listed*
every film, because the metadata lives in its own database — only pressing play failed. That
split (library fine, playback dead) is the signature of a missing mount rather than a broken
Jellyfin.

Fix was two commands, no file edits:

```bash
mount -a          # UUID finds the disk at whatever letter it now has
pct restart 200   # container must re-resolve its bind mount
```

The restart is not optional: **an LXC bind mount is resolved once, when the container starts.**
Mounting a filesystem underneath that path afterwards does not propagate into the container's
mount namespace, so the host looks fixed while the container still sees an empty folder.

Also relearned while chasing this: **Jellyfin is the only service here not managed as code.**
CT 200 was built by hand, its user accounts live in its own SQLite DB, and nothing about it is
in Ansible or Vault. If that container is lost, PBS is the entire recovery plan. Worth a
`jellyfin` role, or at minimum a runbook. And exFAT has **no Unix permission model** — the
`uid=1000,gid=1000,umask=002` mount options *are* the access control, so they must survive any
future fstab edit.

### IaC added / changed
- `docs/current-state.md` — rewritten for 2026-07-30.
- `terraform/proxmox/family-vms.tf` — `dns.servers` → `["192.168.0.31", "1.1.1.1"]` (**not applied**).
- Removed `leak-test.txt` and `scripts/root@192.168.0.221`.
- ⚠️ **ADR-003 is now stale** — it records GitLab as "Tunnel + Cloudflare Access," but GitLab
  has been Tailscale-only since split-DNS solved remote access in Session 10. Needs updating,
  with the lost capability (inbound webhooks) written down as the trigger to revisit.

---

## Session 10 — 2026-07-29 · Alert email, a qBittorrent self-heal watchdog, remote GitLab

**Goal:** A work-day session (remote over Tailscale), so remote-safe jobs only — finish
alert email, automate the qBittorrent-dies-daily chore, and get GitLab reachable remotely.

**Outcome:** ✅ Grafana alert email live (Proton SMTP). ✅ A `qbittorrent_watchdog` role that
self-heals qbit when gluetun's tunnel goes stale. ✅ Remote `*.lab` access via Tailscale
split-DNS (GitLab included). Runner token in hand for the next session's first CI pipeline.

### What I did
1. **Alert email** — enabled Grafana SMTP (`GF_SMTP_*`) via a **Proton Business SMTP token**
   (`smtp.protonmail.ch:587`), token in vault. Test mail delivered.
2. **qBittorrent watchdog** (`qbittorrent_watchdog` role, media-vm) — a systemd **timer** (every
   3 min) runs a script that curls qbit's `/api/v2/transfer/info`; if DHT collapses to 0 /
   disconnected for **2 checks running**, it runs `docker compose restart gluetun qbittorrent`.
   Modelled on `nic_watchdog`, but time-triggered (timer) instead of boot-triggered.
3. **Remote GitLab** — `git.lab` is LAN-only DNS, so it was unreachable off-LAN. Fixed with
   **Tailscale split-DNS** (nameserver = AdGuard `192.168.0.31`, restricted to domain `lab`) +
   "Use Tailscale DNS" on the laptop. All `*.lab` now resolve remotely.

### Errors & fixes 🔥
**qbit Web API returns `Forbidden`.** qbit is inside gluetun's netns, so a `localhost` request
is NAT'd and arrives from a Docker IP (`172.18.0.1`), not `127.0.0.1` — the "bypass auth for
localhost" toggle never triggers. Fix: whitelist `172.16.0.0/12` in qbit's "Bypass auth for
whitelisted IP subnets."

**`systemctl start` as the `ubuntu` user → polkit auth failure.** The cloud-init user has no
password, so systemd's polkit prompt can't be answered. Fix: `sudo systemctl …` (the role is
fine — it runs as root). Rule: anything that *changes* systemd state needs sudo.

**Remote `git.lab` = "Non-existent domain".** The laptop's DNS was the corporate resolver
(`10.255.255.1`), not Tailscale's `100.100.100.100`, so split-DNS wasn't applied. Fix: turn on
"Use Tailscale DNS settings." Note: `nslookup` ignores the hosts file, so if you fall back to a
hosts entry, test with `ping`, not `nslookup`.

**IaC added:** `qbittorrent_watchdog` role + a media-vm play in `site.yml`; `GF_SMTP_*` in the
monitoring compose + `SMTP_*` in `host_vars/monitor-vm.yml` (+ `vault_smtp_password`).

---

## Session 9 — 2026-07-28 · Immich on a new SSD pool (+ a CPU-flags gotcha)

**Goal:** Get the family photo library online. Turn the spare 1 TB M.2 SSD in k8plus into a
ZFS pool, hand family-vm a disk from it, and deploy **Immich** (a Google-Photos replacement) —
then expose it publicly so the family can back up phones.

**Outcome:** ✅ `data` ZFS pool live (single NVMe, ~922 GB), family-vm has an 800 GB
SSD-backed disk at `/mnt/immich`, and Immich is up (server + Postgres + Redis + ML). One
genuinely interesting gotcha: the ML container crash-looped on a **NumPy CPU-instruction
error** until I passed the host CPU into the VM. Kept Immich **Tailscale-only** (no public
exposure) — family photos are more sensitive than the media catalogue, and Tailscale also
sidesteps Cloudflare's 100 MB upload cap.

### What I did
1. **Identified the disk safely.** `lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL` + `zpool status`
   + `ls /dev/disk/by-id/`. k8plus has three ~1 TB devices (two USB My Passports + the rpool
   NVMe), so the whole game was picking the *right* one — the KIOXIA NVMe that belonged to no
   pool. **Always build pools on `/dev/disk/by-id/…`, never `/dev/sdX`** (the letters reshuffle
   across reboots; a by-id name is welded to the drive).
2. **Created the pool.** `sgdisk --zap-all` + `wipefs -a` to clear the old exfat/NTFS junk,
   then:
   ```bash
   zpool create -f -o ashift=12 \
     -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl \
     data /dev/disk/by-id/nvme-KBG60ZNS1T02_KIOXIA_…
   zfs create data/immich
   pvesm add zfspool data --pool data --content images,rootdir --sparse 1
   ```
   (`ashift=12` = 4K sectors for the SSD; `lz4` = free speed; `xattr=sa`+`acltype=posixacl`
   are what container file stores want; `atime=off` skips a write on every read.)
3. **Gave family-vm an SSD disk as code.** A `dynamic "disk"` block in Terraform keyed off a
   new `data_disk` field, so *only* family-vm gets a second 800 GB disk (`scsi1`) on the
   `data` pool; also bumped its RAM to 12 GB for the ML load. **Targeted** apply
   (`-target='…family["family-vm"]'`) so I didn't drag in the K3s tier or the `dns{}` drift.
   Inside the VM: `mkfs.ext4 -L immich`, an `fstab` line with `nofail`, mounted at `/mnt/immich`.
4. **Deployed Immich** through the existing `family` compose stack — but fixed the env first:
   it was missing `DB_HOSTNAME` / `REDIS_HOSTNAME` (Immich can't find its own DB/Redis without
   them) and I repointed `UPLOAD_LOCATION` from the exfat media drive to `/mnt/immich`.
5. **Access = Tailscale-only.** Briefly wired a Cloudflare hostname, then decided against it:
   the photo library is more sensitive than media and has no reason to be public. Closed the
   Cloudflare hostname/Access → Immich is now reachable **only over the tailnet**. Put Tailscale
   on family-vm via the `tailscale` role (identity-only) and pointed the Immich app at the VM's
   tailnet IP `http://100.x.y.z:2283`. Every viewer/uploader must be on the tailnet — private,
   and no 100 MB body cap. Updated **ADR-003** to move Immich from public → Tailscale-only.

### Errors & fixes 🔥
**Immich ML crash-loops with `NumPy was built with baseline optimizations (X86_V2) but your
machine doesn't support (X86_V2)`.** The `immich-server` was healthy but
`immich-machine-learning` restarted every ~5 s (exit 1). Root cause: **Proxmox's default VM
CPU model is `kvm64`**, a minimal baseline that predates x86-64-v2, so the guest didn't
advertise SSE4.2/POPCNT/etc. Immich's ML image ships a NumPy compiled for the **v2** baseline,
so it aborts the instant it `import numpy`. Fix: `cpu { type = "host" }` in Terraform → the VM
inherits the real Ryzen flags → ML boots clean. CPU model isn't hot-pluggable, so it's a
cold-boot change (brief family-vm restart).

**Tailscale role ran clean but `tailscale ip -4` said `NeedsLogin`.** The join task was
guarded with `creates: /var/lib/tailscale/tailscaled.state`, but `tailscaled` writes that
file the moment the daemon *starts* — before any login — so Ansible skipped the actual
`tailscale up`. Fixed the role to guard on `tailscale status --json` backend state instead;
recovered the running VM with a manual `tailscale up --ssh --accept-routes=false
--accept-dns=false`.

### 🎓 The thing I actually learned: x86-64 microarchitecture levels & VM CPU models
CPUs have piled on instruction sets for 20 years (SSE → SSE2 → SSE4.2 → AVX → AVX2 → AVX-512…).
Rather than have software probe for each one, the industry defined **tiers** you can target:

| Level | ~Era | Adds (roughly) | What gives it to you |
|---|---|---|---|
| `x86-64-v1` | 2003 | SSE2 (the original 64-bit baseline) | `kvm64` / `qemu64` (Proxmox default) |
| `x86-64-v2` | 2009 | **SSE4.2, POPCNT, CMPXCHG16B** | most real CPUs; NumPy targeted this |
| `x86-64-v3` | 2013 | AVX, AVX2, BMI1/2, FMA | modern desktops/servers |
| `x86-64-v4` | — | AVX-512 | newer Xeon/EPYC (and some Ryzen) |

Libraries increasingly build for **v2/v3** to run faster and drop ancient-CPU support — which
is exactly why a modern NumPy refuses to load on a CPU that only claims **v1**.

A Proxmox VM does **not** automatically see the physical CPU. QEMU hands the guest a *virtual*
CPU model, and you choose the tradeoff:
- **`kvm64` / `qemu64`** — safe lowest-common-denominator (v1). Maximum compatibility (any VM
  runs on any host), but modern v2/v3 software breaks. *This was my problem.*
- **`host`** — passes the physical CPU straight through. Fastest, every flag available. The
  catch: you can only **live-migrate** to an *identical* CPU (a VM that booted with AVX2 can't
  move to a host that lacks it). I don't do HA/live-migration, so `host` is the correct choice.
- **Named models** (`x86-64-v2-AES`, `x86-64-v3`, `EPYC-…`) — the middle ground: guarantee a
  tier of flags while staying migratable across any host that supports that tier.

**Rule of thumb:** single-host homelab VM → use `host`. Cluster you migrate across mixed CPUs →
pick the highest **named** model *all* your hosts share.

**Why only ML broke:** the Immich server (Node/TypeScript) and Postgres/Redis never touch that
NumPy build path. The Python ML worker `import numpy`s at startup, so it's the canary that
sniffs out missing CPU flags first.

### 🎓 Storage & exposure notes (for future-me)
- **Single-disk pool = no redundancy.** Acceptable *because* the phone originals + PBS are the
  safety net — but real photos landing here bumps **off-site backup** up the priority list.
- **ext4-on-a-zvol** looks like double bookkeeping, but the pool's checksums/compression still
  apply underneath; it keeps family-vm's disk model identical to every other VM (clean IaC)
  instead of a one-off virtiofs share.
- **Cloudflare's proxy caps request bodies at 100 MB** (Free/Pro). Photos sail through, but a
  >100 MB phone **video** would fail to upload through the tunnel. This — plus the privacy of
  family photos — is why Immich ended up **Tailscale-only** rather than public. (Good gotcha to
  remember for *any* service that takes large uploads behind a Cloudflare Tunnel.)

**IaC touched:** `terraform/proxmox/family-vms.tf` (`data_disk` dynamic disk + `cpu type=host`
+ 12 GB on family-vm), `host_vars/family-vm.yml` (`UPLOAD_LOCATION=/mnt/immich` +
`DB_HOSTNAME`/`REDIS_HOSTNAME`), `compose/family/.env.example`.

---

## Session 8 — 2026-07-25/26 · G11 core-infra complete + managed switch in

**Goal:** Recover from the failing backup disk, harden the fixes in code, then finish
G11 as the core-infra node (DNS, reverse proxy, logs, GitLab). The MikroTik switch,
a spare SSD, 2.5G adapters, and a JetKVM all landed too.

**Outcome:** ✅ **G11 core-infra is done** — AdGuard DNS, Nginx Proxy Manager (`*.lab`
hostnames), Loki + Promtail logs with a provisioned dashboard, and **GitLab CE** on its
own VM. Backup disk recovered (pool ONLINE, scrub clean). MikroTik CRS310 in as a flat
managed switch (VLAN work is Phase 1, next). JetKVM gives out-of-band console to k8plus.

### What I did
1. **Backup disk recovery:** reconnected the WD My Passport to the front USB-C port →
   `zpool clear/import backup` → **ONLINE, scrub 0 errors** → re-enabled backups.
2. **Hardened the fixes in code:** `nic_tuning` role (disable EEE on igc NICs), `tailscale`
   role now `--accept-routes=false --accept-dns=false`, `disk_health` role (ZFS+SMART →
   Prometheus) with panels + in-Grafana alerts, and the `docker` role now sets a DNS
   resolver + waits for cloud-init before apt.
3. **G11 core-infra (all via `compose_stack` + per-stack tags):**
   - **AdGuard Home** (DNS + ad-blocking) → set the router's DHCP DNS to it.
   - **Nginx Proxy Manager** → `*.lab` internal hostnames (AdGuard rewrite `*.lab` → NPM → service).
   - **Loki + Promtail** (logs) + a provisioned Logs dashboard (host/container/search filters).
   - **GitLab CE** on a new `gitlab-vm` (.32); reached at `git.lab`, git-SSH on :2224.
4. **Managed switch (Phase 0):** MikroTik **CRS310-8G+2S+** (RouterOS) in place, flat
   `192.168.0.x` working, mgmt IP `192.168.0.2` added. **JetKVM** (ether8→k8plus) working
   as out-of-band console. Incremental VLAN plan chosen (keep infra on the flat net; add
   VLAN 40 IoT / 20 Lab as new zones).

### Errors & fixes 🔥
**VM shuts itself down under load = host OOM.** gitlab-vm kept dying → g11's BIOS had
**UMA Frame Buffer = 4G**, so only 11GB of 16 was usable → VMs overcommitted → OOM-killed
the VM. Fix: BIOS → GFX → **UMA Frame Buffer → 256M** → ~15GB usable. (PVE9 already caps
ZFS ARC at ~10% — ARC was NOT the culprit; always check `free` vs installed RAM.)

**Fresh cloud-init VM: apt lock race** (`Unable to acquire the dpkg frontend lock`) —
cloud-init runs apt on first boot. Fixed in the `docker` role with `cloud-init status --wait`.

**DNS broke on family-vm again** (cloud-init sets no DNS) → codified a systemd-resolved
resolver into the `docker` role so every VM gets one.

**Grafana Loki dashboard "parse error"** — Loki rejects a query where all matchers are
empty-compatible (`.*`). Fix: anchor with `job="docker"` + set the "All" value to `.+`.

**Intel i226 NIC link-flap** ("Link Up 2500 → Down" loop) took k8plus offline → `ethtool
--set-eee <iface> eee off` (now the `nic_tuning` role).

**Winbox "connection timed out"** on the new switch — default IP is 192.168.88.1, client
was on .0.x. Fix: connect **by MAC** via Winbox → Neighbors (works at L2 regardless of subnet).

**JetKVM: see the screen but can't type** — USB HID was fine (dmesg showed the emulated
keyboard); the web console just needed a **click to focus** before it captures keystrokes.

### Next session
- **VLAN Phase 1 (VLAN 40 IoT/Guest)** — enable bridge `vlan-filtering` CAREFULLY (mgmt VLAN
  first or lockout; Winbox-by-MAC + JetKVM are the lifelines). Write ADR-006 first.
- Then VLAN 20 (Lab) with the K3s tier, and VLAN 30 (mgmt/cluster) on the second NICs.
- 1TB SSD (now in k8plus) → `data` ZFS pool → Immich.

---

## Session 7 — 2026-07-24 · Monitoring, notes backend, and a very long firefight

**Goal:** Stand up centralized monitoring + a self-hosted notes backend as code. Ended
up root-causing a failing disk and a self-inflicted network lockout along the way.

**Outcome:** ✅ Prometheus + Grafana live on a new VM on G11 (fleet dashboard working),
uptime-kuma watching every service, CouchDB running for Obsidian LiveSync. Also found and
contained a **failing USB backup disk** and recovered from a **Tailscale routing lockout**.
A brutal but hugely instructive session.

### What I did
1. **Monitoring (core-infra on g11):** Terraformed `monitor-vm` (192.168.0.31) — a
   cross-node clone (template lives on k8plus). Bootstrapped it as a docker host, then
   deployed **Prometheus + Grafana + uptime-kuma** via `compose_stack`. Prometheus scrapes
   node_exporter on all 6 hosts; Grafana datasource + a Fleet Overview dashboard are
   provisioned from git.
2. **Notes backend:** deployed **CouchDB** on family-vm (so it rides the PBS backups) for
   the Obsidian **Self-hosted LiveSync** plugin. Configured it via a post-boot HTTP-API
   script (mounting a config file crashed it — see below).
3. **IaC hardening:** extended `compose_stack` to copy a whole stack folder (config +
   provisioning, not just the compose file); added a `disk_health` role (ZFS pool + SMART
   → node_exporter textfile); changed the `tailscale` role to `--accept-routes=false`.

### Errors & fixes 🔥
**Terraform wanted to DESTROY family-vm + media-vm** — a change to the `clone { full }`
flag forces VM replacement. Caught it in `terraform plan` (`2 to destroy`). Fixed to
`full = true` (the provider default the VMs were built with) so existing VMs show no diff.
**Lesson: always read the plan; `-target` the new resource; never blind-`apply`.**

**Grafana crash-looped** — `datasource provisioning error: Only one datasource per
organization can be marked as default`. The scaffold shipped a datasource file AND I added
one, both `isDefault: true`. Emptied the scaffold one.

**CouchDB exited code 1 with ZERO logs** — mounting a `local.d/*.ini` config file crashes
CouchDB 3.5.2 before it can even log. Proved it: boots fine without the mount. Fix: boot
clean, apply the LiveSync settings **after startup via the `_config` HTTP API**
(`setup-couchdb.sh`) — which is the method the LiveSync docs recommend anyway.

**PBS backups kept failing → traced to a dying disk** 🔥🔥🔥 The whole chain, in order:
- Backup failed with `unable to acquire backup group lock`.
- Found a **zombie `proxmox-backup` process** (`Zsl <defunct>`) stuck since a prior day.
- It was **unreapable** — a sibling thread wedged in uninterruptible kernel I/O (`D` state);
  SIGKILL can't touch it (`SubState=stop-sigkill`, `MainPID=0`). Only a **reboot** clears it.
- After reboot, backup *still* failed: `http upgrade request timed out`.
- `zpool status` → the **`backup` pool was SUSPENDED**: the 1TB WD **USB** disk (`sdb`)
  threw READ/WRITE errors and **dropped off the bus** (`DID_ERROR`, `device offline`,
  gone from `lsblk`). Root cause of *everything* since the first hang.
- Both HDDs are **bus-powered USB** on a mini PC → the drive browns out / drops under load.
  Fix (physical, pending): powered enclosure / new cable / different port, then `zpool clear`
  + `scrub`. Backup job **disabled** meanwhile so it can't re-wedge the node.

**Rebooting k8plus blinded me to g11 + macbook** — the only Tailscale **subnet router** ran
on k8plus. From remote (work), losing it withdrew the `192.168.0.0/24` route → no path to
*any* node. The cluster was perfectly quorate the whole time (corosync log proved it); I'd
just lost the tunnel. Fix: Tailscale on all nodes, each with its own IP.

**Then `--accept-routes` on the nodes locked them out** — a node accepting a route for the
`/24` it already lives on reroutes its own LAN + corosync through the tunnel. Recovered via
the **Proxmox web console over each node's Tailscale IP** (password auth, no SSH key), then
`tailscale set --accept-routes=false`. **Rule: nodes never accept routes; only clients do.**

### Next session
- **Physical:** fix the backup disk (powered enclosure), `zpool clear` + scrub, re-enable backups.
- Apply the `disk_health` + `tailscale` role changes (targeted run, skip the firewall role).
- Finish Obsidian on the phone (Tailscale + LiveSync Setup URI).
- VLAN migration when the MikroTik lands; then the K3s lab tier.

---

## Session 6 — 2026-07-24 · The 3-node cluster is real

**Goal:** Build the last two nodes (G11 and the MacBook) and stop running one lonely
server — turn it into a proper 3-node Proxmox cluster with real quorum.

**Outcome:** 🎉 Done. All three machines are installed, bootstrapped from the repo, and
joined into one cluster that survives losing any single node. The flaky MacBook now heals
its own network on boot, and its screen sleeps so I don't burn the panel. This is the
milestone the whole design was pointing at.

### Why I did the MacBook now instead of a QDevice
I wanted G11 in the cluster, but a **2-node cluster is quorum-fragile**: quorum needs a
majority, so with two nodes that's 2-of-2 — if *either* node drops, the survivor can't
start or change guests. That's dangerous for k8plus, which runs the family stuff.

The "proper" fix for two nodes is a **QDevice** (a tiny third vote on some always-on box).
But I don't have a spare always-on machine — so instead of scaffolding a QDevice I'd just
rip out later, I built the **MacBook as the real third node** tonight.

**How the votes play out with 3 nodes:** 3 votes total, quorum = 2. The cluster stays
fully functional as long as **any 2 of 3** are up. So my disposable, flaky MacBook can
come and go freely — losing it still leaves k8plus + g11 = 2 votes = quorate. Exactly the
ADR-001 design: the unreliable machine can only ever take down disposable workloads.

### What I did
1. **G11:** installed Proxmox VE 9 (ZFS), static `192.168.0.12`, hostname `g11`. Ticked
   **vmbr0 → VLAN aware** (so the future MikroTik VLAN migration is just NIC tagging, no
   bridge surgery). Then from the Z13 control node:
   ```bash
   ssh-keygen -R 192.168.0.12 && ssh-copy-id root@192.168.0.12
   cd ~/homelab-infra/ansible
   ansible-playbook bootstrap.yml --limit g11
   ```
2. **Formed the cluster** on k8plus and joined g11:
   ```bash
   # k8plus (safe — running guests untouched):
   pvecm create homelab
   # g11 (must be empty, which it was):
   pvecm add 192.168.0.11
   pvecm status        # Nodes: 2, quorate
   ```
3. **MacBook:** wiped it (no data to keep). It's a 2019 MBP with a **T2 chip**, so it
   needed a pre-flight or it wouldn't even boot the USB (see below). Installed Proxmox VE 9
   (ZFS), static `192.168.0.13`, hostname `macbook`, vmbr0 VLAN-aware.
4. **Bootstrapped + joined** the MacBook as node 3:
   ```bash
   ssh-keygen -R 192.168.0.13 && ssh-copy-id root@192.168.0.13
   ansible-playbook bootstrap.yml --limit macbook   # includes nic_watchdog + console_blank
   ssh root@192.168.0.13 'pvecm add 192.168.0.11'
   pvecm status        # Nodes: 3, Expected votes: 3, Quorate: Yes ✅
   ```
5. **Reboot test:** rebooted the MacBook and confirmed it came back on the network **by
   itself** (`ansible macbook -m ping` → pong, no manual adapter poking), and the screen
   went dark on its own. Hands-off. That's the win.

### Errors & fixes 🔥
**T2 Mac won't boot the USB installer** — the T2 security chip blocks external boot by
default. Fix, in macOS Recovery (Cmd-R) → **Startup Security Utility**: set **Secure Boot
→ No Security** and **Allow booting from external media**. Then boot holding **Option**
and pick the USB.

**`applesmc ... probe with driver applesmc failed with error -5`** at the login prompt —
**harmless**, expected on every T2 Mac. `applesmc` is the old fan/temp-sensor driver; the
SMC sits behind the T2, so it can't probe it. Doesn't affect networking, storage, or
clustering — the T2 firmware manages the fans itself. Cosmetic log noise, ignore it.

**MacBook unreachable after install — vmbr0 had no IP** 🔥🔥 This is *the* MacBook quirk,
the reason it's the disposable node. Its ethernet is a **USB Realtek adapter (`r8152`,
named `nic0`)** that **enumerates late** — so at boot Proxmox brings up `vmbr0` before the
adapter exists, the bridge comes up with no working port, and the node is dead on the
network. Diagnosed at the console:
```bash
ip -br a          # vmbr0 missing / no address
ip -br link       # nic0 = DOWN
```
Manual recovery:
```bash
ip link set nic0 up          # → "r8152 ... nic0: carrier on"
systemctl restart networking # rebuilds vmbr0 with 192.168.0.13
ping -c2 192.168.0.1         # replies → back online
```
(`ifreload -a` kept failing with "another instance already running" — a stale lock;
`systemctl restart networking` is the reliable hammer.)

**Permanent fix — the `nic_watchdog` role was a broken stub.** It had a hardcoded
`enp3s0` and reloaded `bcm5974` (the *trackpad* driver!). Rewrote `nic-fix.sh` to (a) find
the NIC by its `r8152` driver so a USB rename won't break it, and (b) heal the **bridge** —
it checks that `vmbr0` has an IP and restarts networking if not, which is what actually
failed. It's a no-op on a healthy boot. Also fixed the systemd unit:
`After=networking.service` instead of `network-online.target` (which can hang forever when
the link never comes up). And it wasn't even running — `nic_watchdog` was only in
`site.yml`, but `bootstrap.yml` is the safe baseline, so I added a lab-scoped play to
bootstrap.

### New this session
- **`console_blank` role** — sets `consoleblank=60` on the kernel cmdline so the MacBook's
  internal panel backlight sleeps after 60s (machine stays fully powered — just the screen
  rests, no burn-in). Persists via `proxmox-boot-tool`, and blanks the live console
  immediately so I saw it work without a reboot.
- **VLAN-aware bridges** on all three nodes now, ready for the MikroTik.

### Next session
- Stand up **centralized monitoring** (Prometheus + Grafana) — node_exporter is already on
  every host, so it just needs a scrape target + dashboards. First service to land on G11.
- When the **MikroTik managed switch** arrives: VLAN segmentation (ADR-005) — tag each
  guest's NIC, firewall the zones. Keep guests on the same IPs so the tunnel/Tailscale
  survive the cutover.
- Then the fun part: **K3s on the MacBook** → ArgoCD → first commit-to-deploy pipeline.

---

## Session 5 — 2026-07-23 · Nextcloud on IaC, portfolio polish, FlareSolverr

**Goal:** Retire the hand-deployed Nextcloud and bring it under Ansible; sharpen the
public-facing portfolio; and wire up FlareSolverr for Cloudflare-protected indexers.

**Outcome:** ✅ Nextcloud is now Ansible + Vault managed (redeployed as a clean install —
no data existed yet, so no migration risk). README + docs + blog posts brought in line
with what's actually built. FlareSolverr configured so I can add indexers that sit behind
Cloudflare.

### Key decisions
- **Nextcloud = fresh install.** No family data on it yet, so I skipped the careful "match
  the old DB password / reuse volumes" dance — just wiped the manual deploy and let Ansible
  build it clean. The vault `vault_nextcloud_db_password` can be any value.
- **MacBook lab node = clean wipe.** Nothing to preserve on it either, which killed the
  whole "back up the old VM first" problem (I'd forgotten its password anyway — see the
  migration write-up). Turns out the best backup is realising you don't need one.

### What I did
1. **Ansible Nextcloud redeploy:**
   - Gave the `compose_stack` role a `stack_services` filter so I can deploy just part of a
     compose file (`[nextcloud, nextcloud-db]` now; Immich waits for the SSD):
     ```yaml
     services: "{{ stack_services | default(omit) }}"
     ```
   - `host_vars/family-vm.yml`: `stack_name: family`, `stack_services: [nextcloud,
     nextcloud-db]`, `stack_dir: /home/ubuntu/stacks`.
   - Wiped the old manual stack and redeployed as code:
     ```bash
     ssh ubuntu@192.168.0.21 'cd ~/stacks/family && docker compose down -v'
     cd ~/homelab-infra/ansible
     ansible-playbook deploy-stacks.yml --limit family-vm --ask-vault-pass
     ```
   - Ran the first-run wizard, created admin. Plaintext `.env` retired — it's generated
     from vault on every deploy now.
2. **FlareSolverr:** it was already in the media compose; the work was wiring it in
   Prowlarr → Settings → Indexers → add **FlareSolverr proxy** at `http://flaresolverr:8191`
   with a `flaresolverr` tag, then tagging the Cloudflare-protected indexers so only they
   route through it. (FlareSolverr uses the VM's normal network, not the VPN — but that's
   just *search* queries; the actual download still goes qBittorrent → Gluetun → VPN.)
3. **Portfolio polish:** README rewritten with an honest 🟢/🟡/⚪ build-status legend (an
   in-progress build reads as more credible than pretending everything's done), fixed real
   inaccuracies (Proxmox VE 8→9, "SOPS+age" → the Ansible Vault I actually use), redrew the
   architecture diagram, refreshed `current-state.md`, de-drafted the blog posts.

### Next session
- Build G11 + the MacBook and form the cluster (→ Session 6).

---

## Session 4 — 2026-07-22/23 · Media automation, end to end

**Goal:** Get the whole media pipeline working — Jellyseerr → Radarr/Sonarr → qBittorrent
through the VPN → library → Jellyfin — deployed as code.

**Outcome:** ✅ Full pipeline live. Switched VPN from ProtonVPN free (blocks P2P) to
**Windscribe (paid)**, deployed the stack via **Ansible + Vault**, and got a real download
flowing through the kill-switched VPN into the library and onto Jellyfin.

### What I did
- Kept **Windscribe** (Mullvad dropped port forwarding in 2023; Windscribe does P2P + port
  forwarding + Gluetun — no reason to switch). Reconfigured gluetun for it; secrets
  (private + preshared key) in ansible-vault, region + address in host_vars.
- Redeployed: `ansible-playbook deploy-stacks.yml --limit media-vm --ask-vault-pass`.
- Configured the apps:
  - **qBittorrent** (:8080 via gluetun): password, save path `/media/downloads`.
  - **Radarr/Sonarr**: root folders `/media/Movies`, `/media/TV Show`; download client
    **host = `gluetun`, port 8080** (qbit shares gluetun's netns — NOT `qbittorrent`).
  - **Prowlarr** (:9696): indexers + apps via API keys. **Jellyseerr** (:5055): linked to
    Jellyfin + Radarr/Sonarr.
- Set **Radarr min seeders = 5** and qBit seeding limits (ratio 2.0 / 7 days → remove
  torrent + files) so dead torrents are skipped and the duplicate copy auto-cleans (exFAT
  has no hardlinks).

### Errors & fixes 🔥
**gluetun crash-loop: "the region specified is not valid ... hong kong - phooey"** — I
used Windscribe's UI label. Gluetun wants its *own* exact region string. Fix:
`vpn_region: "Hong Kong"` from Gluetun's printed list.

**Torrents stuck at "Downloading metadata", DHT: 0 nodes** 🔥🔥 — the **Windscribe Hong
Kong server blocks P2P**: VPN connects, web traffic works, but all peer/DHT traffic is
dead. Not a dead torrent (two different ones failed identically). Fix: switch region:
```bash
sed -i 's/^vpn_region:.*/vpn_region: "Netherlands"/' ansible/inventory/host_vars/media-vm.yml
ansible-playbook deploy-stacks.yml --limit media-vm --ask-vault-pass
```
DHT nodes immediately climbed → download started. **Lesson: pick a P2P-allowed server.**

**docker.sock permission denied on media-vm** — user wasn't in the docker group (role
timing). `sudo usermod -aG docker ubuntu && newgrp docker` (role has the task for rebuilds).

---

## Session 3 — 2026-07-21/22 · Media platform, Cloudflare consolidation, IaC deploys

**Goal:** Move the media disk to the K8 Plus, bring up Jellyfin with hardware transcoding,
back everything up, consolidate Cloudflare onto the new infra, and deploy the media stack
as code.

**Outcome:** Family media platform fully live on the new node (Jellyfin + HW transcode,
zero-downtime cutover). PBS nightly backups running. Cloudflare tunnel migrated off the
MacBook to its own LXC; admin is Tailscale-only; public surface trimmed to Jellyfin +
Nextcloud. Media stack deployed via **Ansible + Vault**.

### What I did
1. **Media disk move (exFAT):** moved 2×WD HDDs to K8 Plus. sda1 = 2TB exFAT "JC-Media"
   (~890 GB of Movies/TV), sdb1 = 1TB (→ ZFS backup pool).
   ```bash
   apt-get install -y exfatprogs
   echo 'UUID=621B-F154 /mnt/media exfat defaults,nofail,uid=1000,gid=1000,umask=002 0 0' >> /etc/fstab
   ```
2. **Jellyfin LXC + iGPU passthrough** (CT 200, Debian 12, bind-mount `/mnt/media`):
   ```bash
   pct set 200 -dev0 /dev/dri/renderD128,gid=104   # gid must match container's render group
   pct set 200 -dev1 /dev/dri/card0,gid=44
   ```
   `vainfo` confirmed H264/HEVC/VP9/AV1 decode + HW encode on the Radeon 780M. Cutover:
   repointed the Cloudflare tunnel to `192.168.0.23:8096` — family kept the same URL, zero
   downtime.
3. **Backups — ZFS pool + PBS** on the 1TB disk; nightly backups of all guests.
4. **Cloudflare consolidation:** new `lxc-tunnel` (cloudflared in CT 201), only `jellyfin`
   + `nextcloud` hostnames kept; deleted the old MacBook tunnel + all the admin DNS records
   (proxmox/grafana/jenkins/git/npm). Public surface = 2 services. (ADR-003.)
5. **Tailscale** subnet router (`--advertise-routes=192.168.0.0/24 --accept-routes`) — so
   dropping the public admin hostnames cost nothing.
6. **Media share (Samba/CIFS):** NFS failed (exFAT can't be NFS-exported), so Samba.
7. **IaC — Ansible + Vault:** new `compose_stack` role renders `.env` from vaulted vars and
   runs the stack; `deploy-stacks.yml` maps hosts → stacks. Secrets safe to commit.

### Errors & fixes 🔥
**exFAT can't be NFS-exported** → use **Samba/CIFS**.
**CIFS `mount error(13)`** → Samba password mismatch; test with `smbclient //host/media -U user` first.
**PBS enterprise repo 401** (blocked apt) → `rm /etc/apt/sources.list.d/pbs-enterprise.sources`. Both PVE *and* PBS ship an enterprise repo.
**Jellyfin LXC no GPU** → render group GID mismatch (device gid 993 vs container's 104). Fix: `pct set 200 -dev0 /dev/dri/renderD128,gid=104`.
**Cloudflare 525** on a hostname → stale DNS record from the old tunnel; delete + re-add on the new tunnel.
**Nextcloud "untrusted domain"** through the proxy:
```bash
docker compose exec -u www-data nextcloud php occ config:system:set trusted_domains 1 --value=nextcloud.your-domain.example
docker compose exec -u www-data nextcloud php occ config:system:set overwriteprotocol --value=https
```
**gluetun unhealthy, all traffic times out** → **ProtonVPN free blocks P2P** (port
forwarding is paid-only). Not a bug — free tier can't torrent. ✅ Kill-switch validated:
VPN down = qBittorrent had NO network. No leak possible.

---

## Session 2 — 2026-07-21 · VMs as code + first service live

**Goal:** Reinstall k8plus on ZFS, then Terraform the family VMs, Ansible them into Docker
hosts, and deploy the first real service.

**Outcome:** 🎉 Full arc: bare metal → Proxmox (ZFS) → Terraform VMs → Ansible/Docker →
**Nextcloud in the browser**. Every layer reproducible from git.

### What I did
1. Reinstalled k8plus on **ZFS (RAID0)**; re-baselined in one command (all Session 1 fixes
   baked in):
   ```bash
   ssh-keygen -R 192.168.0.11 && ssh-copy-id root@192.168.0.11
   ansible-playbook bootstrap.yml --limit k8plus
   ```
2. Built cloud-init template 9000 on ZFS (`sed -i 's/STORAGE=local-lvm/STORAGE=local-zfs/'`).
3. Installed **Terraform 1.15.8** (binary, not apt — see gotcha), made a Proxmox API token:
   ```bash
   export TF_VAR_pve_api_token='root@pam!terraform=<secret>'   # single quotes! (the ! )
   ```
4. Terraformed the two family VMs (targeted, since g11/macbook didn't exist yet), then
   Ansible → Docker → Nextcloud.

### Errors & fixes 🔥
**`export TF_VAR_...` → "Invalid block definition"** — I pasted the shell `export` line
into `terraform.tfvars`. It's a terminal command; tfvars holds only variables.
**SSH key showed as literal "PASTE: cat ~/.ssh/..."** — I pasted the instruction, not the
key. Run `cat ~/.ssh/id_ed25519.pub`, paste the real `ssh-ed25519 AAAA...`.
**TF cloud-init disk → `local-lvm` not found** — pin `datastore_id = "local-zfs"` in each
`initialization {}` block.
**WSL lost all network mid-session ("No route to host")** 🔥🔥 — WSL2 network stack
collapsed. `wsl --shutdown`; when that didn't fix it, switched to **mirrored networking**
(`%USERPROFILE%\.wslconfig` → `[wsl2] networkingMode=mirrored`, `dnsTunneling=true`).
**WSL apt: IPv6 unreachable + HashiCorp has no `resolute` suite** — force IPv4 in
apt.conf.d; install Terraform from the binary zip.
**Ansible "Could not resolve hostname vars"** — `vars:` was indented under `hosts:`. It
must be level with `hosts:` (group vars).
**apt "Permission denied" on the VMs** — added `ansible_become: true` on `docker_hosts`.
**Handler "Could not find service sshd"** — Ubuntu's service is `ssh`.
**`docker.sock` permission denied** — `usermod -aG docker ubuntu`; added to the docker role.

---

## Session 1 — 2026-07-21 · First node bring-up

**Goal:** Get the K8 Plus running Proxmox as the family-prod node, with an Ansible control
node driving it, plus a cloud-init template for Terraform.

**Outcome:** Proxmox VE 9 installed, network sorted, Ansible control node working, baseline
applied as code, cloud-init template scripted. Discovered the node was on **LVM**; decided
to reinstall on **ZFS**.

### The highlights
- **BIOS:** enabled SVM/virtualisation, set **Restore on AC Power Loss → Power On**.
- ⚠️ It's **Proxmox VE 9** (Debian 13 "trixie") — newer than the plan assumed. Matters for
  the repo format (deb822 `.sources`).
- **Ansible control node** on the Z13 (WSL Ubuntu): ssh keys, clone the repo, `ansible
  k8plus -m ping` → pong.
- Cloud-init template script seals VM **9000** for Terraform to clone.
- **Decision — reinstall on ZFS:** LVM works, but ZFS gives checksums (bit-rot protection
  for family photos), compression, snapshots, and replication. Node was empty, so cheap to
  redo.

### Errors & fixes 🔥
**`ping ... General failure`** — I'd set the node to `192.168.1.11`, but the LAN is
**192.168.0.0/24**. Confirmed with `ipconfig` (gateway 192.168.0.1), fixed the address +
gateway, then shifted the whole repo `192.168.1.x → 192.168.0.x`. **Lesson: confirm the
router's real subnet before hardcoding static IPs.**
**`apt: No package matching 'vim'`** — node had no DNS. `echo "nameserver 192.168.0.1" >
/etc/resolv.conf; apt update`.
**apt 401 on enterprise.proxmox.com** 🔥 — PVE 9 uses the deb822 `.sources` format, so the
old `.list` disabling didn't work:
```bash
rm -f /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
apt update
```
**node_exporter "Could not find service" in `--check`** — dry-run never installed the
package. Run without `--check`; guarded the role with `when: not ansible_check_mode`.
**`Unable to parse .../host.yml`** — the file is `hosts.yml` (plural); run inside `ansible/`.
**`storage 'local-zfs' does not exist`** — installed on LVM. Led to the ZFS reinstall.

---

## 🔥 Gotchas index — "it happened again" quick lookup

| Symptom | Root cause | Fix | Session |
|---|---|---|---|
| `ping ... General failure` (Windows) | Target on a different subnet | Match subnet; check `ipconfig` for real gateway | 1 |
| `apt: No package matching 'X'` | Node has no DNS | `echo "nameserver 192.168.0.1" > /etc/resolv.conf; apt update` | 1 |
| apt `401` enterprise.proxmox.com (PVE **or** PBS) | PVE 9 deb822 repos; enterprise still enabled | Remove the `*-enterprise.sources` file, add `pve-no-subscription.sources` | 1, 3 |
| Ansible "Could not find service" | Ran with `--check` | Run without `--check`; guard `when: not ansible_check_mode` | 1 |
| `Unable to parse .../host.yml` | Wrong filename | It's `hosts.yml` (plural); run inside `ansible/` | 1 |
| `storage 'local-zfs' does not exist` | Installed on LVM | `pvesm status`; reinstall on ZFS | 1 |
| Reinstalled node → SSH "host key changed" | New host key | `ssh-keygen -R <ip>` then reconnect | 1 |
| WSL "No route to host" (LAN too), Windows fine | WSL2 network stack collapsed | `wsl --shutdown`; then `.wslconfig` `networkingMode=mirrored` | 2 |
| WSL apt IPv6 / HashiCorp no `resolute` suite | WSL IPv6 unroutable + too-new codename | Force IPv4 in apt.conf.d; Terraform from binary zip | 2 |
| Terraform tfvars "Invalid block definition" | `export ...` pasted into the file | `export` is a shell cmd; tfvars holds only vars | 2 |
| VM SSH key = literal "PASTE: ..." | Pasted instruction, not key | `cat ~/.ssh/id_ed25519.pub`, paste real key | 2 |
| TF cloud-init disk → local-lvm | Provider default on ZFS host | Pin `datastore_id = "local-zfs"` in `initialization {}` | 2 |
| Ansible "Could not resolve hostname vars" | `vars:` indented under `hosts:` | Put `vars:` level with `hosts:` | 2 |
| VM apt "Permission denied" lock | ubuntu user, no become | `ansible_become: true` on docker_hosts | 2 |
| Handler "Could not find service sshd" | Ubuntu service is `ssh` | Handler `name: ssh` | 2 |
| `docker.sock` permission denied | User not in docker group | `usermod -aG docker ubuntu`; role does it for rebuilds | 2, 4 |
| `does not support NFS export` | exFAT can't be NFS-exported | Share via Samba/CIFS | 3 |
| CIFS `mount error(13)` | Samba password mismatch | Test `smbclient -U user` first; match creds file | 3 |
| Jellyfin LXC no GPU access | render group GID mismatch host vs container | `pct set -dev0 renderD128,gid=<container render gid>` | 3 |
| Cloudflare 525 on tunnel host | stale DNS record from old tunnel | delete hostname+DNS, re-add on new tunnel | 3 |
| Nextcloud "untrusted domain" | new proxy domain not allowlisted | `occ config:system:set trusted_domains` + overwriteprotocol | 3 |
| gluetun timeouts / unhealthy | ProtonVPN free blocks P2P | use a paid P2P VPN (Windscribe) | 3 |
| gluetun "region is not valid" | used VPN's UI label, not Gluetun's name | use exact name from Gluetun's printed list | 4 |
| Torrents stuck at metadata, DHT 0 | VPN server blocks P2P | switch to a P2P-allowed region (Netherlands) | 4 |
| Radarr download client won't connect | wrong host | host = `gluetun` (qbit shares its netns), port 8080 | 4 |
| T2 Mac won't boot USB | T2 blocks external boot | Recovery → Startup Security → No Security + allow external media | 6 |
| `applesmc ... failed with error -5` | T2 hides the SMC from the old driver | Harmless, ignore — T2 manages fans itself | 6 |
| MacBook unreachable, vmbr0 no IP | USB `r8152` NIC enumerates late → bridge portless | `ip link set nic0 up; systemctl restart networking`; `nic_watchdog` automates it | 6 |
| `ifreload -a` "another instance already running" | stale ifupdown lock | `systemctl restart networking` instead | 6 |
| Terraform wants to destroy/replace existing VMs | changed a create-time `clone` flag (e.g. `full`) | match the original value; always `plan` + `-target` the new resource | 7 |
| Grafana crash-loop "only one datasource default" | two provisioning files both `isDefault: true` | keep one default; empty/neutralize the other | 7 |
| CouchDB exits code 1 with NO logs | mounting a `local.d/*.ini` crashes CouchDB 3.5.2 | boot clean; apply config via `_config` HTTP API after startup | 7 |
| PBS backup lock / unreapable zombie / node won't die | disk stuck in kernel I/O (`D` state) | only a reboot clears it; then fix the disk | 7 |
| `zpool` SUSPENDED, disk gone from `lsblk` | bus-powered USB disk dropped off under load | powered enclosure/cable/port; `zpool clear` + scrub | 7 |
| Rebooting one node kills remote access to ALL nodes | only that node ran the Tailscale subnet router | run Tailscale on every node (own IP); redundant routers | 7 |
| Node self-locks-out after `tailscale up` | node accepted a route for its own `/24` | `tailscale set --accept-routes=false`; recover via web console | 7 |
| All non-VPN containers fail DNS (`Temporary failure in name resolution`) | Tailscale `--accept-dns` (MagicDNS) hijacked the resolver, no working upstream | `tailscale set --accept-dns=false` + `resolvectl dns <iface> 192.168.0.1 1.1.1.1`. On servers: Tailscale identity-only | 7 |
| VM SSH "REMOTE HOST IDENTIFICATION HAS CHANGED" | rebuilt VM = new host key vs stale known_hosts | `ssh-keygen -R <ip>` then reconnect (verify fingerprint via console for anything internet-facing) | 7 |
| Node offline, console spams `NIC Link Up 2500 → Down` | Intel i225/i226 (`igc`) EEE link-flap bug | `ethtool --set-eee <iface> eee off` (codified in `nic_tuning`); else force 1G / swap cable | 7 |
| LXC won't restart after a node reboot | manually-created LXCs default to onboot=0 | `pct set <id> -onboot 1` | 7 |
| Jellyfin LXC won't start: `Device /dev/dri/card0 does not exist` | GPU DRM nodes renumbered on reboot (card0→card1) | transcoding needs only `renderD128` → `pct set 200 --delete dev1`; durable: pass by `/dev/dri/by-path` | 7 |
| VM keeps OOM-shutting-down; `free` ≪ installed RAM | BIOS **UMA Frame Buffer** default (e.g. 4G) eats host RAM | BIOS → GFX → UMA Frame Buffer → 256M (headless). PVE9 already caps ARC — not the culprit | 8 |
| Fresh VM: `Unable to acquire the dpkg frontend lock` | cloud-init runs apt on first boot | `cloud-init status --wait` before apt (in the `docker` role now) | 8 |
| Grafana Loki panel "parse error ... empty-compatible" | all-`.*` label matchers | anchor with a real matcher e.g. `job="docker"`; set variable "All" value to `.+` | 8 |
| Winbox "connection timed out" to a new MikroTik | default IP 192.168.88.1 ≠ your subnet | connect **by MAC** (Winbox → Neighbors); works at L2 regardless of IP | 8 |
| KVM-over-IP: see the screen but can't type | web console not focused (USB HID is fine) | click the video area first; check `dmesg`/`lsusb` for the emulated keyboard | 8 |
| qBittorrent stuck 0 / DHT 0 / "firewalled" | gluetun tunnel went stale | `cd ~/stacks/media && docker compose restart gluetun qbittorrent` (region switch only if that fails) | 8 |
| Immich `immich-machine-learning` crash-loops: `NumPy … baseline optimizations (X86_V2) … machine doesn't support (X86_V2)` | Proxmox default VM CPU `kvm64` lacks x86-64-v2 (SSE4.2/POPCNT); ML's NumPy is built for v2 | Terraform `cpu { type = "host" }` (or a named `x86-64-v2`+ model); cold-boot the VM | 9 |
| Immich upload fails for large videos over the Cloudflare Tunnel | CF proxy caps request body at 100 MB (Free/Pro) | upload over Tailscale/LAN (no cap); keep the tunnel for viewing | 9 |
| New ZFS pool disappears / wrong disk after reboot | created pool on `/dev/sdX` (letters reshuffle) | always `zpool create` on `/dev/disk/by-id/…`; `zpool export/import -d /dev/disk/by-id` to fix | 9 |
| Tailscale role runs "OK" but `tailscale ip` → `NeedsLogin` | `creates: tailscaled.state` guard skips the join — daemon writes that file *before* login | guard on `tailscale status --json` backend state instead; recover now with a manual `tailscale up --ssh --accept-routes=false --accept-dns=false` | 9 |
| qBittorrent Web API returns `Forbidden` from the host | qbit is in gluetun's netns → request arrives from a Docker IP, not `127.0.0.1`, so localhost-bypass never fires | whitelist the Docker subnet (`172.16.0.0/12`) in qbit → Web UI → "Bypass auth for whitelisted IP subnets" | 10 |
| `systemctl start` as `ubuntu` → polkit "Authentication failure" | cloud-init user has no password to answer the polkit prompt | use `sudo systemctl …`; anything that *changes* systemd state needs root | 10 |
| Remote `*.lab` = "Non-existent domain" (e.g. `git.lab`) | client DNS is the corp/ISP resolver, not Tailscale's `100.100.100.100` → split-DNS not applied | enable "Use Tailscale DNS" + a `lab`-restricted split-DNS nameserver = AdGuard; hosts-file fallback (test with `ping`, not `nslookup`) | 10 |
| Pool `SUSPENDED`, disk present but renamed (`sdc`→`sde`) | **the rename is the *fingerprint* of a bus drop, not the cause** — ZFS matches vdevs by label GUID, not `/dev/sdX`, and a device sitting still never gets renamed | `dmesg -T`: several devices disconnecting in the *same second* = a **hub** reset, not a dying disk. `zpool clear <pool>` to release the brake | 11 |
| `zpool status` shows a vdev path that no longer exists (`ata-…` but only `usb-…` is present) | lost UAS/USB 3 — `ata-*` by-id needs ATA passthrough; behind a USB 2.0 hub the kernel falls back to `usb-storage` and issues a generic `usb-*` name | it's a **link-speed regression**: check `dmesg` for `super-speed`+`uas` (USB 3) vs `high-speed`+`usb-storage` (USB 2.0). Move to a direct port, then `zpool export` + `import -d /dev/disk/by-id` | 11 |
| Pool won't come back on its own after the disk returns | default `failmode=wait` freezes all pool I/O instead of erroring — a safety brake, and it does not self-clear | `zpool clear <pool>`. Read counters first: `CKSUM 0` = no corruption detected; **non-zero CKSUM on a single-vdev pool = unrepairable — stop before clearing** | 11 |
| Terraform `~ update in-place` unexpectedly reboots a VM | *in-place* means the **resource** isn't recreated — it says nothing about guest downtime. QEMU builds the vCPU at process start, so `cpu.type` changes force a stop/start | expect a power cycle for `cpu.type`; `reboot_after_update=false` does **not** make it hot-applicable. Stage disruptive VMs with `-target` | 11 |
| Terraform DNS/network change has no effect on an existing VM | cloud-init network config is **first-boot only** | fix live via netplan / `resolvectl`; the Terraform change only helps VMs built from then on | 11 |
| Local file appears named `root@<ip>` | `scp file root@ip` with the **colon missing** → plain local copy, no transfer | `scp file root@ip:/path` — and check `git status` before committing | 11 |
| Pushed, but the other remote is behind | `git push` only pushes to `origin`; a second remote silently drifts | `git push <remote> main`, or set up mirroring (pull-mirror avoids needing inbound webhooks) | 11 |
| Jellyfin library lists titles but **playback fails** after moving disks | the USB media disk re-enumerated (`sda`→`sdc`); `nofail` in fstab means "don't block boot" — it does **NOT** auto-mount on hotplug. `/mnt/media` stayed an empty dir, so the DB still had metadata but the files were gone | `mount -a` (UUID finds it at any letter) → `findmnt -t exfat` to confirm → **`pct restart 200`** | 11 |
| Host mount is correct but the container still sees an empty folder | an LXC bind mount is resolved **once, at container start** — mounting a filesystem under that path afterwards doesn't propagate into the container's mount namespace | restart the container so it re-resolves the bind mount | 11 |
| exFAT files unreadable to a service (permission denied) | exFAT has **no Unix permission model** — ownership is synthesized at mount time by `uid=`/`gid=`/`umask=`. Those mount options *are* the access control | preserve the exact `uid=1000,gid=1000,umask=002` options on any fstab edit | 11 |
| CI job fails cloning: `Could not resolve host: git.lab` — but the runner VM resolves it fine | **the VM and its containers have different resolvers.** Ubuntu's systemd-resolved puts the loopback stub `127.0.0.53` in `/etc/resolv.conf`; Docker strips loopback addresses when building a container's resolv.conf and falls back to `8.8.8.8` | give the **daemon** a resolver: `/etc/docker/daemon.json` → `{"dns":["192.168.0.31","1.1.1.1"]}`, validate with `python3 -m json.tool`, `systemctl restart docker` | 12 |
| A CI job fails before any of your `script:` lines appear in the log | every job **clones the repo first** — a fresh container has nothing in it. A failed fetch kills the job before your commands run | read the log above your script; `exit code 128` is git's generic failure | 12 |
| Docker won't start after editing `daemon.json` | JSON is stricter than YAML — double quotes only, no trailing commas, no comments | **always** `python3 -m json.tool /etc/docker/daemon.json` *before* `systemctl restart docker` | 12 |
| `nano /etc/…` lets you type, then "Permission denied" on save | `/etc` is root-owned; nano only fails at write time | `sudo nano`. For long edits, Ctrl+O to `/tmp/file`, then `sudo cp` into place | 12 |
| Job sits in "pending", no runner ever picks it up | job `tags:` must be a **subset** of the runner's tags — a mismatch never errors, it just waits forever | check Settings → CI/CD → Runners for the runner's actual tags; or enable "run untagged jobs" | 12 |
| An Ansible `when:` guard never skips — task runs every time | `when:` is **already** a Jinja expression context. Quoting a sub-expression (`'"X" in var.stdout'`) makes it a **string literal**, and a non-empty string is truthy → condition always True | drop the outer quotes; quote only the literal being searched: `'X' in var.stdout`. **Verify by running against a converged host and confirming `skipped`** | 12 |
| Task reports success but installed nothing (`curl … \| sh`) | in a pipeline the exit code is the **last** command's — a failed curl feeds empty input to `sh`, which exits 0 | `set -o pipefail && curl … \| sh` **plus** `executable: /bin/bash` (pipefail isn't POSIX sh; Ubuntu `/bin/sh` is dash) | 12 |
| Config change applied but the service never restarted | a handler was renamed without updating its `notify:` — the link is an exact string match and **fails silently** | rename both sides in one commit, then `grep -rn "notify:" ansible/` | 12 |
| `copy`/`template` produces different permissions on different hosts | no `mode:` → permissions fall back to the remote umask | always set `mode:`, and **quote it** — unquoted `0644` is parsed as an integer, not octal | 12 |
| CI tool crashes on import, traceback entirely inside `site-packages` | dependency problem, not your code — pinning one package while its deps float can resolve an incompatible pair | **pin what you've verified, not what you guessed**: let the resolver pick a set, read versions off a green run, then freeze them together | 12 |
| A lint/format config file seems to be ignored | tools differ on config discovery — ansible-lint walks *up* from cwd; yamllint checks only the *current* dir | it's a working-directory problem: run from the repo root and pass a path (`ansible-lint ansible/`) | 12 |
| Lint findings don't fall monotonically — clearing some reveals more | ansible-lint **profiles** (`min`→`basic`→`moderate`→`safety`→`shared`→`production`) promote you as you pass each tier | pin the bar explicitly: `profile: production` in `.ansible-lint`, so CI strictness can't drift on its own | 12 |
| A host/container can reach the internet but not `*.lab` | its resolver is the **router** (`192.168.0.1`). The router *advertises* AdGuard over DHCP but its own resolver forwards to the WAN upstream — it has no idea about internal rewrites | point every resolver at AdGuard **`192.168.0.31`** directly: cloud-init/netplan, `/etc/docker/daemon.json`, LXC `nameserver`. Prove it: `dig @192.168.0.1 git.lab` vs `dig @192.168.0.31 git.lab` | 12 |
| A config file written by hand on one host, never codified | it vanishes on rebuild and the original bug returns | put it in the role — and use `validate: <cmd> %s` on `copy`/`template` so a malformed file fails the task instead of breaking the service | 12 |
| AdGuard (or any DNS container) won't start on an Ubuntu host: port 53 in use | systemd-resolved holds `127.0.0.53:53`. Publishing the container on `0.0.0.0:53` claims 53 on **every** interface incl. loopback → collision | publish on the **specific LAN IP**: `192.168.0.31:53`. Then the stub keeps loopback, the container keeps the LAN IP, no conflict and no need to disable `DNSStubListener`. Verify with `ss -lnup 'sport = :53'` | 12 |
| A `--check --diff` run shows files being *created* on a host you thought was converged | that host is **behind the repo** — a task added after its last run | `--check --diff` is a drift detector, not just a preview. Worth running fleet-wide periodically as an audit | 12 |
| `get_url` reports `changed` in check mode every time | it can't verify a remote file without downloading, and check mode doesn't download | expected false positive; add a `checksum:` if you want certainty. **Check mode over-reports for tasks that reach out to something** | 12 |
| `{{ ansible_distribution_release }}` will silently become undefined | `INJECT_FACTS_AS_VARS` deprecation — ansible-core 2.24 stops auto-injecting facts as bare top-level vars | use `{{ ansible_facts['distribution_release'] }}`. Note **ansible-lint passed this at the production profile** — static analysis and runtime catch different things | 12 |

---

## Template for the next entry (copy this)

```markdown
## Session N — YYYY-MM-DD · <title>

**Goal:**
**Outcome:**

### What I did
- ...
​```bash
# commands
​```

### Errors & fixes 🔥
**Error:** <message>
**Cause:**
**Fix:**

### Next session
- ...
```
