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
