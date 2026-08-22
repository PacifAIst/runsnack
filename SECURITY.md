# Security

RunSnack gives someone a terminal on your machine, inside a container, over a
link. This document describes how that works, what the boundaries are, and how
to configure your setup for the level of exposure you want.

## Design intent

RunSnack is built for **direct sharing between people** — a student on the lab
GPU, a colleague on the build machine, a collaborator reproducing something on
hardware they don't own, a client testing before they buy.

That's why there's no account system, no listing, and no platform in the
middle: the trust relationship already exists between the two people, so the
software doesn't need to manufacture one. Sharing works best the same way
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

Containers share the host kernel, so this isn't equivalent to a virtual
machine. If your situation calls for VM-grade separation, run RunSnack inside a
VM — that composes fine and gives you both boundaries.

## GPU memory between sessions

RunSnack passes the GPU through directly. A property of GPU computing generally
— not of RunSnack specifically — is that **VRAM isn't reliably zeroed when a
workload releases it.** Memory freed by one session may still hold its contents
when the next allocation receives it, so in principle data can be readable
across sequential sessions.

MIG and vGPU partitioning would address this, but they exist only on datacenter
hardware (A100, H100, some AMD Instinct cards). On a consumer GPU there's no
partitioning layer available to any software.

### Recommended practice: reset the GPU between sessions

Power-cycling or resetting the GPU clears its memory. Two ways to do it:

**Fast (seconds), Linux, root required:**

```bash
docker stop snack1
sudo nvidia-smi --gpu-reset -i 0     # -i is the GPU index
docker start snack1
```

`--gpu-reset` performs a device-level reset that reinitialises the GPU and
clears its memory. It requires that no processes are using the GPU, which is
why the container is stopped first.

**Strongest: restart the host between sessions.** A full shutdown power-cycles
the GPU, which clears VRAM unconditionally. Slower, but it needs no special
privileges and works identically on Windows, Linux and macOS.

If you reboot, make sure RunSnack comes back automatically or sharing will stop
silently. Add a restart policy to the container:

```bash
docker update --restart unless-stopped snack1
```

**When this matters:** if you're sharing with the same person repeatedly, or
sharing your own machine with a colleague, resetting between sessions is
optional. If you're handing the machine to different people in sequence, reset
between them.

**What a reset doesn't cover:** concurrent sessions sharing the same GPU, and
your own workloads running alongside a guest session. If you need those
isolated from each other, use a separate GPU or a separate machine.

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

- Reset the GPU between sessions with different people (see above).
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
