# My Family Never Noticed: Migrating a Home Media Platform to a 3-Node Cluster with Zero Downtime

*Built over a handful of July evenings in 2026. Every config in this post is public — link at the bottom.*

---

There's a special kind of pressure that comes from running infrastructure your family depends on. Nobody writes you an SLA, but the SLA exists. It's enforced at dinner.

For the past year, everything in my homelab lived on a single 2019 MacBook Pro running Proxmox: Jellyfin for our movie nights, GitLab and Jenkins for my projects, Grafana watching over it all, everything published through a Cloudflare Tunnel on my own domain. It worked — right up until the machine restarted. The MacBook has a quirk where its network adapter stays dead after a reboot until someone physically walks over and wakes it up. When that machine is also your family's entire media library, "someone" is always you, and it's always during a movie.

So I decided to fix it properly. Not by patching the NIC issue — by redesigning the whole thing around a principle I've since learned real platform teams live by: **match workload criticality to hardware reliability.**

## The design: production, infrastructure, and a lab that's allowed to die

I picked up two mini PCs — a GMKtec K8 Plus (32 GB RAM) and a G11 (16 GB) — plus a 2.5 GbE switch, and split my world into three tiers.

The K8 Plus became **family-prod**: Jellyfin with hardware transcoding on its Radeon iGPU, Immich for photo backup, Nextcloud for files, and the media automation stack. It also inherited the two 1 TB drives that hold our library. This node has one job: never make my family notice it exists.

The G11 is earmarked as **core-infra**: the reverse proxy, DNS, GitLab, and monitoring. Small, always-on, deliberately boring. It's the next node I'll build; for now the Cloudflare Tunnel connector runs in its own tiny container on the family-prod node, which was enough to get the family tier fully live first.

And the MacBook? It becomes the **lab** — a disposable playground for Kubernetes and CI/CD experiments. Its unreliable NIC goes from being my biggest operational problem to being completely irrelevant, because nothing family-facing will run there. The plan is to automate the fix with a systemd watchdog that bounces the interface after boot anyway — but now it'll protect my time, not movie night.

## The trick that made zero downtime possible

Here's the thing I didn't appreciate until I planned this migration: a Cloudflare Tunnel completely decouples your public hostnames from the machines behind them. `jellyfin.mydomain.com` doesn't point at a server — it points at a tunnel, and the tunnel decides where traffic goes.

That means every service could migrate using the same five-step pattern, which I later learned is just a blue-green deployment wearing casual clothes:

First, deploy the new instance on the new node — from config files already committed to git, never by hand. Second, publish it at a temporary hostname (`jellyfin-new.mydomain.com`) through the tunnel. Third, test it properly: logins, playback, a 4K transcode, the works. Fourth, flip the real hostname's ingress rule to the new internal IP. Fifth, keep the old instance stopped-but-intact for a week, then delete it.

The flip itself takes seconds. Users keep the same URL, the same bookmarks, the same everything. The evening I cut Jellyfin over, I tested it from my phone on cellular data — new node, same `jellyfin.mydomain.com`, a movie playing smoothly with the Radeon iGPU transcoding in the background. The only evidence anything had changed was a line in my git log.

## The details that actually took time

Zero downtime doesn't mean zero effort. A few honest notes from the trenches:

**The most useful backup lesson was that I didn't need one.** My plan opened with "back up the old GitLab and Jenkins first." Then I hit a wall: I'd forgotten the root password to the old DevOps VM and couldn't get in to run the backup at all. Mild panic — until I actually asked myself what was on it. Nothing. No live repositories, no pipeline history I cared about, just a service I'd stood up to learn on. The real lesson wasn't about `gitlab-secrets.json` or test-extracting archives (both true, and worth knowing) — it was this: **figure out what genuinely needs preserving before you architect a migration around protecting it.** I'd almost spent a weekend rescuing data that didn't exist. I wiped the VM and started clean.

**ZFS choices matter more than they look.** I deliberately did *not* mirror my two drives. Movies are re-downloadable; family photos are not. So one disk holds media, the other became a dedicated ZFS pool for nightly Proxmox Backup Server snapshots. Losing redundancy on replaceable data bought me a dedicated backup disk for the irreplaceable stuff. The encrypted off-site leg (Backblaze B2 or Cloudflare R2) is the next step — I'm holding it until the photo library actually lands on the box, so 3-2-1 kicks in exactly when there's something worth 3-2-1-ing.

**The torrent stack needed a kill-switch, not a lecture.** The media automation VM routes qBittorrent through a Gluetun VPN container using Docker's `network_mode: "service:gluetun"`. The torrent client literally has no network of its own — if the VPN drops, traffic stops. I tested this by killing the VPN container mid-download and watching qBittorrent fail with `bad address` on every request. Zero leak. Two side-lessons the hard way: the free VPN tier I started with silently blocks P2P entirely (the tunnel connects, then every peer connection times out), and even on a paid plan the specific *server region* matters — one region blocked DHT traffic while another a few hundred kilometres away worked instantly. Test your kill-switch, and test that your VPN actually allows what you're using it for, before you need either.

**Migration order matters.** Family services first — get the thing my family depends on safe and stable before anything else. Core infrastructure (a fresh GitLab, monitoring) comes second, on its own node, once the family tier is boring and reliable. Only when nothing points at the old MacBook anymore does it get wiped and rejoin as the disposable lab node. I keep a decommission checklist in the repo and won't format a disk until every box is ticked.

## What I'd tell you if you're planning the same thing

The migration took a handful of evening sessions spread across a few days — reinstalling Proxmox on ZFS, Terraforming the VMs, Ansible-ing them into Docker hosts, moving the drives, standing up Jellyfin with GPU passthrough, and finally cutting over. The technical work was maybe half of it. The other half was discipline: writing down the current state before changing it, committing every config before applying it, and resisting the urge to "quickly fix" things by hand on the new machines.

That discipline paid off in a way I didn't expect. Because every compose file, playbook, and tunnel config went into git from day one, I accidentally ended up with something more valuable than a working homelab: a repository that documents exactly how to build it again. That repo has since become the foundation of everything else I do — but that's the next post.

The best compliment my infrastructure ever received came about a week after the cutover, when I asked my family if they'd noticed anything different about Jellyfin.

"No. Why, did something change?"

Everything changed. That's the point.

---

*The full configuration for everything in this post — Terraform, Ansible, compose files, and the runbooks — is public at [github.com/YOUR-GH-USER/homelab-infra](https://github.com/YOUR-GH-USER/homelab-infra).*
