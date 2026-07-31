# Runbook: rebuild the Jellyfin + cloudflared LXCs from scratch

**Use this only if PBS can't help you.** `pct restore <vmid> <backup>` restores config *and* data
in one step and is always the first thing to try. This runbook is the last-resort path: PBS is gone
too, or you're rebuilding on new hardware.

These two containers were created by hand and are the only part of the fleet not built from code.
Everything below was captured from a working system on 2026-07-31.

## Preconditions

- Proxmox VE 9 node with a `local-zfs` storage pool
- A Debian 12 LXC template in `local:vztmpl/` (`pveam update && pveam available | grep debian-12`)
- `/mnt/media` mounted on the host (see `/etc/fstab`, mounted by UUID)
- An iGPU present at `/dev/dri/renderD128`

---

## CT 200 — Jellyfin

```bash
pct create 200 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname jellyfin \
  --arch amd64 --ostype debian \
  --cores 4 --memory 4096 --swap 512 \
  --rootfs local-zfs:16 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.0.23/24,gw=192.168.0.1,type=veth \
  --nameserver 192.168.0.31 \
  --features nesting=1 \
  --unprivileged 1 \
  --onboot 1

pct set 200 -mp0 /mnt/media,mp=/media,ro=1
pct start 200
```

### Then the GPU — do NOT copy the GID blindly

```bash
# 1. find the render group GID INSIDE the container
pct exec 200 -- getent group render        # e.g. render:x:104:

# 2. pass the device through with THAT gid
pct set 200 -dev0 /dev/dri/renderD128,gid=104
pct restart 200

# 3. verify
pct exec 200 -- ls -l /dev/dri/renderD128
```

### Why each non-obvious flag is there

| Flag | Reason |
|---|---|
| `-dev0 /dev/dri/renderD128` | **Only `renderD128`.** Do not pass `card0` — DRM nodes renumber across reboots (`card0`→`card1`) and the container then refuses to start with *"Device /dev/dri/card0 does not exist"*. Transcoding only ever needs the render node. |
| `gid=104` | The GID **inside** the container, not the host's. Host render GID is 993, the container's is 104; this flag does the mapping. Verify per rebuild — it can differ by Debian release. |
| `--onboot 1` | Manually created LXCs default to `onboot=0` and stay down after a node reboot. This bit us once already. |
| `--unprivileged 1` | Container root is not host root. Keep it. |
| `--features nesting=1` | Required for systemd to work properly inside the container. |
| `mp0 ... ro=1` | Media is mounted **read-only**. Jellyfin has no business writing to the library. |
| `--nameserver 192.168.0.31` | AdGuard. **Not `192.168.0.1`** — the router does not resolve `*.lab`. |

### ⚠️ The exFAT permission dependency

`/mnt/media` is exFAT, mounted with `uid=1000,gid=1000,umask=002` (see `/etc/fstab`). exFAT carries
no Unix permissions, so those mount options *synthesise* them: files become `0664`, directories `0775`.

In an **unprivileged** container, host UID 1000 falls outside the container's mapped range, so the
files appear owned by `nobody`. Jellyfin can still read them **only because "other" has the read
bit** — which comes from `umask=002`.

**If anyone ever tightens that umask (e.g. to `077`), Jellyfin silently loses access to the entire
library** while the mount still looks perfectly healthy on the host. Same failure signature as a
missing mount: library lists titles, playback fails.

### Install Jellyfin

```bash
pct exec 200 -- bash -c "apt update && apt install -y curl gnupg"
# then the official Jellyfin apt repo — see https://jellyfin.org/docs/general/installation/linux
```

Jellyfin's own data (users, libraries, watch state, metadata) lives in `/var/lib/jellyfin` and
`/etc/jellyfin` **inside the container**. That is what PBS backs up, and there is no copy of it in
this repo. A from-scratch rebuild means recreating user accounts and re-scanning the library.

---

## CT 201 — cloudflared

```bash
pct create 201 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname cloudflared \
  --arch amd64 --ostype debian \
  --cores 1 --memory 256 --swap 256 \
  --rootfs local-zfs:4 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.0.24/24,gw=192.168.0.1,type=veth \
  --nameserver 1.1.1.1 \
  --features nesting=1 \
  --unprivileged 1 \
  --onboot 1
pct start 201
```

**Note the nameserver is deliberately `1.1.1.1`, not AdGuard.** This container is the public front
door — if it can't resolve Cloudflare's edge, the family loses external access to Jellyfin and
Nextcloud. Don't make it depend on a DNS container running on a different node.

### Tunnel credentials

The tunnel's credentials are **not in this repo** and cannot be. Recovery options, in order:

1. Restore CT 201 from PBS — credentials come back with it.
2. Otherwise: create a new tunnel in the Cloudflare dashboard, install the new token, and
   re-point the `jellyfin` and `nextcloud` public hostnames at it.

Only those two hostnames should be public — see ADR-003.

---

## Verification

Work down the list; stop at the first failure.

```bash
# both containers up and set to autostart
pct list

# Jellyfin can see the GPU
pct exec 200 -- ls -l /dev/dri/renderD128

# Jellyfin can read the media (must NOT be empty)
pct exec 200 -- ls /media

# DNS works in each
pct exec 200 -- getent hosts jellyfin.org
pct exec 201 -- getent hosts cloudflare.com
```

Then, from a browser:

1. Jellyfin web UI reachable on `192.168.0.23:8096`
2. Play a video that requires transcoding — confirm hardware transcode in the Jellyfin dashboard,
   not CPU
3. Public hostnames resolve and load through the tunnel

Finally, **reboot the node** and re-run `pct list`. If either container is down, `onboot` didn't
stick.

---

## Getting Ansible into a fresh container

Both LXCs are in the `lxc_hosts` inventory group and get `common` + `node_exporter` from
`site.yml`. But a **fresh** container has no `authorized_keys`, and Ansible can't configure a host
it can't log into. Bootstrap from the Proxmox host:

```bash
# from the control node
scp ~/.ssh/id_ed25519.pub root@192.168.0.11:/tmp/jc.pub

ssh root@192.168.0.11 'for id in 200 201; do
  pct exec $id -- install -d -m 0700 /root/.ssh
  pct push $id /tmp/jc.pub /root/.ssh/authorized_keys --perms 600
done; rm /tmp/jc.pub'

# VERIFY before going further — both must print a hostname
ssh root@192.168.0.23 hostname
ssh root@192.168.0.24 hostname

ansible-playbook site.yml --limit lxc_hosts
```

⚠️ **Verify the key works first.** The `common` role sets `PasswordAuthentication no`; running it
with a broken key locks you out of the container. Recoverable with `pct enter <id>` from the host,
but easier to avoid.

## Known gaps

- The container definitions above are documentation, not code. Terraform
  (`proxmox_virtual_environment_container` + `terraform import`) would make them reproducible.
- Jellyfin's application data (users, libraries, watch state) has no representation outside PBS.
- `common` installs `qemu-guest-agent`, which is meaningless in a container. Harmless; tidy fix is
  to make the package list a role variable and override it for `lxc_hosts`.
