# My Family Never Noticed: Migrating a Home Media Platform to a 3-Node Cluster with Zero Downtime

*Draft — fill in the [BRACKETED] details after the migration, and rewrite anything that doesn't sound like you.*

---

There's a special kind of pressure that comes from running infrastructure your family depends on. Nobody writes you an SLA, but the SLA exists. It's enforced at dinner.

For the past year, everything in my homelab lived on a single 2019 MacBook Pro running Proxmox: Jellyfin for our movie nights, GitLab and Jenkins for my projects, Grafana watching over it all, everything published through a Cloudflare Tunnel on my own domain. It worked — right up until the machine restarted. The MacBook has a quirk where its network adapter stays dead after a reboot until someone physically walks over and wakes it up. When that machine is also your family's entire media library, "someone" is always you, and it's always during a movie.

So I decided to fix it properly. Not by patching the NIC issue — by redesigning the whole thing around a principle I've since learned real platform teams live by: **match workload criticality to hardware reliability.**

## The design: production, infrastructure, and a lab that's allowed to die

I picked up two mini PCs — a GMKtec K8 Plus (32 GB RAM) and a G11 (16 GB) — plus a 2.5 GbE switch, and split my world into three tiers.

The K8 Plus became **family-prod**: Jellyfin with hardware transcoding on its Radeon iGPU, Immich for photo backup, Nextcloud for files, and the media automation stack. It also inherited the two 1 TB drives that hold our library. This node has one job: never make my family notice it exists.

The G11 became **core-infra**: the reverse proxy, DNS, the Cloudflare Tunnel endpoint, GitLab, and monitoring. Small, always-on, deliberately boring.

And the MacBook? It became the **lab** — a disposable playground for Kubernetes and CI/CD experiments. Its unreliable NIC went from being my biggest operational problem to being completely irrelevant, because nothing family-facing runs there anymore. (I did eventually automate the fix with a systemd watchdog that bounces the interface after boot — but now it protects my time, not movie night.)

## The trick that made zero downtime possible

Here's the thing I didn't appreciate until I planned this migration: a Cloudflare Tunnel completely decouples your public hostnames from the machines behind them. `jellyfin.mydomain.com` doesn't point at a server — it points at a tunnel, and the tunnel decides where traffic goes.

That means every service could migrate using the same five-step pattern, which I later learned is just a blue-green deployment wearing casual clothes:

First, deploy the new instance on the new node — from config files already committed to git, never by hand. Second, publish it at a temporary hostname (`jellyfin-new.mydomain.com`) through the tunnel. Third, test it properly: logins, playback, a 4K transcode, the works. Fourth, flip the real hostname's ingress rule to the new internal IP. Fifth, keep the old instance stopped-but-intact for a week, then delete it.

The flip itself takes seconds. Users keep the same URL, the same bookmarks, the same everything. My family watched [FILL IN: what they were watching] the evening I migrated Jellyfin, and the only evidence anything changed was a line in my git log.

## The details that actually took time

Zero downtime doesn't mean zero effort. A few honest notes from the trenches:

**Backups came first, and they were nearly worthless.** Before touching anything, I ran `gitlab-backup create` — and learned that a GitLab backup is useless without `/etc/gitlab/gitlab-secrets.json`, which it does *not* include. I also learned to test-extract every archive before trusting it. An unverified backup is a hope, not a backup. [FILL IN: anything that surprised you during backup]

**ZFS choices matter more than they look.** I deliberately did *not* mirror my two drives. Movies are re-downloadable; family photos are not. So one disk holds media, the other holds backups — including nightly Proxmox Backup Server snapshots and a weekly encrypted off-site sync. Losing redundancy on replaceable data bought me a dedicated backup disk for irreplaceable data. 3-2-1 for the photos, best-effort for the films.

**The torrent stack needed a kill-switch, not a lecture.** The media automation VM routes qBittorrent through a Gluetun VPN container using Docker's `network_mode: "service:gluetun"`. The torrent client literally has no network of its own — if the VPN drops, traffic stops. I tested this by killing the VPN container mid-download and watching everything freeze. Test your kill-switch before you need it.

**Migration order matters.** Family services first (get them safe), core infrastructure second (GitLab restored from backup, same version, *then* upgraded), and only when nothing pointed at the MacBook anymore did I wipe it. I kept a decommission checklist in the repo and refused to format the disk until every box was ticked.

## What I'd tell you if you're planning the same thing

The migration took [FILL IN: actual duration] spread over [FILL IN: weekends/evenings]. The technical work was maybe half of it. The other half was discipline: writing down the current state before changing it, committing every config before applying it, and resisting the urge to "quickly fix" things by hand on the new machines.

That discipline paid off in a way I didn't expect. Because every compose file, playbook, and tunnel config went into git from day one, I accidentally ended up with something more valuable than a working homelab: a repository that documents exactly how to build it again. That repo has since become the foundation of everything else I do — but that's the next post.

The best compliment my infrastructure ever received came about a week after the cutover, when I asked my family if they'd noticed anything different about Jellyfin.

"No. Why, did something change?"

Everything changed. That's the point.

---

*The full configuration for everything in this post — Terraform, Ansible, compose files, and the runbooks — is public at [github.com/YOUR-GH-USER/homelab-infra](https://github.com/YOUR-GH-USER/homelab-infra).*
