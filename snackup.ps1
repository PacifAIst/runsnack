# RunSnack setup script (Windows). Pulls the agent image and starts a
# hardened container. cloudflared runs INSIDE the container (the agent
# manages it) -- this script only needs Docker Desktop on the host.
#
# Distributed as plain PowerShell, not a compiled .exe: an unsigned .exe
# triggers a SmartScreen "unrecognized publisher" block that reputably
# requires an EV code-signing certificate (~$300+/year) to clear. A
# downloaded .ps1 only gets the lighter "Windows protected your PC" /
# Unblock-File treatment. See the README for how to run this file.
#
# Note: this script does NOT set $ErrorActionPreference = "Stop". On
# Windows PowerShell 5.1, redirecting a native command's stderr (docker's
# in particular) wraps it in a terminating NativeCommandError under -Stop
# even for expected, harmless cases -- e.g. `docker rm -f` on a container
# that doesn't exist yet, which happens on every first run. Real failures
# are instead checked explicitly via $LASTEXITCODE.

$Image = "gunzfanatic/runsnack-agent:latest"
$Container = "snack1"

Write-Host "RunSnack setup"
Write-Host "=============="
Write-Host ""
Write-Host "WARNING: this gives whoever you share the link with a real terminal"
Write-Host "on this machine, inside a sandboxed container. Don't run this on a"
Write-Host "machine with sensitive data. See the README before continuing."
Write-Host ""

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    Write-Host "Docker not found. Install Docker Desktop first: https://www.docker.com/products/docker-desktop/"
    exit 1
}

$null = docker info 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker Desktop is installed but not running (or still starting up)."
    Write-Host "Start Docker Desktop and re-run this script."
    exit 1
}

$dockerInfoText = docker info 2>&1 | Out-String
$gpuFlag = "all"
if ($dockerInfoText -notmatch "(?i)nvidia") {
    Write-Host "Note: no NVIDIA Docker runtime detected. Continuing without GPU passthrough"
    Write-Host "(CPU-only). See the README if you expected GPU support to be available."
    $gpuFlag = $null
}

$cpu = Read-Host "CPU cores [4]"
if ([string]::IsNullOrWhiteSpace($cpu)) { $cpu = "4" }

$ram = Read-Host "RAM in GB [4]"
if ([string]::IsNullOrWhiteSpace($ram)) { $ram = "4" }

$sched = Read-Host "Schedule as CET:HH:MM-HH:MM (blank = always on)"
# TURN works out of the box (a default Metered.ca key is baked into the
# agent, see cmd/snack-agent/main.go) -- no prompt needed. Set
# $env:METERED_API_KEY yourself before running this script only if you
# want to override that default with your own account's credentials.
$meteredKey = $env:METERED_API_KEY

# Running from a cloned/downloaded copy of the repo (this script lives in
# scripts/, source lives in ../agent and ../docker)? Build locally instead
# of pulling from Docker Hub -- there's no reason to require a published
# image (or a Docker Hub account at all) just to try this out from source,
# and until this project actually publishes a real image, `docker pull`
# here will always fail with "repository does not exist".
$RepoRoot = Split-Path -Parent $PSScriptRoot
$DockerDir = Join-Path $RepoRoot "docker"
$AgentDir = Join-Path $RepoRoot "agent"
$BuildFromSource = (Test-Path (Join-Path $DockerDir "Dockerfile")) -and (Test-Path $AgentDir)

if ($BuildFromSource) {
    Write-Host ""
    Write-Host "Found source checkout next to this script -- building the image locally"
    Write-Host "instead of pulling from Docker Hub (no account needed for this)."

    Write-Host "Compiling snack-agent and snackctl (linux/amd64, via a throwaway golang container)..."
    docker run --rm `
        -v "${AgentDir}:/app" -w /app `
        -v "runsnack-gomodcache:/go/pkg/mod" -v "runsnack-gobuildcache:/root/.cache/go-build" `
        -e GOOS=linux -e GOARCH=amd64 `
        golang:1.24 sh -c "go build -o dist/snack-agent ./cmd/snack-agent && go build -o dist/snackctl ./cmd/snackctl"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Building the Go binaries failed."
        exit 1
    }

    Copy-Item (Join-Path $AgentDir "dist\snack-agent") (Join-Path $DockerDir "snack-agent") -Force
    Copy-Item (Join-Path $AgentDir "dist\snackctl") (Join-Path $DockerDir "snackctl") -Force

    Write-Host "Building Docker image $Image ..."
    Push-Location $DockerDir
    docker build -t $Image .
    $buildExit = $LASTEXITCODE
    Pop-Location
    if ($buildExit -ne 0) {
        Write-Host "docker build failed."
        exit 1
    }
} else {
    Write-Host ""
    Write-Host "Pulling $Image ..."
    docker pull $Image
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "Could not pull $Image -- this isn't something wrong on your end."
        Write-Host "It means the RunSnack image hasn't been published to Docker Hub yet"
        Write-Host "(or was published under a different name). There's nothing more to"
        Write-Host "try here: this script can only build from source if it's run from"
        Write-Host "inside a full clone of the RunSnack repo (with agent/ and docker/"
        Write-Host "next to it), not from a standalone downloaded copy like this one."
        Write-Host "Please let the person who shared this installer know."
        exit 1
    }
}

# Best-effort cleanup from a previous run -- failure here is expected and
# harmless (e.g. "no such container" the very first time) so it is never
# treated as fatal.
docker rm -f $Container 2>&1 | Out-Null

$runArgs = @(
    "run", "-d", "--name", $Container,
    "--cpus=$cpu", "--memory=${ram}g",
    "--read-only",
    "--tmpfs", "/tmp:rw,nosuid,size=2g",
    "--tmpfs", "/home/snackuser:rw,exec,nosuid,size=2g,uid=1000,gid=1000",
    "--cap-drop=ALL", "--security-opt=no-new-privileges"
)
if ($gpuFlag) {
    $runArgs += @("--gpus", $gpuFlag)
}
if (-not [string]::IsNullOrWhiteSpace($sched)) {
    $runArgs += @("-e", "SCHEDULE=CET:$sched")
}
if (-not [string]::IsNullOrWhiteSpace($meteredKey)) {
    $runArgs += @("-e", "METERED_API_KEY=$meteredKey")
}
$runArgs += $Image

docker @runArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "docker run failed."
    exit 1
}

Write-Host ""
Write-Host "RunSnack is starting. Waiting for the shareable link..."

$link = $null
for ($i = 0; $i -lt 20; $i++) {
    $logs = docker logs $Container 2>&1 | Out-String
    $match = [regex]::Match($logs, "https://\S+/#[st]=\S+")
    if ($match.Success) {
        $link = $match.Value
        break
    }
    Start-Sleep -Seconds 1
}

if ($link) {
    Write-Host ""
    Write-Host "+=============================================+"
    Write-Host "|  RUNSNACK - Your GPU. One link. The world.  |"
    Write-Host "+=============================================+"
    Write-Host ""
    Write-Host "Your RunSnack is LIVE"
    Write-Host "Share this link: $link"
    Write-Host ""
    Write-Host "-----------------------------------------------"
    Write-Host "Commands:"
    Write-Host "  docker exec -it $Container snackctl   -> management menu"
    Write-Host "  docker stop $Container                -> stop sharing immediately"
    Write-Host ""
    Write-Host "Tips:"
    Write-Host "  - Give the link only to people you trust"
    Write-Host "  - Regenerate the link in snackctl to kick users"
    Write-Host "  - Files in /uploads/ are lost when you stop"
    Write-Host "  - This is a sandboxed Docker container -- your host is isolated"
    Write-Host "  - Find renters: RunSnack on Discord -- https://discord.gg/jaKt2HANNP"
    Write-Host "-----------------------------------------------"
} else {
    Write-Host "Link not ready yet. Check status with: docker logs $Container"
}
