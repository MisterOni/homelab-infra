# I Destroy My Kubernetes Lab Every Month. Here's What It Keeps Teaching Me.

*Draft — update the drill table and [BRACKETED] details as real drills happen, and rewrite anything that doesn't sound like you.*

---

On the [FILL IN: first Saturday] of every month, I run `terraform destroy` against my entire Kubernetes lab — three VMs, the cluster, ArgoCD, Jenkins, every experiment on it — and then I time how long it takes to bring it all back from my git repository.

People sometimes assume this is a flex. It's closer to a confession. The monthly teardown exists because the first rebuild was a disaster, and every drill since has been an audit of my own bad habits.

## Why deliberately break a working lab?

My lab runs on a 2019 MacBook Pro whose network adapter routinely dies after a reboot. When I designed my three-node homelab, I put the disposable workloads on the unreliable machine on purpose — the family's media server lives elsewhere, on hardware that behaves. (I wrote about that design in the [migration post](#).)

But "disposable" is a claim, not a property. Plenty of infrastructure is *called* cattle and *treated* like a pet: unique, hand-fed, irreplaceable in ways nobody documented. The only way to know which one you have is to shoot it and see if a new one appears. Infrastructure-as-code that has never been re-run from scratch is best understood as infrastructure-as-hope.

So the drill is the test. If my repo really is the single source of truth, the rebuild is boring. Every place it isn't boring is a place I lied to myself in a commit message.

## What the drills actually caught

The scoreboard lives in my repo's README, but the honest version is the list of things each drill exposed:

**Drill #1: [FILL IN — e.g., "the kubeconfig only existed on my laptop, and a Helm values tweak I'd made in the UI was in nobody's memory but ArgoCD's"].** The first rebuild took [FILL IN] and involved more improvisation than execution. Humbling, and exactly the point.

**Drill #2: [FILL IN — e.g., "a container image tag I'd referenced as :latest had moved under me, so 'the same' cluster came back different"].** Rebuild time: [FILL IN].

**Drill #3: [FILL IN].** Rebuild time: [FILL IN].

Each fix followed the same rule I stole from my own migration: *any manual step becomes code the second time you perform it.* The MacBook's flaky NIC is the flagship example — what began as "walk over and bounce the interface" is now a systemd watchdog deployed by an Ansible role, and the hardware quirk that once ruined movie nights is just another file in git.

The trend line matters more than any single number. Rebuilds should get faster and duller every month. My current time from `destroy` to a fully synced ArgoCD dashboard is [FILL IN] — the goal is for the drill to eventually be so uneventful that the only interesting part is this blog post.

## The layers, and where the truth lives

A rebuild traverses the whole stack, which makes it a nice map of what "everything as code" actually means in practice. Terraform recreates the VMs from a cloud-init template — names, IPs, sizes, all declared. Ansible turns blank VMs into configured nodes — packages, hardening, exporters, the NIC watchdog. K3s goes on, then ArgoCD, then ArgoCD reads one app-of-apps manifest and pulls every workload back out of git. My part of the ceremony is three commands and some tea.

The subtle lesson here was learning *where state is allowed to live*. Code lives in git. Secrets live encrypted (safe to store, never plaintext). Data — the things that can't be regenerated — lives outside the blast radius entirely, on the production node, with real backups. The lab can only be casually destroyable because nothing irreplaceable is ever allowed onto it. Deciding what's cattle isn't a naming exercise; it's a data-placement exercise.

## The unexpected career dividend

I started the drills to keep myself honest. What I didn't expect was how useful "my lab rebuilds from git in [FILL IN] minutes" would become as a sentence.

It compresses a lot of claims into one verifiable artifact: that I write Terraform and Ansible someone else could run, that my GitOps setup actually reconciles from nothing, that I think about disaster recovery as a practice rather than a document. In interviews, most of my favourite questions have been follow-ups to that one sentence. And because the repo is public, none of it requires trust — the receipts are in the commit history, including the embarrassing early ones. *Especially* the embarrassing early ones; a repo where nothing ever went wrong is a repo where nothing was learned.

The same code now has a party trick, too: a variant of the lab that deploys to AWS on demand — VPC, instance, k3s, app — demos for a few cents, and then `terraform destroy`s itself back to zero. Ephemerality turns out to be a transferable skill.

## If you want to start

Don't start with the drill. Start with one honest question: *if this machine vanished right now, what would I actually lose?* Write the answer down. Everything on that list either becomes code, becomes an encrypted secret, or gets moved somewhere with backups. Then — only then — schedule the teardown, put the date in your calendar, and treat whatever breaks as the curriculum.

The first rebuild will be a mess. Do it anyway. The mess *is* the syllabus.

---

*The Terraform, Ansible, and drill scoreboard from this post live in [github.com/YOUR-GH-USER/homelab-infra](https://github.com/YOUR-GH-USER/homelab-infra).*
