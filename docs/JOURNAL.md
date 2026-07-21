# 🛠️ Homelab Build Journal

A running log of everything done to the homelab — every command, every error, and
the fix that worked. Future-me: **Ctrl-F your error message** (e.g. "401", "DNS",
"general failure") to jump straight to what solved it.

**How to use this file**
- Newest session at the top of the log.
- Each session: what we did, the exact commands, what broke, and how it was fixed.
- The 🔥 **Gotchas index** at the bottom is the fast lookup for "this happened again".

**Fleet quick reference**

| Node | IP | Role | Notes |
|---|---|---|---|
| k8plus | 192.168.0.11 | family-prod | Proxmox VE 9, ZFS. 2×1TB HDD to be added at cutover |
| g11 | 192.168.0.12 | core-infra | not built yet |
| macbook | 192.168.0.13 | lab (disposable) | not built yet; flaky NIC |
| Z13 (control) | 192.168.0.239 (DHCP) | Ansible control node (WSL) | — |
| Cluster net | 10.10.10.0/24 | corosync/migration/backup | NIC2, added when g11 joins |

- **LAN / subnet:** 192.168.0.0/24, gateway 192.168.0.1
- **Switch:** TP-Link TL-SG108S-M2 (8-port 2.5G, *unmanaged* — no VLANs)
- **Web domain:** your-domain.example (Cloudflare Tunnel) · **Email:** Proton Mail on your-mail.example
- **Repo:** homelab-infra (GitHub public mirror ← self-hosted GitLab later)

---
## Session 3 — 2026-07-21/22 · Media platform, Cloudflare consolidation, IaC deploys

**Goal:** Move the media disk to the K8 Plus, bring up Jellyfin with hardware
transcoding, back everything up, consolidate Cloudflare onto the new infra, and
deploy the media automation stack as code.

**Outcome:** Family media platform fully live on the new node (Jellyfin + HW
transcode, zero-downtime cutover). PBS nightly backups running. Cloudflare tunnel
migrated off the MacBook to its own LXC; admin now Tailscale-only; public surface
trimmed to Jellyfin + Nextcloud. Media stack deployed via **Ansible + Vault** (real
IaC). Only blocker: ProtonVPN **free** can't do P2P — need a paid P2P VPN
(Windscribe paid confirmed to work) to finish downloads.

### 1. Media disk move (exFAT)
- Shut down MacBook, moved 2×WD HDDs to K8 Plus.
- Disks: **sda1 = 2TB exFAT "JC-Media"** (890 GB of Movies/TV), **sdb1 = 1TB ext4** (empty).
```bash
apt-get install -y exfatprogs
mkdir -p /mnt/media
mount -t exfat -o ro UUID=621B-F154 /mnt/media   # verified library read-only first
# then rw + persistent:
echo 'UUID=621B-F154 /mnt/media exfat defaults,nofail,uid=1000,gid=1000,umask=002 0 0' >> /etc/fstab
```

### 2. Jellyfin LXC + iGPU passthrough
- Debian 12 unprivileged LXC (CT 200), bind-mount `/mnt/media` → `/media` (ro).
- Passed the Radeon 780M in:
```bash
pct set 200 -dev0 /dev/dri/renderD128,gid=104   # gid must match container's render group
pct set 200 -dev1 /dev/dri/card0,gid=44
```
- Installed jellyfin + mesa-va-drivers; `vainfo` confirmed H264/HEVC/VP9/AV1 decode + HW encode.
- Cutover: repointed the Cloudflare tunnel to `192.168.0.23:8096` — family kept the same URL, zero downtime.

### 3. Backups — ZFS pool + PBS
```bash
zpool create -f -o ashift=12 backup /dev/disk/by-id/ata-WDC_WD10SDZM-...   # the 1TB disk
zfs set compression=lz4 backup; zfs create backup/pbs
# PBS on host:
apt install -y proxmox-backup-server
proxmox-backup-manager datastore create main /backup/pbs
```
Added PBS as PVE storage, scheduled nightly backups of all guests. Off-site (B2/R2)
deferred until Immich holds real photos.

### 4. Cloudflare consolidation
- Created a NEW tunnel `lxc-tunnel`, connector runs in a small cloudflared LXC (CT 201) on K8 Plus.
- Added only the hostnames we're keeping: `jellyfin` → .23:8096, `nextcloud` → .21:8081.
- Deleted the old `macbook-proxmox-hub` tunnel + its admin DNS records (proxmox/grafana/jenkins/git/npm).
- Result: public surface = Jellyfin + Nextcloud only; admin = Tailscale-only. (ADR-003 done.)

### 5. Tailscale (admin access)
```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --advertise-routes=192.168.0.0/24 --accept-routes   # subnet router
```
Approved the /24 route in the admin console. Reaches the whole LAN over Tailscale — so
dropping the public admin hostnames cost nothing.

### 6. Media share (Samba/CIFS)
Host owns `/mnt/media`; media-vm needs write access → shared it. **NFS failed** (exFAT
can't be NFS-exported), so used Samba:
```bash
# host: samba share [media], user smbmedia, force user = root
# media-vm: mount via cifs-utils with credentials file, uid=1000
//192.168.0.11/media /mnt/media cifs credentials=/root/.smbmedia,uid=1000,gid=1000,nofail 0 0
```

### 7. IaC deploy — Ansible + Vault (the big one)
- New role `compose_stack`: copies a stack's compose from the repo, renders `.env` from
  vaulted vars, runs `docker compose up`.
- `deploy-stacks.yml` maps hosts → stacks. Secrets in `ansible-vault`-encrypted
  `group_vars/docker_hosts/vault.yml` (safe to commit).
```bash
ansible-galaxy collection install -r requirements.yml
ansible-vault encrypt inventory/group_vars/docker_hosts/vault.yml
ansible-playbook deploy-stacks.yml --limit media-vm --ask-vault-pass
```
Media stack (gluetun, qbittorrent, prowlarr, radarr, sonarr, jellyseerr) all came up.

### Errors & fixes 🔥
**exFAT can't be NFS-exported** ("does not support NFS export") → use **Samba/CIFS** instead.

**CIFS `mount error(13) Permission denied`** → Samba password mismatch. Verify auth
independently with `smbclient //host/media -U smbmedia` before touching fstab.

**PBS enterprise repo 401** (blocked `apt update`, incl. Tailscale install) → same as PVE:
`rm /etc/apt/sources.list.d/pbs-enterprise.sources`. Both PVE **and** PBS ship an enterprise repo.

**Jellyfin LXC GPU: render group GID mismatch** → device came in as gid 993 but container's
`render` group was 104. Fix: `pct set 200 -dev0 /dev/dri/renderD128,gid=104` (match container).

**Cloudflare 525 on a tunnel hostname** → stale DNS record from the old tunnel. Delete the
hostname from both tunnels, delete the DNS record, re-add cleanly on the new tunnel.

**Nextcloud "untrusted domain"** through the tunnel:
```bash
docker compose exec -u www-data nextcloud php occ config:system:set trusted_domains 1 --value=nextcloud.your-domain.example
docker compose exec -u www-data nextcloud php occ config:system:set overwriteprotocol --value=https
```

**`docker.sock permission denied` on media-vm** → user not in docker group (media-vm missed
the role's usermod from timing): `sudo usermod -aG docker ubuntu && newgrp docker`.

**gluetun unhealthy, all traffic i/o timeout** → **ProtonVPN FREE blocks P2P** (and port
forwarding is paid-only). Not a bug — free tier can't torrent. Need a paid P2P VPN.
✅ Kill-switch validated: with the VPN down, qBittorrent had NO network — no leak possible.

### Next session
- Swap vault to **Windscribe** (provider=windscribe, WireGuard private key + address;
  VPN_PORT_FORWARDING off), redeploy → gluetun healthy → downloads work.
- Configure Prowlarr indexers → Radarr/Sonarr (root folders /media/Movies, /media/TV Show,
  download client qBittorrent) → Jellyseerr (link to Jellyfin).
- Redeploy Nextcloud via the Ansible compose_stack role (Task #27), retire its plaintext .env.
- Next week: 1TB SSD internal → Immich `data` pool → off-site backup.

---

### Gotchas to add to the index
| Symptom | Root cause | Fix | Session |
|---|---|---|---|
| `does not support NFS export` | exFAT can't be NFS-exported | Share via Samba/CIFS instead | 3 |
| CIFS `mount error(13)` | Samba password mismatch | Test with `smbclient -U user` first; match creds file | 3 |
| PBS `apt` 401 enterprise repo | PBS also ships an enterprise repo | `rm /etc/apt/sources.list.d/pbs-enterprise.sources` | 3 |
| Jellyfin LXC no GPU access | render group GID mismatch host vs container | `pct set -dev0 renderD128,gid=<container render gid>` | 3 |
| Cloudflare 525 on tunnel host | stale DNS record from old tunnel | delete hostname+DNS, re-add on new tunnel | 3 |
| Nextcloud "untrusted domain" | new proxy domain not allowlisted | `occ config:system:set trusted_domains` + overwriteprotocol | 3 |
| gluetun timeouts / unhealthy | ProtonVPN free blocks P2P | use a paid P2P VPN (Windscribe/Mullvad/Proton Plus) | 3 |

---

## Session 2 — 2026-07-21 · VMs as code + first service live

**Goal:** Reinstall k8plus on ZFS, then Terraform the family VMs, Ansible them
into Docker hosts, and deploy the first real service.

**Outcome:** 🎉 Full arc complete — bare metal → Proxmox (ZFS) → Terraform VMs →
Ansible/Docker → **Nextcloud running in the browser** at http://192.168.0.21:8081.
Every layer reproducible from git.

### What we did
1. Reinstalled k8plus on **ZFS (RAID0)**; re-baselined with one command:
   ```bash
   ssh-keygen -R 192.168.0.11 && ssh-copy-id root@192.168.0.11
   ansible-playbook bootstrap.yml --limit k8plus     # all Session 1 fixes baked in → clean
   ```
2. Built cloud-init template 9000 on ZFS:
   ```bash
   sed -i 's/STORAGE=local-lvm/STORAGE=local-zfs/' scripts/create-cloud-template.sh
   ssh root@192.168.0.11 'bash -s' < scripts/create-cloud-template.sh
   ```
3. Installed **Terraform 1.15.8** (binary, not apt — see gotcha) and created a
   Proxmox API token:
   ```bash
   ssh root@192.168.0.11 "pveum user token add root@pam terraform --privsep 0"
   export TF_VAR_pve_api_token='root@pam!terraform=<secret>'   # single quotes! (the ! )
   ```
4. Terraformed the two family VMs (targeted, since g11/macbook don't exist yet):
   ```bash
   terraform init
   terraform apply \
     -target='proxmox_virtual_environment_vm.family["family-vm"]' \
     -target='proxmox_virtual_environment_vm.family["media-vm"]'
   # Apply complete! Resources: 2 added.
   ```
5. Ansible → Docker on both VMs, then deployed Nextcloud:
   ```bash
   ansible-playbook site.yml --limit docker_hosts
   scp compose/family/{docker-compose.yml,.env.example} ubuntu@192.168.0.21:~/stacks/family/
   # (renamed .env.example → .env, set NC_DB_PASSWORD)
   docker compose up -d nextcloud nextcloud-db
   ```

### Errors & fixes 🔥
**`export TF_VAR_...` → "Invalid block definition" in terraform.tfvars**
Cause: pasted the shell `export` line INTO terraform.tfvars.
Fix: `export` is a terminal command, not a file line. tfvars holds only
`pve_endpoint`, `template_id`, `ssh_pubkey`. Token goes in the env var (single-quoted).

**SSH key showed as literal `"PASTE: cat ~/.ssh/id_ed25519.pub"` in the plan**
Cause: pasted the instruction text, not the key output.
Fix: `cat ~/.ssh/id_ed25519.pub`, paste the real `ssh-ed25519 AAAA...` line.

**Terraform cloud-init disk → `local-lvm` (doesn't exist on ZFS)**
Fix: pin `datastore_id = "local-zfs"` inside each `initialization {}` block.

**WSL lost all network mid-session ("No route to host", even to LAN)** 🔥🔥
Cause: WSL2 virtual network stack collapsed (Windows browser still fine).
Fix: `wsl --shutdown` first; when that failed, switched to **mirrored networking**:
`%USERPROFILE%\.wslconfig` → `[wsl2]\nnetworkingMode=mirrored\ndnsTunneling=true`,
then `wsl --shutdown`. (Bonus: WSL now reaches LAN hosts natively.)

**apt in WSL: IPv6 unreachable + HashiCorp has no `resolute` (26.04) suite**
Fix: force IPv4 (`Acquire::ForceIPv4 "true"` in apt.conf.d), remove the hashicorp
apt list, install Terraform from the **binary zip** instead.

**Ansible → docker VMs: "Could not resolve hostname vars"**
Cause: `vars:` indented under `hosts:`, so Ansible read it as a host.
Fix: `vars:` must be level with `hosts:` (group vars). Overwrote hosts.yml cleanly.

**apt "Permission denied" locking /var/lib/apt on the VMs**
Cause: `ubuntu` isn't root and the play had no privilege escalation.
Fix: `ansible_become: true` on the `docker_hosts` group (ubuntu has passwordless sudo).

**Handler "Could not find the requested service sshd"**
Cause: Debian/Ubuntu service is `ssh`, not `sshd`.
Fix: handler → `name: ssh`.

**`docker compose`: "permission denied ... /var/run/docker.sock"**
Cause: `ubuntu` not in the `docker` group.
Fix: `sudo usermod -aG docker ubuntu && newgrp docker`. Added to the `docker`
Ansible role so future hosts get it automatically.

### Next session
- Move the 2×1TB HDDs from the MacBook → K8 Plus; create ZFS media/backup pools.
- Deploy Immich (photos) + the media automation stack (Jellyseerr/Radarr/Sonarr/
  qBittorrent+Gluetun) — test the VPN kill-switch BEFORE any torrent.
- Jellyfin LXC with iGPU passthrough; cut the family over (blue-green).

---

## Session 1 — 2026-07-21 · First node bring-up

**Goal:** Get the K8 Plus running Proxmox as the family-prod node, with an
Ansible control node driving it, plus a cloud-init template for Terraform.

**Outcome:** Proxmox VE 9 installed, network sorted, Ansible control node working,
baseline applied as code, cloud-init template scripted. Discovered the node was
installed on **LVM**; decided to reinstall on **ZFS** (see end).

### 1. Proxmox install (K8 Plus)
- Wrote Proxmox VE ISO to USB (Rufus DD mode / balenaEtcher).
- BIOS: enabled **SVM/virtualisation**, set **Restore on AC Power Loss → Power On**.
- Installed to the 512 GB NVMe.
- ⚠️ Turned out to be **Proxmox VE 9** (Debian 13 "trixie") — newer than the plan
  assumed (PVE 8). Matters for repo format (see gotcha #4).

### 2. Wrong subnet — "general failure" on ping  🔥
**Problem:** Set static IP to `192.168.1.11`; couldn't ping it from the Z13,
Windows returned `PING: transmit failed. General failure.`

**Cause:** The home router's LAN is **192.168.0.0/24**, not 192.168.1.x. The node
was on an unreachable island.

**Diagnosis:**
```bash
ipconfig            # on the Z13 → IPv4 192.168.0.239, gateway 192.168.0.1
```

**Fix:** On the Proxmox console, edited the address + gateway:
```bash
nano /etc/network/interfaces
#   address 192.168.1.11/24  → 192.168.0.11/24
#   gateway 192.168.1.1      → 192.168.0.1
ifreload -a
ip a                 # confirm 192.168.0.11
ping 192.168.0.1     # confirm router reachable
```
Then the whole repo IP plan was shifted `192.168.1.x → 192.168.0.x`.

**Lesson:** Always confirm the router's real subnet (`ipconfig` / `ip route`)
before hardcoding static IPs.

### 3. Ansible control node on the Z13 (WSL)
```powershell
wsl --install                       # admin PowerShell; installs Ubuntu
```
```bash
# inside WSL Ubuntu
sudo apt update && sudo apt install -y ansible git openssh-client
ssh-keygen -t ed25519 -C "ansible@z13"
ssh-copy-id root@192.168.0.11
ssh root@192.168.0.11 "hostname"    # passwordless login works
git clone git@github.com:YOUR-GH-USER/homelab-infra.git
cd homelab-infra/ansible
ansible k8plus -m ping              # → pong
```

**Gotcha:** first ping failed — `Unable to parse .../inventory/host.yml`. The file
is **`hosts.yml`** (plural). Run from inside `ansible/` so `ansible.cfg` finds it,
or pass the exact name.

### 4. Bootstrap playbook — three errors, three fixes
Ran the safe baseline (NOT full `site.yml` — that would apply the firewall and
lock out LAN SSH before Tailscale exists):
```bash
ansible-playbook bootstrap.yml --limit k8plus
```

**Error A — "No package matching 'vim' is available"  🔥**
Cause: node had **no DNS**, so `apt update` fetched nothing.
```bash
ssh root@192.168.0.11
ping -c2 1.1.1.1            # internet OK by IP
ping -c2 deb.debian.org    # FAILED → DNS broken
echo "nameserver 192.168.0.1" > /etc/resolv.conf   # or 1.1.1.1
apt update                 # now pulls package lists
```

**Error B — node_exporter "Could not find the requested service"  🔥**
Cause: it was a `--check` (dry-run) run — apt didn't actually install the package,
so the enable step had no service to find.
Fix: run **without** `--check`; also made the role check-mode-safe with
`when: not ansible_check_mode`.

**Error C — apt 401 Unauthorized on enterprise.proxmox.com  🔥**
Cause: **Proxmox VE 9 uses the deb822 `.sources` format**, so the old `.list`
disabling didn't remove the enterprise repos.
```bash
ssh root@192.168.0.11
rm -f /etc/apt/sources.list.d/pve-enterprise.sources
rm -f /etc/apt/sources.list.d/ceph.sources
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
apt update                 # clean, no 401
```
Role `proxmox_postinstall` updated to handle deb822 (version-aware via
`ansible_distribution_release`). After fixes: **PLAY RECAP failed=0** ✅

### 5. Git identity + auth
```bash
git config --global user.name "Jocelyn Choo"
git config --global user.email "..."     # use GitHub noreply for privacy on public repo
# SSH auth (reused the Ansible key):
cat ~/.ssh/id_ed25519.pub                # → add to GitHub → Settings → SSH keys
git remote set-url origin git@github.com:YOUR-GH-USER/homelab-infra.git
ssh -T git@github.com
git push
```

### 6. Cloud-init template (script: scripts/create-cloud-template.sh)
```bash
ssh root@192.168.0.11 'bash -s' < scripts/create-cloud-template.sh
```
Downloads Ubuntu 24.04 cloud image, bakes in qemu-guest-agent, seals VM **9000**
as a template for Terraform to clone.

**Gotcha — "storage 'local-zfs' does not exist":** the install had used **LVM**,
so the storage was `local-lvm`. Confirmed with:
```bash
pvesm status                  # Name column → local-lvm
qm destroy 9000               # remove the half-created VM shell
```

### 7. Decision: reinstall on ZFS
LVM works, but ZFS gives checksums (bit-rot protection for family photos),
compression, snapshots, and node-to-node replication — all valuable for the
family-prod node, and the repo/plan assume ZFS. Node was empty, so reinstalling
now is cheap.

**Reinstall checklist (in progress at end of session):**
- [ ] Boot Proxmox USB → installer → Filesystem = **zfs (RAID0)**
- [ ] Network: `192.168.0.11/24`, gw `192.168.0.1`, **DNS `192.168.0.1`**, host `k8plus`
- [ ] `ssh-keygen -R 192.168.0.11 && ssh-copy-id root@192.168.0.11`
- [ ] `ansible-playbook bootstrap.yml --limit k8plus`  ← all tonight's fixes baked in
- [ ] `sed -i 's/STORAGE=local-lvm/STORAGE=local-zfs/' scripts/create-cloud-template.sh`
- [ ] `ssh root@192.168.0.11 'bash -s' < scripts/create-cloud-template.sh`

### Next session
- Verify template 9000 exists on ZFS.
- `terraform apply` the family + media VMs (family-vm .21, media-vm .22).
- Then: Docker via Ansible → deploy family/media compose stacks.

---

## 🔥 Gotchas index — "it happened again" quick lookup

| Symptom | Root cause | Fix | Session |
|---|---|---|---|
| `ping ... General failure` (Windows) | Target on a different subnet than the Z13 | Match subnet; check `ipconfig` for real gateway | 1 |
| `apt: No package matching 'X'` | Node has no DNS; `apt update` fetched nothing | `echo "nameserver 192.168.0.1" > /etc/resolv.conf; apt update` | 1 |
| apt `401 Unauthorized` enterprise.proxmox.com | PVE 9 deb822 repos; enterprise still enabled | Remove `*.sources` enterprise files, add `pve-no-subscription.sources` | 1 |
| Ansible service task "Could not find service" | Ran with `--check`; package never actually installed | Run without `--check`; guard with `when: not ansible_check_mode` | 1 |
| `Unable to parse .../host.yml` | Wrong filename | It's `hosts.yml` (plural); run inside `ansible/` | 1 |
| `storage 'local-zfs' does not exist` | Installed on LVM, not ZFS | `pvesm status` to get real name; reinstall on ZFS or use `local-lvm` | 1 |
| Reinstalled node → SSH "host key changed" warning | New host = new host key | `ssh-keygen -R 192.168.0.11` then reconnect | 1 |
| WSL "No route to host" (even to LAN), Windows fine | WSL2 network stack collapsed | `wsl --shutdown`; if stuck → `.wslconfig` `networkingMode=mirrored` | 2 |
| WSL apt fails IPv6 / HashiCorp no `resolute` suite | WSL IPv6 unroutable + too-new Ubuntu codename | Force IPv4 in apt.conf.d; install Terraform from binary zip | 2 |
| Terraform tfvars "Invalid block definition" | `export ...` line pasted into the file | `export` is a shell cmd; tfvars holds only variables | 2 |
| VM SSH key = literal "PASTE: ..." | Pasted instruction text, not key | `cat ~/.ssh/id_ed25519.pub`, paste real key | 2 |
| TF cloud-init disk → local-lvm not found | Provider default on ZFS host | Pin `datastore_id = "local-zfs"` in `initialization {}` | 2 |
| Ansible "Could not resolve hostname vars" | `vars:` indented under `hosts:` | Put `vars:` level with `hosts:` (group vars) | 2 |
| VM apt "Permission denied" lock | ubuntu user, no become | `ansible_become: true` on docker_hosts group | 2 |
| Handler "Could not find service sshd" | Ubuntu service is `ssh` | Handler `name: ssh` | 2 |
| `docker.sock` permission denied | user not in docker group | `usermod -aG docker ubuntu && newgrp docker` | 2 |

---

## Template for the next entry (copy this)

```markdown
## Session N — YYYY-MM-DD · <title>

**Goal:**
**Outcome:**

### What we did
- ...
​```bash
# commands
​```

### Errors & fixes 🔥
**Error:** <message>
**Cause:**
**Fix:**
​```bash
# fix commands
​```

### Next session
- ...
```
