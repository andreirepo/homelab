# Actions Runner Controller on a 4-core Proxmox host

Ephemeral GitHub Actions runners, on the homelab, replacing two always-on
`myoung34/github-runner` containers that shared a Docker socket and a
long-lived personal access token.

## Why

- **Isolation.** Every job gets a fresh pod that is deleted afterwards. No
  leftovers between runs, no shared workspace.
- **No long-lived credential.** The current containers carry a PAT in their
  environment. ARC authenticates as a GitHub App and mints short-lived
  registration tokens.
- **Scale to zero.** Two containers were always on. The scale set is idle at
  0 runners and 0 MB until something is queued.

Cost saving was never the point: public repositories already get free
GitHub-hosted minutes. This is about control, isolation and learning.

## The host, honestly

| | |
|---|---|
| CPU | 4 cores, i5-6500T (2015, no HT) |
| RAM | 16 GB, ~6 GB free |
| Disk | 1× 223 GB consumer SATA SSD |
| Workload | dev VM, Home Assistant, Immich |

That constraint drives every decision below: a single-node cluster, a 3 GB
container for the cluster itself, and `maxRunners: 2`.

## Architecture

```
GitHub (App)  ──►  listener pod  ──►  controller ──►  runner pod (ephemeral)
                                    (arc-systems)     (arc-runners)
        k3s in an LXC on Proxmox: 2 vCPU · 3 GB · 30 GB
```

- **k3s** v1.37 (Traefik and servicelb disabled — nothing to expose).
- **cert-manager** — required by ARC for the listener's TLS assets.
- **ARC controller** 0.15.1 and one `gha-runner-scale-set`.

## Measurements

| | |
|---|---|
| Idle cluster (k3s + cert-manager + controller + listener) | **928 MB RAM** |
| Runner pods when idle | **0** |
| Pod creation → `Running` | ~55 s first run (image pull), ~3 s after |
| Four-job matrix, `maxRunners: 2` | 207 s wall clock; two jobs queued behind the limit |
| Disk after pulling the runner image | 4.3 GB of 30 GB |

A quirk worth knowing: inside the pod, `/proc/meminfo` reports the **host's**
16 GB, because containers are not namespaced for it. `nproc` does reflect the
container limit. Don't size anything from `free` inside a runner.

### A second repository, warm cluster

`arc-portfolio` is a separate scale set (same App, `maxRunners: 1`) because a
personal account has no org runner groups. A throwaway pull request measured it:

| | |
|---|---|
| pull request opened → job finished | **17 s** |
| time in queue | **7 s** |
| the job itself | 9 s |
| pods afterwards | 0 |

The same repository's GitHub-hosted jobs have queued for **20+ minutes** on busy
mornings. The gap between 7 seconds and 20 minutes, not runner speed, is the
argument for self-hosting.

## Gotchas

- **Helm needs `KUBECONFIG`.** A non-interactive shell over SSH does not pick
  up `/etc/rancher/k3s/k3s.yaml`, so `helm` fails with
  `dial tcp [::1]:8080: connection refused` while `kubectl` works.
- **The App must be *installed*, not just created.** `GET /app/installations`
  returning `[]` is the tell.
- **Repo-scoped, not org-scoped.** A personal account cannot use org runner
  groups, so each repository needs its own scale set (or an organisation).
- **Thin LVM without `discard`** had left ~82 GB allocated and unusable in the
  Proxmox pool; `discard=on` + `fstrim` reclaimed it before any of this.
- **The runner image is the agent, not a build environment.**
  `ghcr.io/actions/actions-runner` ships `git`, `curl`, `jq`, `python3`, `tar`,
  `unzip`, `sudo` and the action runtimes — but no Node, no pnpm and no
  Chromium (`node --version` → not found). Anything more needs a custom image.
- **`kubectl logs deploy/…-listener` does not exist.** ARC creates the listener
  as a bare Pod, not a Deployment — log the pod.
- **One transient reconcile error per new scale set**:
  `autoscalinglisteners… already exists`. Harmless, appears once, the listener
  comes up anyway.
- **A classic PAT cannot add a repository to an App installation.**
  `PUT /user/installations/{id}/repositories` answers 403/404 for PATs; only an
  OAuth-app token or the App's own JWT can. That click belongs in the UI.

## Security notes

This repository is public, and GitHub advises against self-hosted runners on
public repositories: a fork can open a pull request whose code would run on your
infrastructure. Two mitigations here:

1. The workflow carries `if: github.event.pull_request.head.repo.full_name == github.repository`,
   so fork pull requests skip the self-hosted job entirely.
2. Runners are ephemeral pods with no Docker socket and no host mounts —
   nothing to poison between runs.

## Reproducing

```bash
pct create <id> <ubuntu-24.04-template> --cores 2 --memory 3072 --rootfs local-lvm:30 \
  --features nesting=1,keyctl=1 --net0 name=eth0,bridge=vmbr0,ip=<ip>/24,gw=<gw> --unprivileged 1
# inside: install k3s, cert-manager, helm, the controller, then this scale set
kubectl -n arc-runners get pods -w     # the show: 0 → N → 0
```

## What deliberately stayed on GitHub-hosted runners

The point of this exercise was not "self-host everything". `declara720` — a
private repo with a Playwright suite — stayed on `ubuntu-latest`, and the
reasoning is worth more than the setup itself:

- **Its workflow needs a build environment**, not a runner: Node, pnpm and
  Chromium with its system libraries. The ARC image has none of that, so the
  job would need a custom image to be built, published and kept current.
- **RAM is the binding constraint.** Chromium plus a Vite build peaks above
  2 GB. The cluster has 3 GB in total and 2.1 GB free at idle; the host has
  ~5 GB. It would fit on a quiet afternoon and fail on a bad one.
- **It costs nothing to leave.** ~100 minutes a month against 2,000 free
  private-repository minutes. There is no bill to optimise.

Which leaves exactly one job that belongs here: the AI review, because it talks
to a language model on the LAN — an address GitHub-hosted runners cannot reach
at all. That is the honest test for anything else you are tempted to move:
self-host when the job needs *your* network, your hardware or your data, not
because the setup is fun.

## The migration, and the two addresses it broke

Moving `andrei-portfolio` from the container runner to pods surfaced the same
problem twice, and it is the detail worth stealing from this write-up: **pods
live on the LAN, not on Tailscale.**

| Job | Was pointing at | Symptom | Fixed by |
|---|---|---|---|
| AI review → LM Studio | a Tailscale IP of a PC that had been offline for 70 days | `curl` timed out, review silently skipped | the PC's LAN address |
| deploy → server | a Tailscale IP | `ssh: connect to host … port 22: Connection timed out` | the server's LAN address |

The second one failed a real deployment on `main` and triggered the rollback
job, which failed the same way. Nothing broke — the previous image kept
serving — but it is exactly the sort of thing that only shows up in production.

Two smaller findings from the same migration:

- **The review never refreshed.** The workflow skipped the whole LM Studio
  check when a review comment already existed, so the "update the existing
  comment" branch was unreachable: every push after the first was a no-op that
  went green in ten seconds.
- **The model name was wrong.** The payload asked for `qwen/qwen3-14b`; LM
  Studio serves `qwen3-14b` and answers `400`, which `curl -sf` swallowed into
  `review_failed=true`. Reviews had been skipped silently for as long as the
  name had been wrong.

Neither would have been caught by a green check. Both were caught by reading
the log of a job that "succeeded".
## Where this ended

Two scale sets, both idle at zero pods, and no container runners left on the
dev VM:

| Repository | Build jobs | Deploy / AI review |
|---|---|---|
| `andrei-portfolio` | GitHub-hosted | ARC pod (`arc-portfolio`) |
| `homelab` | GitHub-hosted | ARC pod (`arc-homelab`) |
| `declara720` | GitHub-hosted | — |
| `todo-app` | — | manual, documented in `DEPLOYMENT.md` |

`todo-app` was the last container, and the honest reason it is not here: its
pipeline needs Node, Docker buildx and SSH to a host behind NAT. Rather than
build a privileged DinD runner on a 3 GB cluster, its workflow was retired and
the deploy written down — build two amd64 images with the exact build args, push
two tags, deploy by tag, roll back from the state file.

That leaves nothing holding a personal access token.
