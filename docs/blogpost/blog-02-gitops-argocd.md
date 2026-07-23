# kubectl apply Is for Debugging: How ArgoCD Changed the Way I Ship Everything

*This post describes the GitOps design I'm building toward on the lab tier — the family platform is already live (see the previous post); the Kubernetes lab node is the next phase. I'm writing it in the present tense as a design I've committed to, and I'll fold in real numbers from the first full cluster rebuild once it happens.*

---

Before I ran Kubernetes properly, my mental model of "deploying" was SSH. Change a manifest on my laptop, `kubectl apply` it, watch the pods, move on. It works — right up until you realise the cluster's true configuration lives nowhere: not in git, not in a file, but in the accumulated history of every command you ever ran and half-forgot. That's the trap I'm designing the lab tier specifically to avoid.

The industry has a name for the cure: GitOps. The idea sounds almost too simple to be useful — *the cluster should continuously make itself look like a git repository* — but adopting it properly changed how I think about operating software more than any other single tool in my lab.

## The rule that makes it work

GitOps only works if you commit to one rule with no exceptions: **nothing enters the cluster except through git.** Not "mostly through git." Not "through git unless I'm in a hurry." The moment you allow one manual hotfix to stick around, your repo stops being the truth and goes back to being a suggestion.

In the lab, that rule is enforced by ArgoCD — a controller that runs inside the K3s cluster, watches my GitLab repository, and relentlessly reconciles reality against it. Edit a deployment in git and ArgoCD applies it within minutes. Change the cluster directly and ArgoCD notices the drift and puts it back. Self-heal isn't a metaphor — the whole appeal is that reverting my own late-night meddling stops being my job and becomes the controller's.

`kubectl apply` still has a place in my toolbox. That place is debugging — poking at a problem, testing a theory. But the moment something should *exist*, it goes through a commit. The command line is for questions; git is for decisions.

## App-of-apps: one manifest to rule them all

The pattern that made ArgoCD click for me is called **app-of-apps**. You hand-apply exactly one manifest, once — a root ArgoCD Application that points at a folder in your repo. That folder contains more Application manifests: one for monitoring, one for the demo app, one for whatever comes next. The root app deploys the child apps, and the child apps deploy the actual workloads.

The consequence is lovely: adding a new service to the cluster is a pull request. Removing one is a deleted file (ArgoCD prunes what git no longer mentions). And rebuilding the entire cluster from nothing is: install K3s, install ArgoCD, apply one manifest, make tea. Everything else cascades out of git while the kettle boils.

*(I'll drop the real timing of my first full cascade here once the lab node is running — including whatever breaks the first time, because something always does.)*

## The pipeline: from git push to running pods, no humans involved

With GitOps handling the "how does it get to the cluster" half, my CI pipeline only has to answer "is it good enough to go?" The full journey of a commit in my lab now looks like this:

A push to the app repo triggers Jenkins. Jenkins builds the container image, then hands it to Trivy for a vulnerability scan — and the pipeline *fails* on high or critical CVEs, because a security gate you can skip is a security gate you will skip. If the image is clean, it's pushed to my GitLab registry. Then comes my favourite step: the pipeline doesn't deploy anything. It clones my GitOps repo, bumps the image tag in the deployment manifest, and pushes a commit. That's it. Jenkins has no cluster credentials at all.

ArgoCD sees the new commit and rolls out the change; Grafana shows the new pods coming up. From `git push` to serving traffic should land in a few minutes — I'll pin the exact number once the pipeline is live — and every step of it is visible in either a pipeline log or a git diff.

The security property here is worth pausing on. In the old model, my CI system held keys to the cluster — which means anyone who compromised Jenkins owned my Kubernetes. In the GitOps model, CI can only *propose* changes by writing to a repo; the cluster *pulls* from inside. The audit story improves too: `git log` on the GitOps repo is a complete, timestamped history of every deployment, forever, with authorship for free.

## Secrets, or: how to make your repo safe to show people

One thing will stop you from making a GitOps repo public: secrets. A deployment manifest is harmless; the database password next to it is not.

On the family tier I already do this with **Ansible Vault** — encrypted variables that are safe to commit, plus a pre-commit hook that scans every staged diff for anything that looks like a leaked token or password. For the Kubernetes tier I'll extend the same principle with sealed-secrets (or SOPS + age), so only encrypted secrets ever touch git: the cluster holds the decryption key, the repository holds ciphertext that's safe for the world to see. It's a small amount of setup for a large amount of freedom — my infrastructure repo is public, recruiters can read it, and there's nothing in it I'd mind a stranger seeing. In a finance-heavy job market like Hong Kong's, being able to *demonstrate* secrets hygiene rather than just claim it feels like it matters.

## What GitOps actually taught me

The tools are the visible part, but the shift is mental. GitOps forced me to stop thinking of my cluster as a place I *do things to*, and start thinking of it as a projection of a repository — a cache of git, almost. Once that clicks, a lot of operational fears shrink. Cluster broken beyond repair? Delete it and let the repo rebuild it. Not sure what changed last Tuesday? Read the log. Want to try something risky? Branch.

There's a follow-up question that pattern raises, of course: if the cluster is just a projection of git, how far can you push that? What happens if you delete *everything* — VMs included — every single month, on purpose?

I do exactly that. It's the subject of the next post.

---

*ArgoCD manifests, the Jenkinsfile, and the app-of-apps structure from this post are all in [github.com/YOUR-GH-USER/homelab-infra](https://github.com/YOUR-GH-USER/homelab-infra).*
