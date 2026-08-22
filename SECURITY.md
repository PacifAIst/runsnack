# Security

RunSnack gives someone a terminal on your machine, inside a container, over a
link. This document describes how that works, what the boundaries are, and how
to configure your setup for the level of exposure you're comfortable with.

## Design intent

RunSnack is built for **direct sharing between people** — a student on the lab
GPU, a colleague on the build machine, a collaborator reproducing something on
hardware they don't own, a client testing before they buy.

That design is why there's no account system, no listing, and no platform in
the middle: the trust relationship already exists between the two people, so
the software doesn't need to manufacture one. Sharing works best the same way
sharing an SSH key does — with people you have a reason to trust.

## The container boundary

Sessions run in a Docker container launched with:

- `--read-only` root filesystem
- `--cap-drop=ALL` — no Linux capabilities
- `--security-opt=no-new-privileges`
- Non-root user (uid 1000)
- `--cpus` and `--memory` limits set during install
- `tmpfs` mounts with `nosuid`, size-capped, discarded when the container stops

Docker's default seccomp profile applies. A guest lands as an unprivileged user
in its own namespace, with no capabilities and no writable root filesystem.

This is the same isolation model you rely on whenever you run a container image
you didn't build yourself.

**What it doesn't cover:** containers share the host kernel, so container
isolation is not equivalent to a virtual machine. If your situation calls for
VM-grade separation, run RunSnack inside a VM — that composes fine, and gives
you both boundaries.

## GPU characteristics

RunSnack passes the GPU through directly (`--gpus`). Worth understanding what
that means, because it's a property of GPU computing generally rather than of
RunSnack specifically:

- **GPU memory isn't partitioned on consumer hardware.** MIG and vGPU exist
  only on datacenter parts (A100, H100, some AMD Instinct cards). On a 4090, a
  Jetson, or an integrated GPU there's no partitioning layer available to any
  software.
- **VRAM isn't reliably zeroed between contexts.** Memory freed by one workload
  may still hold its contents when the next allocation receives it, so data can
  be readable across sessions.
- **Isolation on the GPU is driver-enforced.** The driver maintains separate
  virtual address spaces per context, but that's software separation rather
  than the hardware separation SR-IOV provides on other devices.

**Practical guidance:** treat a shared GPU as shared. If a workload involves
data you wouldn't want a later session to see, run it on a GPU you're not
sharing.

## Network

- Connections are peer-to-peer over WebRTC, falling back to a TURN relay when a
  direct path isn't available (typically symmetric NAT or restrictive
  firewalls).
- **Guest traffic egresses from your IP address.** Network activity during a
  session appears to originate from your connection, as with any tunnel.
- **The link is the credential.** Anyone holding it can open a session, and it
  doesn't expire on its own. Regenerate it from `snackctl` to invalidate the
  previous one.

## Scope

Things RunSnack intentionally doesn't include, so there's no ambiguity:

- Escrow, payment handling, or dispute resolution — any arrangement is directly
  between the two people involved
- Reputation or identity systems
- Uptime or availability guarantees
- Third-party security audit
- Isolation between concurrent workloads on the same GPU
- A process-count limit on the container

## Open and closed components

- **Open (Apache 2.0):** the installer scripts in this repository, byte-for-byte
  identical to what runsnack.com serves. These are the components that run on
  your host, and every flag documented above is visible in them.
- **Closed:** the agent running inside the container, distributed as a Docker
  image.

## Hardening your setup

For hosts who want to tighten things further:

- Run it on a machine that isn't holding data you care about — a spare box or a
  lab machine is ideal.
- Put the host on an isolated VLAN, or behind an egress firewall limiting what
  a session can reach.
- Use the schedule option during install so sessions are only possible during
  hours you choose.
- Stop the container when you're not actively sharing: `docker stop snack1`.
- Regenerate the link after each session rather than reusing it.
- Run RunSnack inside a VM if you want a kernel boundary as well as a container
  one.

## Reporting

Open an issue at https://github.com/PacifAIst/runsnack/issues for anything
non-sensitive.

For something that shouldn't be public initially, contact Manuel Herrador via
https://github.com/PacifAIst and we'll arrange a private channel. There's no
bug bounty; we'll credit you unless you'd prefer we didn't.

Corrections to this document are as welcome as vulnerability reports.
