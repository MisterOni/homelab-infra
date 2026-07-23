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
| k8plus | 192.168.0.11 | family-prod (Jellyfin, Nextcloud, media, PBS) | 🟢 live · clustered |
| g11 | 192.168.0.12 | core-infra (proxy/DNS/GitLab/monitoring — coming) | 🟢 live · clustered |
| macbook | 192.168.0.13 | lab (disposable K3s node — coming) | 🟢 live · clustered |
| Z13 (control) | 192.168.0.239 (DHCP) | Ansible control node (WSL) | 🟢 |
| VMs | family-vm .21 · media-vm .22 | Docker hosts on k8plus | 🟢 live |

- **LAN / subnet:** 192.168.0.0/24, gateway 192.168.0.1
- **Switch:** 8-port 2.5G unmanaged (MikroTik managed switch on the way → VLANs later)
- **Web:** your-domain.example (Cloudflare Tunnel) · **Email:** Proton Mail on your-mail.example
- **Cluster:** 3-node Proxmox VE 9, quorate (survives losing any one node)
- **Repo:** homelab-infra (public) ← the whole build as code

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
