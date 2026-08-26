#!/bin/bash
# RunSnack setup script (Linux/macOS). Pulls the agent image and starts a
# hardened container. cloudflared runs INSIDE the container (the agent
# manages it) — this script only needs Docker on the host, nothing else.
set -euo pipefail

CONTAINER="snack1"

echo "RunSnack setup"
echo "=============="
echo
echo "WARNING: this gives whoever you share the link with a real terminal"
echo "on this machine, inside a sandboxed container. Don't run this on a"
echo "machine with sensitive data. See the README before continuing."
echo

if ! command -v docker &>/dev/null; then
  echo "Docker not found. Install Docker first: https://docs.docker.com/get-docker/"
  exit 1
fi

if ! docker info &>/dev/null; then
  echo "Docker is installed but not running. Start Docker and re-run this script."
  exit 1
fi

# Detect the host and pick the right published image -- rather than relying
# on Docker's multi-arch manifest auto-resolution, which can only tell
# linux/amd64 from linux/arm64 and can't distinguish a Jetson from any other
# arm64 machine (Raspberry Pi, Apple Silicon, a generic ARM server). This
# way an unsupported host gets a clear message instead of a silently broken
# or GPU-less image. /etc/nv_tegra_release exists on every L4T-flashed
# Jetson and nowhere else -- the standard way Jetson tooling detects itself.
ARCH=$(uname -m)
IS_JETSON=0
case "$ARCH" in
  x86_64)
    IMAGE="gunzfanatic/runsnack-agent:latest"
    ;;
  aarch64|arm64)
    if [ -f /etc/nv_tegra_release ]; then
      IS_JETSON=1
      IMAGE="gunzfanatic/runsnack-agent:jetson-jp6"
    else
      echo "This machine is ARM64 but not a detected NVIDIA Jetson (JetPack 6.1 / L4T r36.4)."
      echo "RunSnack currently supports x86_64 and Jetson (JetPack 6.1) only."
      echo "See https://github.com/PacifAIst/runsnack for the current hardware list."
      exit 1
    fi
    ;;
  *)
    echo "Unsupported architecture: $ARCH."
    echo "RunSnack currently supports x86_64 and NVIDIA Jetson (JetPack 6.1, arm64) only."
    exit 1
    ;;
esac

GPU_FLAG="all"
if ! docker info 2>/dev/null | grep -qi nvidia; then
  echo "Note: no NVIDIA Docker runtime detected. Continuing without GPU passthrough"
  echo "(CPU-only). See the README if you expected GPU support to be available."
  GPU_FLAG=""
fi

# Jetson's container runtime rejects/ignores --gpus entirely; GPU access
# there goes through --runtime nvidia (csv-mode host-library mounts)
# instead. Gated on GPU_FLAG (not just IS_JETSON) so a freshly-flashed
# Jetson that hasn't configured the NVIDIA container toolkit yet still
# degrades to CPU-only, the same as every other undetected-GPU host, rather
# than hard-failing with "unknown or invalid runtime name". See
# agent/arm64/README.md for why this differs from x86.
RUNTIME_ARGS=()
if [ "$IS_JETSON" = "1" ]; then
  if [ -n "$GPU_FLAG" ]; then
    RUNTIME_ARGS=(--runtime nvidia)
  fi
  GPU_FLAG=""
fi

read -p "CPU cores [4]: " CPU
CPU=${CPU:-4}
read -p "RAM in GB [4]: " RAM
RAM=${RAM:-4}
read -p "Schedule as CET:HH:MM-HH:MM (blank = always on): " SCHED
# TURN works out of the box (a default Metered.ca key is baked into the
# agent, see cmd/snack-agent/main.go) -- no prompt needed. Set
# METERED_API_KEY yourself before running this script only if you want to
# override that default with your own account's credentials.

# Running from a cloned/downloaded copy of the repo (this script lives in
# scripts/, source lives in ../agent and ../docker)? Build locally instead
# of pulling from Docker Hub -- there's no reason to require a published
# image (or a Docker Hub account at all) just to try this out from source,
# and until this project actually publishes a real image, `docker pull`
# here will always fail with "repository does not exist".
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
DOCKER_DIR="$REPO_ROOT/docker"
AGENT_DIR="$REPO_ROOT/agent"
ARM64_DIR="$REPO_ROOT/agent/arm64"

if [ "$IS_JETSON" = "1" ] && [ -f "$ARM64_DIR/Dockerfile" ] && [ -d "$AGENT_DIR" ]; then
  echo
  echo "Found source checkout next to this script -- building the Jetson image"
  echo "locally instead of pulling from Docker Hub (no account needed for this)."
  echo "This requires Docker buildx with arm64 QEMU emulation registered --"
  echo "see agent/arm64/README.md if the build step below fails."

  echo "Building Docker image $IMAGE (linux/arm64, agent/arm64/Dockerfile) ..."
  (cd "$REPO_ROOT" && docker buildx build --platform linux/arm64 \
    -f "$ARM64_DIR/Dockerfile" -t "$IMAGE" --load .)
elif [ -f "$DOCKER_DIR/Dockerfile" ] && [ -d "$AGENT_DIR" ]; then
  echo
  echo "Found source checkout next to this script -- building the image locally"
  echo "instead of pulling from Docker Hub (no account needed for this)."

  echo "Compiling snack-agent and snackctl (linux/amd64, via a throwaway golang container)..."
  docker run --rm \
    -v "$AGENT_DIR:/app" -w /app \
    -v runsnack-gomodcache:/go/pkg/mod -v runsnack-gobuildcache:/root/.cache/go-build \
    -e GOOS=linux -e GOARCH=amd64 \
    golang:1.24 sh -c "go build -o dist/snack-agent ./cmd/snack-agent && go build -o dist/snackctl ./cmd/snackctl"

  cp "$AGENT_DIR/dist/snack-agent" "$AGENT_DIR/dist/snackctl" "$DOCKER_DIR/"

  echo "Building Docker image $IMAGE ..."
  (cd "$DOCKER_DIR" && docker build -t "$IMAGE" .)
else
  echo
  echo "Pulling $IMAGE ..."
  if ! docker pull "$IMAGE"; then
    echo
    echo "Could not pull $IMAGE -- this isn't something wrong on your end."
    echo "It means the RunSnack image hasn't been published to Docker Hub yet"
    echo "(or was published under a different name). There's nothing more to"
    echo "try here: this script can only build from source if it's run from"
    echo "inside a full clone of the RunSnack repo (with agent/ and docker/"
    echo "next to it), not from a standalone downloaded copy like this one."
    echo "Please let the person who shared this installer know."
    exit 1
  fi
fi

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

GPU_ARGS=()
if [ -n "$GPU_FLAG" ]; then
  GPU_ARGS=(--gpus "$GPU_FLAG")
fi

SCHED_ARGS=()
if [ -n "$SCHED" ]; then
  SCHED_ARGS=(-e "SCHEDULE=CET:$SCHED")
fi

TURN_ARGS=()
if [ -n "${METERED_API_KEY:-}" ]; then
  TURN_ARGS=(-e "METERED_API_KEY=$METERED_API_KEY")
fi

docker run -d --name "$CONTAINER" \
  "${GPU_ARGS[@]}" \
  "${RUNTIME_ARGS[@]}" \
  --cpus="$CPU" --memory="${RAM}g" \
  --read-only \
  --tmpfs /tmp:rw,nosuid,size=2g \
  --tmpfs /home/snackuser:rw,exec,nosuid,size=2g,uid=1000,gid=1000 \
  --cap-drop=ALL --security-opt=no-new-privileges \
  "${SCHED_ARGS[@]}" \
  "${TURN_ARGS[@]}" \
  "$IMAGE"

echo
echo "RunSnack is starting. Waiting for the shareable link..."
for i in $(seq 1 20); do
  LINK=$(docker logs "$CONTAINER" 2>&1 | grep -oE 'https://[^ ]+/#[st]=[^ ]*' | tail -1 || true)
  if [ -n "$LINK" ]; then
    echo
    echo "+=============================================+"
    echo "|  RUNSNACK - Your GPU. One link. The world.  |"
    echo "+=============================================+"
    echo
    echo "Your RunSnack is LIVE"
    echo "Share this link: $LINK"
    echo
    echo "-----------------------------------------------"
    echo "Commands:"
    echo "  docker exec -it $CONTAINER snackctl   -> management menu"
    echo "  docker stop $CONTAINER                -> stop sharing immediately"
    echo
    echo "Tips:"
    echo "  - Give the link only to people you trust"
    echo "  - Regenerate the link in snackctl to kick users"
    echo "  - Files in /uploads/ are lost when you stop"
    echo "  - This is a sandboxed Docker container -- your host is isolated"
    echo "  - Find renters: RunSnack on Discord -- https://discord.gg/jaKt2HANNP"
    echo "-----------------------------------------------"
    exit 0
  fi
  sleep 1
done

echo "Link not ready yet. Check status with: docker logs $CONTAINER"
