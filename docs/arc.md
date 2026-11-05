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
