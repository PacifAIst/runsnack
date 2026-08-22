# Security

RunSnack gives someone a shell on your machine, inside a container, over a
link. That is the whole product, and it means the security model deserves a
straight description rather than a reassuring one.

This document says what the boundary does, what it doesn't, and who this tool
is for. If any of it is wrong, please tell us — see *Reporting* at the bottom.

## Who this is for

**Share the way you would share an SSH key.** RunSnack is built for handing
your hardware to a specific person you already have a reason to trust: a
student, a colleague, a collaborator, a maintainer you have been talking to in
an issue thread.

It is **not** built for renting to anonymous strangers. There is no escrow, no
reputation system, no dispute process, and — as described below — no hardware
isolation on the GPU. Platforms like Vast.ai and RunPod exist because those
problems are hard, and they have solved them. RunSnack has not, by design.

## What the container boundary does

Sessions run in a Docker container launched with:

- `--read-only` root filesystem
- `--cap-drop=ALL` — no Linux capabilities
- `--security-opt=no-new-privileges`
- Non-root user (uid 1000)
- `--cpus` and `--memory` limits set at install time
- `tmpfs` mounts with `nosuid`, size-capped, wiped when the container stops

Docker's default seccomp profile applies. A guest lands in an unprivileged
process, in a namespace of its own, with no capabilities and no writable root.

That is a real boundary, and it is the same one you rely on every time you run
somebody else's container image.

## What the container boundary does not do

**Docker is a sandbox, not a hypervisor.** The container shares the host
kernel. A kernel vulnerability, or a misconfiguration that grants back a
capability, turns container access into host access. Platforms that hand you a
full VM with its own kernel give a strictly stronger boundary than this.

If you need VM-grade isolation, use a VM. gVisor and Kata Containers are the
usual middle ground; RunSnack does not currently use either.

## The GPU is the weaker boundary

This is the part most people underestimate, including us until reviewers on
LowEndTalk pushed on it.

RunSnack passes the GPU through whole (`--gpus all`). There is **no MIG, no
vGPU, and no SR-IOV partitioning.** Consequences:

- **VRAM is not reliably zeroed between contexts.** Memory freed by one
  workload can be handed to the next one with the previous contents still in
  it. Data can leak across sessions **with no container escape involved at
  all.**
- **Isolation on the GPU is software-enforced, not hardware-enforced.** The
  driver sets up separate virtual address spaces per context, but a driver bug
  or a scheduler-level exploit can cross that line. There is no equivalent of
  SR-IOV's IOMMU-level separation.
- **The GPU driver is not a privilege boundary.** It runs in kernel space with
  a large attack surface, and the hardware-to-driver interface has never been
  treated as a security boundary. Malformed command buffers, firmware bugs, and
  timing side channels on shared execution units are unaffected by anything
  above.

This is **not specific to NVIDIA**, and it is not something we have chosen not
to fix. No consumer GPU has native isolation between kernels. MIG and vGPU
exist only on datacenter parts; AMD's SR-IOV support is limited to some
Instinct cards. On a 4090, a Jetson, or an integrated GPU there is nothing to
partition with.

**Practical implication:** do not run anything on a shared GPU that you would
mind a later session reading. If your workload involves data you cannot afford
to leak, RunSnack is the wrong tool.

## Network exposure

- The connection is peer-to-peer over WebRTC. When direct connection fails
  (symmetric NAT, restrictive firewalls) it falls back to a TURN relay.
- **Guest traffic leaves from your IP address.** Anything the guest does on the
  network — downloads, scraping, abuse — appears to originate from your
  connection, and is your responsibility as the connection owner.
- Anyone holding the link can open a session. Treat it as a credential: it is
  not password-protected, and it does not expire on its own. Regenerate it from
  `snackctl` to invalidate the old one.

## What we don't have

Stated plainly so nobody has to discover it later:

- No escrow, payment handling, or dispute process
- No reputation or identity system
- No SLA, uptime guarantee, or support commitment
- No audit by a third party
- No isolation between concurrent workloads on the same GPU
- No process-count limit on the container (a fork bomb can exhaust the host's
  process table and require a reboot)

## Open and closed components

- **Open (Apache 2.0):** the installer scripts in this repository. These are
  byte-for-byte what runsnack.com serves. They are the part that touches your
  host, and every flag above is visible in them — read them before running
  anything.
- **Closed:** the agent that runs inside the container, distributed as a
  Docker image. You are trusting it. If that is a dealbreaker for you, it is a
  reasonable position and we would rather say so than argue about it.

## Reducing your exposure

If you want to use RunSnack with the boundary widened as far as it goes:

- Run it on a machine that does not hold data you care about — a spare box, a
  lab machine, a reinstall away from useful.
- Put it on an isolated VLAN, or behind an egress firewall that limits what a
  session can reach.
- Use the schedule option at install time so it only accepts connections during
  hours you choose.
- Stop the container when you are not actively sharing: `docker stop snack1`.
- Regenerate the link after each session rather than reusing it.

## Reporting a vulnerability

Open an issue at https://github.com/PacifAIst/runsnack/issues for anything
non-sensitive.

For something that should not be public first, contact Manuel Herrador through
https://github.com/PacifAIst and we will arrange a private channel. There is no
bug bounty. We will credit you unless you would rather we didn't.

Corrections to this document are as welcome as vulnerability reports. Several
of the limits above were written because people took the time to point them
out.
