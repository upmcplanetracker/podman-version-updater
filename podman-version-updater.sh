#!/usr/bin/env bash
set -Eeuo pipefail

cleanup_on_failure() {
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "ERROR: Something went wrong. The script will now clean up any"
    echo "partially installed files so your existing Podman keeps working."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    sudo rm -f /usr/local/bin/podman /usr/local/bin/podman-remote 2>/dev/null || true
    sudo rm -rf /usr/local/libexec/podman 2>/dev/null || true
    sudo rm -rf /usr/local/share/man/man1/podman* 2>/dev/null || true
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

if [[ "$1" == "--rollback" ]]; then
    echo "=============================================================="
    echo "  ROLLBACK MODE: Reverting to the apt-managed Podman version"
    echo "=============================================================="

    if [[ ! -f /usr/local/bin/podman ]] && [[ ! -d /usr/local/libexec/podman ]]; then
        echo "No locally installed Podman found in /usr/local. Nothing to roll back."
        exit 0
    fi

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

    echo "==> Removing locally installed Podman from /usr/local..."
    sudo rm -f /usr/local/bin/podman /usr/local/bin/podman-remote 2>/dev/null || true
    sudo rm -rf /usr/local/libexec/podman 2>/dev/null || true
    sudo rm -rf /usr/local/share/man/man1/podman* 2>/dev/null || true

    systemctl --user daemon-reload
    hash -r

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

if [[ $EUID -eq 0 ]]; then
    echo "ERROR: Run this script as your normal user, not root."
    exit 1
fi

if [[ "$FRESH_INSTALL" == true ]]; then
    echo "==> Performing a fresh installation (no existing Podman required)."

    echo ""
    echo "=============================================================="
    echo "  Installing build dependencies via apt. This may take"
    echo "  a few minutes with little visible output. Please wait..."
    echo "=============================================================="
    MAJOR_TARGET="$(echo "$TAG_VERSION" | cut -d. -f1)"
    if [[ "$MAJOR_TARGET" -ge 6 ]]; then
        echo ""
        echo "=============================================================="
        echo "  NOTE: Podman v6 requires Netavark/Aardvark v2.0.0+ and"
        echo "  containers-common v0.68.0+. The apt packages on your system"
        echo "  may be too old. If the build fails or 'podman info' errors"
        echo "  after install, check:"
        echo "    apt-cache policy netavark golang-github-containers-common"
        echo "=============================================================="
    fi
    sudo apt update
    sudo apt install -y \
        golang-github-containers-common \
        git golang-go make gcc pkg-config \
        libgpgme-dev libassuan-dev libseccomp-dev \
        libdevmapper-dev libglib2.0-dev libsystemd-dev \
        libselinux1-dev libapparmor-dev libbtrfs-dev \
        btrfs-progs conmon crun netavark aardvark-dns \
        passt nftables uidmap libsubid-dev

    GO_VERSION=$(go version | grep -oP 'go1\.\d+' | head -1)
    if [[ "$(printf '%s\n%s\n' "go1.25" "$GO_VERSION" | sort -V | head -n1)" != "go1.25" ]]; then
        echo "ERROR: Podman v6 requires Go 1.25 or higher. You have $GO_VERSION."
        echo "Please update your Go installation (e.g., via the official Go tarball or a PPA) before continuing."
       exit 1
    fi

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

    echo "==> Installing to /usr/local..."
    sudo make install PREFIX=/usr/local

    hash -r
    echo "==> Verifying the new binary..."
    # FIX (issue 1): capture the full version string, e.g., "5.8.3-rc1"
    INSTALLED_VERSION="$(podman --version | awk '{print $3}')"
    if [[ "$INSTALLED_VERSION" != "$TAG_VERSION" ]]; then
        echo "ERROR: Installation verification failed."
        echo "Expected $TAG_VERSION but got $INSTALLED_VERSION."
        false
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

if [[ "$(printf '%s\n%s\n' "$TAG_VERSION" "$CURRENT_VERSION" | sort -V | head -n1)" == "$TAG_VERSION" ]] && \
   [[ "$TAG_VERSION" != "$CURRENT_VERSION" ]]; then
    echo "ERROR: Target version ($TAG_VERSION) is not newer than current ($CURRENT_VERSION)."
    echo "Refusing to downgrade."
    exit 1
fi

echo "==> Will upgrade from $CURRENT_VERSION to $TAG_VERSION."

echo "==> Saving current state..."
# FIX (issue 5): detect failure to save state, warn and skip automatic restarts
if ! podman ps -a > ~/podman-state-backup.txt 2>/dev/null; then
    echo "WARNING: Could not save container state (podman ps failed)."
    echo "Automatic container restart will be skipped."
    rm -f ~/podman-state-backup.txt
    STATE_CAPTURED=false
else
    STATE_CAPTURED=true
fi

USER_SOCKET_WAS_ACTIVE=false
if systemctl --user is-active --quiet podman.socket 2>/dev/null; then
    USER_SOCKET_WAS_ACTIVE=true
fi
USER_SERVICE_WAS_ACTIVE=false
if systemctl --user is-active --quiet podman.service 2>/dev/null; then
    USER_SERVICE_WAS_ACTIVE=true
fi

echo ""
echo "=============================================================="
echo "  Installing build dependencies via apt. This may take"
echo "  a few minutes with little visible output. Please wait..."
echo "=============================================================="
MAJOR_TARGET="$(echo "$TAG_VERSION" | cut -d. -f1)"
if [[ "$MAJOR_TARGET" -ge 6 ]]; then
    echo ""
    echo "=============================================================="
    echo "  NOTE: Podman v6 requires Netavark/Aardvark v2.0.0+ and"
    echo "  containers-common v0.68.0+. The apt packages on your system"
    echo "  may be too old. If the build fails or 'podman info' errors"
    echo "  after install, check:"
    echo "    apt-cache policy netavark golang-github-containers-common"
    echo "=============================================================="
fi
sudo apt update
sudo apt install -y \
        golang-github-containers-common \
        git golang-go make gcc pkg-config \
        libgpgme-dev libassuan-dev libseccomp-dev \
        libdevmapper-dev libglib2.0-dev libsystemd-dev \
        libselinux1-dev libapparmor-dev libbtrfs-dev \
        btrfs-progs conmon crun netavark aardvark-dns \
        passt nftables uidmap libsubid-dev

GO_VERSION=$(go version | grep -oP 'go1\.\d+' | head -1)
if [[ "$(printf '%s\n%s\n' "go1.25" "$GO_VERSION" | sort -V | head -n1)" != "go1.25" ]]; then
    echo "ERROR: Podman v6 requires Go 1.25 or higher. You have $GO_VERSION."
    echo "Please update your Go installation (e.g., via the official Go tarball or a PPA) before continuing."
    exit 1
fi

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

echo "==> Stopping all containers and Podman services safely..."
podman stop --all 2>/dev/null || true
systemctl --user stop podman.socket podman.service 2>/dev/null || true

ROOTFUL_WAS_ACTIVE=false
if systemctl is-active --quiet podman.service 2>/dev/null; then
    echo "Rootful Podman service detected; stopping it too..."
    sudo systemctl stop podman.socket podman.service 2>/dev/null || true
    ROOTFUL_WAS_ACTIVE=true
fi

echo "==> Installing to /usr/local..."
sudo make install PREFIX=/usr/local

hash -r
echo "==> Verifying the new binary..."
# FIX (issue 1): capture full version string to match pre-release tags
INSTALLED_VERSION="$(podman --version | awk '{print $3}')"
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

echo "==> Running database migration (podman system migrate)..."
MAJOR_VERSION="$(echo "$INSTALLED_VERSION" | cut -d. -f1)"
if [[ "$MAJOR_VERSION" -lt 6 ]]; then
    podman system migrate --migrate-db || echo "Migration finished (warnings may appear if DB is already migrated)."
else
    podman system migrate || echo "Migration step complete."
fi

# FIX (issue 3): run rootful migration if root service was active
if [[ "$ROOTFUL_WAS_ACTIVE" == true ]]; then
    echo "==> Running rootful database migration (sudo podman system migrate)..."
    sudo podman system migrate || echo "Warning: rootful migration encountered issues, but continuing."
fi

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

echo "==> Restarting containers that were previously running..."
RESTARTED_COUNT=0
QUADLET_UNITS_STARTED=()
# FIX (issue 2 & 5): use label detection for Quadlet, only process if state was captured
if [[ "$STATE_CAPTURED" == true && -s ~/podman-state-backup.txt ]]; then
    while read -r name; do
        [[ -z "$name" ]] && continue
        # FIX (issue 2): check PODMAN_SYSTEMD_UNIT label instead of guessing file name
        unit=""
        if podman inspect "$name" &>/dev/null; then
            unit=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$name" 2>/dev/null || true)
        fi
        if [[ -n "$unit" ]]; then
            echo "   [Quadlet] starting user unit: $unit"
            systemctl --user start "$unit" 2>/dev/null || true
            QUADLET_UNITS_STARTED+=("$unit")
        else
            podman start "$name" 2>/dev/null || true
        fi
        ((RESTARTED_COUNT++)) || true
    done < <(grep 'Up' ~/podman-state-backup.txt | awk '{print $NF}')
    echo "Container restart completed ($RESTARTED_COUNT containers processed)."
    if [[ ${#QUADLET_UNITS_STARTED[@]} -gt 0 ]]; then
        echo "Quadlet units started: ${QUADLET_UNITS_STARTED[*]}"
    fi
else
    echo "No previous container state backup found (or state capture failed). Skipping container restart."
fi

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
echo "       systemctl --user start \$(find ~/.config/containers/systemd -name '*.container' | xargs -r -n1 basename | sed 's/\.container\$//')"
echo "     If you run rootful containers (sudo podman), you must restart"
echo "     them manually. For root Quadlet containers, use:"
echo "       sudo systemctl restart \$(find /etc/containers/systemd -name '*.container' | xargs -r -n1 basename | sed 's/\.container\$//')"
echo "     Also verify the podman socket:"
echo "       systemctl --user status podman.socket"
echo "     If you use docker.sock compatibility, check that too:"
echo "       systemctl --user status podman-docker.socket   (if applicable)"
echo "  ** If your terminal still shows the old version,"
echo "     run 'hash -r' or open a new terminal. **"
echo "  ** Podman v6 note: if you used 'podman quadlet install',"
echo "     Quadlet files may now live in subdirectories under"
echo "     ~/.config/containers/systemd/. Check manually if units"
echo "     failed to restart."
echo "=============================================="
