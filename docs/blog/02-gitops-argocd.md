# kubectl apply Is for Debugging: The GitOps Setup I'm Building on My Homelab

*The 3-node Proxmox cluster underneath this is now real (see the previous post). The Kubernetes lab tier on top of it is the next thing I'm building — so I'm writing this as the design I've committed to, and I'll drop in real numbers once the first cluster rebuild actually runs.*

---

Before I ran Kubernetes properly, my mental model of "deploying" was SSH. Change a manifest on my laptop, `kubectl apply`, watch the pods, move on. It works — right up until you realise your cluster's true configuration lives *nowhere*: not in git, not in a file, but in the accumulated history of every command you ever ran and half-forgot. That's the exact trap I'm designing the lab tier to avoid, because I've lived in it.

The industry's cure has a name: GitOps. The idea sounds almost too simple to be useful — *the cluster should continuously make itself match a git repository* — but the more I sit with it, the more it reframes how I think about running software.

## The one rule that makes it work

GitOps only works if you commit to a single rule with no exceptions: **nothing enters the cluster except through git.** Not "mostly." Not "unless I'm in a hurry." The moment one manual hotfix survives, your repo stops being the truth and goes back to being a suggestion.

In the lab, that rule gets enforced by ArgoCD — a controller running inside the K3s cluster that watches my GitLab repo and reconciles reality against it. Edit a deployment in git, ArgoCD applies it within minutes. Change the cluster directly, ArgoCD notices the drift and puts it back. The appeal is that reverting my own late-night meddling stops being my job and becomes the controller's.

`kubectl apply` still has a place — debugging, poking at a problem, testing a theory. But the moment something should *exist*, it goes through a commit. The command line is for questions; git is for decisions.

## App-of-apps: one manifest to rule them all

The pattern that makes ArgoCD click is **app-of-apps**. You hand-apply exactly one manifest, once — a root Application that points at a folder in your repo. That folder holds more Application manifests: one for monitoring, one for the demo app, one for whatever's next. The root deploys the children, the children deploy the workloads.

The nice consequence: adding a service is a pull request. Removing one is a deleted file (ArgoCD prunes what git no longer mentions). And rebuilding the entire cluster from nothing is: install K3s, install ArgoCD, apply one manifest, make tea. Everything else cascades out of git while the kettle boils.

*(I'll drop the real timing of my first full cascade here once the lab node is running K3s — including whatever breaks the first time, because something always does.)*

## From git push to running pods, no humans involved

With GitOps handling "how does it reach the cluster," my CI pipeline only has to answer "is it good enough to go?" The plan for a commit's full journey:

A push triggers Jenkins. Jenkins builds the image, hands it to Trivy for a vulnerability scan, and the pipeline *fails* on high/critical CVEs — a security gate you can skip is a gate you will skip. Clean image gets pushed to my GitLab registry. Then my favourite step: the pipeline doesn't deploy anything. It clones the GitOps repo, bumps the image tag in the manifest, and pushes a commit. That's it. Jenkins has no cluster credentials at all.

ArgoCD sees the new commit and rolls it out; Grafana shows the new pods coming up. The security property is the part I actually care about: in the old model, CI held keys to the cluster, so anyone who owned Jenkins owned Kubernetes. Here, CI can only *propose* a change by writing to a repo; the cluster pulls from inside. And `git log` on the GitOps repo becomes a complete, timestamped deployment history, authorship included, for free.

## Secrets, or: how to make your repo safe to show people

One thing stops you from making an infra repo public: secrets. A deployment manifest is harmless; the database password next to it is not.

On the family tier I already handle this with **Ansible Vault** — encrypted variables that are safe to commit, plus a pre-commit hook that scans every staged diff for anything that looks like a leaked token or password. For the Kubernetes tier I'll extend the same principle with sealed-secrets (or SOPS + age): only encrypted secrets touch git, the cluster holds the key, the repo holds ciphertext that's safe for the world to read. It's a little setup for a lot of freedom — my infra repo is public, recruiters can read it, and there's nothing in it I'd mind a stranger seeing. Transitioning into DevOps in a finance-heavy market like Hong Kong's, being able to *show* secrets hygiene rather than claim it feels like it matters.

## Why I care about this at all

The tools are the visible part, but the real shift is mental. GitOps pushes you to stop thinking of a cluster as a place you *do things to*, and start thinking of it as a projection of a repository — a cache of git, almost. Once that clicks, a lot of operational fear shrinks. Cluster broken beyond repair? Delete it, let the repo rebuild it. Not sure what changed last Tuesday? Read the log. Want to try something risky? Branch.

And that raises an obvious question: if the cluster is just a projection of git, how far can you push it? What happens if you delete *everything* — VMs included — every month, on purpose?

That's the plan. It's the next post.

---

*The ArgoCD manifests, Jenkinsfile, and app-of-apps structure land in [github.com/MisterOni/homelab-infra](https://github.com/MisterOni/homelab-infra) as I build this tier.*
