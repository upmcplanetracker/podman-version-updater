#!/usr/bin/env bash
set -Eeuo pipefail

# ── Safe error handler ────────────────────────────────────────────────
cleanup_on_failure() {
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "ERROR: Something went wrong. The script will now clean up any"
    echo "partially installed files so your existing Podman keeps working."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    # Remove any newly installed files from /usr/local
    sudo rm -f /usr/local/bin/podman /usr/local/bin/podman-remote 2>/dev/null || true
    sudo rm -rf /usr/local/libexec/podman 2>/dev/null || true
    sudo rm -rf /usr/local/share/man/man1/podman* 2>/dev/null || true
    # Reload user systemd to avoid stale unit files
    systemctl --user daemon-reload 2>/dev/null || true
    hash -r
    if command -v podman &>/dev/null; then
        echo "Old Podman version is still available:"
        podman --version
    else
        echo "No Podman binary found. You may need to reinstall it."
    fi
    exit 1
}
trap cleanup_on_failure ERR

# ── Usage ──────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage:
  Update:   $0 <RELEASE_TAG_URL>
  Rollback: $0 --rollback
  Fresh install (no existing Podman): $0 --fresh-install <RELEASE_TAG_URL>

  The <RELEASE_TAG_URL> must be a GitHub release tag URL, e.g.:
      https://github.com/containers/podman/releases/tag/v5.8.3
EOF
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

# ── Rollback mode ─────────────────────────────────────────────────────
if [[ "$1" == "--rollback" ]]; then
    echo "=============================================================="
    echo "  ROLLBACK MODE: Reverting to the apt-managed Podman version"
    echo "=============================================================="

    # Check for files installed to /usr/local
    if [[ ! -f /usr/local/bin/podman ]] && [[ ! -d /usr/local/libexec/podman ]]; then
        echo "No locally installed Podman found in /usr/local. Nothing to roll back."
        exit 0
    fi

    # Capture active state of Podman services (user)
    USER_SERVICE_ACTIVE=false
    if systemctl --user is-active --quiet podman.service 2>/dev/null; then
        USER_SERVICE_ACTIVE=true
    fi
    USER_SOCKET_ACTIVE=false
    if systemctl --user is-active --quiet podman.socket 2>/dev/null; then
        USER_SOCKET_ACTIVE=true
    fi

    echo "==> Stopping any running Podman user services..."
    if [[ "$USER_SERVICE_ACTIVE" == true ]]; then
        systemctl --user stop podman.service 2>/dev/null || true
    fi
    if [[ "$USER_SOCKET_ACTIVE" == true ]]; then
        systemctl --user stop podman.socket 2>/dev/null || true
    fi

    # Handle rootful Podman (if present)
    ROOTFUL_SERVICE_ACTIVE=false
    ROOTFUL_SOCKET_ACTIVE=false
    if systemctl is-active --quiet podman.service 2>/dev/null; then
        ROOTFUL_SERVICE_ACTIVE=true
    fi
    if systemctl is-active --quiet podman.socket 2>/dev/null; then
        ROOTFUL_SOCKET_ACTIVE=true
    fi

    if [[ "$ROOTFUL_SERVICE_ACTIVE" == true || "$ROOTFUL_SOCKET_ACTIVE" == true ]]; then
        echo "Rootful Podman services detected; stopping them too..."
        if [[ "$ROOTFUL_SERVICE_ACTIVE" == true ]]; then
            sudo systemctl stop podman.service 2>/dev/null || true
        fi
        if [[ "$ROOTFUL_SOCKET_ACTIVE" == true ]]; then
            sudo systemctl stop podman.socket 2>/dev/null || true
        fi
    fi

    # Remove the locally installed files
    echo "==> Removing locally installed Podman from /usr/local..."
    sudo rm -f /usr/local/bin/podman /usr/local/bin/podman-remote 2>/dev/null || true
    sudo rm -rf /usr/local/libexec/podman 2>/dev/null || true
    sudo rm -rf /usr/local/share/man/man1/podman* 2>/dev/null || true

    # Reload systemd and clear command hash
    systemctl --user daemon-reload
    hash -r

    # Restart services that were active before rollback
    if [[ "$USER_SOCKET_ACTIVE" == true ]]; then
        systemctl --user start podman.socket 2>/dev/null || true
    fi
    if [[ "$USER_SERVICE_ACTIVE" == true ]]; then
        systemctl --user start podman.service 2>/dev/null || true
    fi
    if [[ "$ROOTFUL_SOCKET_ACTIVE" == true ]]; then
        sudo systemctl start podman.socket 2>/dev/null || true
    fi
    if [[ "$ROOTFUL_SERVICE_ACTIVE" == true ]]; then
        sudo systemctl start podman.service 2>/dev/null || true
    fi

    echo ""
    echo "=============================================="
    echo "Rollback complete. System Podman version is now:"
    podman --version
    echo "=============================================="
    exit 0
fi

# ── Fresh install mode ─────────────────────────────────────────────────
if [[ "$1" == "--fresh-install" ]]; then
    if [[ $# -ne 2 ]]; then
        echo "Usage: $0 --fresh-install <RELEASE_TAG_URL>"
        exit 1
    fi
    RELEASE_URL="$2"
    FRESH_INSTALL=true
else
    if [[ $# -ne 1 ]]; then
        usage
    fi
    RELEASE_URL="$1"
    FRESH_INSTALL=false
fi

# ── Parse URL → repo + tag ────────────────────────────────────────────
if [[ ! "$RELEASE_URL" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/tag/(.+)$ ]]; then
    echo "ERROR: URL must be a GitHub release tag URL, e.g.:"
    echo "       https://github.com/containers/podman/releases/tag/v5.8.3"
    exit 1
fi

OWNER="${BASH_REMATCH[1]}"
REPO="${BASH_REMATCH[2]}"
TAG="${BASH_REMATCH[3]}"
REPO_URL="https://github.com/${OWNER}/${REPO}"
TAG_VERSION="${TAG#v}"

echo "==> Repository : $REPO_URL"
echo "==> Tag        : $TAG (version $TAG_VERSION)"

# ── Pre‑flight: must be a normal user ──────────────────────────────────
if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Run this script as your normal user, not root."
    exit 1
fi

# ── Fresh install branch ───────────────────────────────────────────────
if [[ "$FRESH_INSTALL" == true ]]; then
    echo "==> Performing a fresh installation (no existing Podman required)."

    # ── Install build dependencies ─────────────────────────────────────
    echo ""
    echo "=============================================================="
    echo "  Installing build dependencies via apt. This may take"
    echo "  a few minutes with little visible output. Please wait..."
    echo "=============================================================="
    sudo apt update
    sudo apt install -y \
        golang-github-containers-common \
        git golang-go make gcc pkg-config \
        libgpgme-dev libassuan-dev libseccomp-dev \
        libdevmapper-dev libglib2.0-dev libsystemd-dev \
        libselinux1-dev libapparmor-dev libbtrfs-dev \
        btrfs-progs conmon crun netavark \
        uidmap libsubid-dev

    # ── Clone and compile ─────────────────────────────────────────────
    WORKDIR="$(mktemp -d /tmp/podman-build.XXXXXX)"
    echo ""
    echo "=============================================================="
    echo "  Cloning repository. Network speed dependent, but usually"
    echo "  completes quickly. No output while cloning..."
    echo "=============================================================="
    git clone "$REPO_URL" "$WORKDIR"
    cd "$WORKDIR"
    git -c advice.detachedHead=false checkout "$TAG"

    echo ""
    echo "=============================================================="
    echo "  Building Podman from source. This step CAN TAKE 10–20"
    echo "  MINUTES with no progress output. Do NOT interrupt it."
    echo "  Let it finish even if the terminal seems frozen."
    echo "=============================================================="
    make BUILDTAGS="selinux seccomp systemd exclude_graphdriver_devicemapper"

    # ── Install to /usr/local ─────────────────────────────────────────
    echo "==> Installing to /usr/local..."
    sudo make install PREFIX=/usr/local

    # ── Verify the installation ───────────────────────────────────────
    hash -r
    echo "==> Verifying the new binary..."
    INSTALLED_VERSION="$(podman --version | grep -oP '\d+\.\d+\.\d+')"
    if [[ "$INSTALLED_VERSION" != "$TAG_VERSION" ]]; then
        echo "ERROR: Installation verification failed."
        echo "Expected $TAG_VERSION but got $INSTALLED_VERSION."
        false   # triggers cleanup trap
    fi

    podman info &>/dev/null || {
        echo "ERROR: 'podman info' failed after installation."
        false
    }

    echo ""
    echo "=============================================="
    echo "  Podman $TAG_VERSION installed successfully!"
    echo "  Remember: run 'hash -r' or open a new terminal"
    echo "  if your shell still shows an old version (if any)."
    echo "=============================================="
    exit 0
fi

# ── Normal update path (existing Podman required) ──────────────────────

if ! command -v podman &>/dev/null; then
    echo "ERROR: 'podman' not found. Use --fresh-install if you have none."
    exit 1
fi

CURRENT_VERSION="$(podman --version | grep -oP '\d+\.\d+\.\d+')"
if [[ -z "$CURRENT_VERSION" ]]; then
    echo "ERROR: Could not detect current Podman version."
    exit 1
fi

echo "==> Current Podman version: $CURRENT_VERSION"

if [[ "$CURRENT_VERSION" == "$TAG_VERSION" ]]; then
    echo "==> Current version is already $TAG_VERSION. Nothing to do."
    exit 0
fi

if printf '%s\n%s\n' "$TAG_VERSION" "$CURRENT_VERSION" | sort -V | head -n1 | grep -q "$TAG_VERSION"; then
    echo "ERROR: Target version ($TAG_VERSION) is not newer than current ($CURRENT_VERSION)."
    echo "Refusing to downgrade."
    exit 1
fi

echo "==> Will upgrade from $CURRENT_VERSION to $TAG_VERSION."

# ── Backups ────────────────────────────────────────────────────────────
echo "==> Saving current state..."
podman ps -a > ~/podman-state-backup.txt 2>/dev/null || touch ~/podman-state-backup.txt

# Record whether the podman socket/service are active (user‑level)
USER_SOCKET_WAS_ACTIVE=false
if systemctl --user is-active --quiet podman.socket 2>/dev/null; then
    USER_SOCKET_WAS_ACTIVE=true
fi
USER_SERVICE_WAS_ACTIVE=false
if systemctl --user is-active --quiet podman.service 2>/dev/null; then
    USER_SERVICE_WAS_ACTIVE=true
fi

# ── Install build dependencies ─────────────────────────────────────────
echo ""
echo "=============================================================="
echo "  Installing build dependencies via apt. This may take"
echo "  a few minutes with little visible output. Please wait..."
echo "=============================================================="
sudo apt update
sudo apt install -y \
    golang-github-containers-common \
    git golang-go make gcc pkg-config \
    libgpgme-dev libassuan-dev libseccomp-dev \
    libdevmapper-dev libglib2.0-dev libsystemd-dev \
    libselinux1-dev libapparmor-dev libbtrfs-dev \
    btrfs-progs conmon crun netavark \
    uidmap libsubid-dev

# ── Clone and compile ─────────────────────────────────────────────────
WORKDIR="$(mktemp -d /tmp/podman-build.XXXXXX)"
echo ""
echo "=============================================================="
echo "  Cloning repository. Network speed dependent, but usually"
echo "  completes quickly. No output while cloning..."
echo "=============================================================="
git clone "$REPO_URL" "$WORKDIR"
cd "$WORKDIR"
git -c advice.detachedHead=false checkout "$TAG"

echo ""
echo "=============================================================="
echo "  Building Podman from source. This step CAN TAKE 10–20"
echo "  MINUTES with no progress output. Do NOT interrupt it."
echo "  Let it finish even if the terminal seems frozen."
echo "=============================================================="
make BUILDTAGS="selinux seccomp systemd exclude_graphdriver_devicemapper"

# ── Stop Podman services and all containers ───────────────────────────
echo "==> Stopping all containers and Podman services safely..."
# Gracefully stop all user containers
podman stop --all 2>/dev/null || true
# Stop user‑level Podman socket and service
systemctl --user stop podman.socket podman.service 2>/dev/null || true

# Optional: rootful Podman
ROOTFUL_WAS_ACTIVE=false
if systemctl is-active --quiet podman.service 2>/dev/null; then
    echo "Rootful Podman service detected; stopping it too..."
    sudo systemctl stop podman.socket podman.service 2>/dev/null || true
    ROOTFUL_WAS_ACTIVE=true
fi

# ── Install to /usr/local ─────────────────────────────────────────────
echo "==> Installing to /usr/local..."
sudo make install PREFIX=/usr/local

# ── Verify the installation ───────────────────────────────────────────
hash -r
echo "==> Verifying the new binary..."
INSTALLED_VERSION="$(podman --version | grep -oP '\d+\.\d+\.\d+')"
if [[ "$INSTALLED_VERSION" != "$TAG_VERSION" ]]; then
    echo "ERROR: Installation verification failed."
    echo "Expected $TAG_VERSION but got $INSTALLED_VERSION."
    false
fi

podman info &>/dev/null || {
    echo "ERROR: 'podman info' failed after installation."
    false
}

echo "==> New Podman version verified: $INSTALLED_VERSION"
podman --version
which podman

# ── Database migration ────────────────────────────────────────────────
echo "==> Running database migration (podman system migrate)..."
podman system migrate --migrate-db || echo "Migration finished (warnings may appear if DB is already migrated)."

# ── Reload systemd and restart the socket first ───────────────────────
systemctl --user daemon-reload

if [[ "$USER_SOCKET_WAS_ACTIVE" == true ]]; then
    echo "==> Restarting podman.socket..."
    systemctl --user start podman.socket 2>/dev/null || true
    echo "==> Waiting for podman.socket to be listening..."
    for i in {1..10}; do
        if systemctl --user is-active --quiet podman.socket && \
           systemctl --user status podman.socket | grep -q 'listening'; then
            break
        fi
        sleep 1
    done
fi

if [[ "$USER_SERVICE_WAS_ACTIVE" == true ]]; then
    systemctl --user start podman.service 2>/dev/null || true
fi

# ── Restart containers that were previously running (user only) ───────
echo "==> Restarting containers that were previously running..."
RESTARTED_COUNT=0
QUADLET_UNITS_STARTED=()
if [[ -s ~/podman-state-backup.txt ]]; then
    while read -r name; do
        [[ -z "$name" ]] && continue
        # Check for user Quadlet file
        if [[ -f "$HOME/.config/containers/systemd/${name}.container" ]]; then
            echo "   [Quadlet] starting user unit: ${name}.service"
            systemctl --user start "${name}.service" 2>/dev/null || true
            QUADLET_UNITS_STARTED+=("${name}.service")
        else
            # Not a Quadlet container, start normally
            podman start "$name" 2>/dev/null || true
        fi
        ((RESTARTED_COUNT++)) || true
    done < <(grep 'Up' ~/podman-state-backup.txt | awk '{print $NF}')
    echo "Container restart completed ($RESTARTED_COUNT containers processed)."
    if [[ ${#QUADLET_UNITS_STARTED[@]} -gt 0 ]]; then
        echo "Quadlet units started: ${QUADLET_UNITS_STARTED[*]}"
    fi
else
    echo "No previous container state backup found. Skipping container restart."
fi

# Restart rootful Podman if we stopped it
if [[ "$ROOTFUL_WAS_ACTIVE" == true ]]; then
    echo "Restarting rootful Podman services..."
    sudo systemctl start podman.socket podman.service 2>/dev/null || true
fi

echo ""
echo "=============================================="
echo "  Podman successfully updated to $TAG_VERSION!"
echo "  ** IMPORTANT: Always check 'podman ps -a' to confirm all"
echo "     containers are running. If not, you can restart them"
echo "     manually with 'podman start <name>' or 'podman start --all'."
echo "     If your containers are managed by Quadlet (systemd units),"
echo "     restart them with:"
echo "       systemctl --user start \$(ls ~/.config/containers/systemd/*.container | xargs -n1 basename | sed 's/\.container\$//')"
echo "     If you run rootful containers (sudo podman), you must restart"
echo "     them manually. For root Quadlet containers, use:"
echo "       sudo systemctl restart \$(ls /etc/containers/systemd/*.container | xargs -n1 basename | sed 's/\.container\$//')"
echo "     Also verify the podman socket:"
echo "       systemctl --user status podman.socket"
echo "     If you use docker.sock compatibility, check that too:"
echo "       systemctl --user status podman-docker.socket   (if applicable)"
echo "  ** If your terminal still shows the old version,"
echo "     run 'hash -r' or open a new terminal. **"
echo "=============================================="
