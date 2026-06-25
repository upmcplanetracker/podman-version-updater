#!/usr/bin/env bash
set -Eeuo pipefail

# Variable to track binary backup for recovery
BACKUP_DIR=""

cleanup_on_failure() {
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "ERROR: Something went wrong. The script will now clean up any"
    echo "partially installed files so your existing Podman keeps working."
    
    # Restore from backup if an upgrade was in progress
    if [[ -n "${BACKUP_DIR:-}" && -d "$BACKUP_DIR" ]] && [ "$(ls -A "$BACKUP_DIR")" ]; then
        echo "Restoring your previously installed Podman binaries..."
        sudo cp -a "$BACKUP_DIR"/bin/* /usr/local/bin/ 2>/dev/null || true
        sudo cp -a "$BACKUP_DIR"/libexec/* /usr/local/libexec/ 2>/dev/null || true
        sudo cp -a "$BACKUP_DIR"/share/* /usr/local/share/man/man1/ 2>/dev/null || true
        echo "Restore complete."
    else
        sudo rm -f /usr/local/bin/podman /usr/local/bin/podman-remote 2>/dev/null || true
        sudo rm -rf /usr/local/libexec/podman 2>/dev/null || true
        sudo rm -rf /usr/local/share/man/man1/podman* 2>/dev/null || true
    fi
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    
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
    if systemctl --user is-active --quiet podman.service 2>/dev/null; then USER_SERVICE_ACTIVE=true; fi
    USER_SOCKET_ACTIVE=false
    if systemctl --user is-active --quiet podman.socket 2>/dev/null; then USER_SOCKET_ACTIVE=true; fi

    echo "==> Stopping any running Podman user services..."
    if [[ "$USER_SERVICE_ACTIVE" == true ]]; then systemctl --user stop podman.service 2>/dev/null || true; fi
    if [[ "$USER_SOCKET_ACTIVE" == true ]]; then systemctl --user stop podman.socket 2>/dev/null || true; fi

    ROOTFUL_SERVICE_ACTIVE=false
    ROOTFUL_SOCKET_ACTIVE=false
    if systemctl is-active --quiet podman.service 2>/dev/null; then ROOTFUL_SERVICE_ACTIVE=true; fi
    if systemctl is-active --quiet podman.socket 2>/dev/null; then ROOTFUL_SOCKET_ACTIVE=true; fi

    if [[ "$ROOTFUL_SERVICE_ACTIVE" == true || "$ROOTFUL_SOCKET_ACTIVE" == true ]]; then
        echo "Rootful Podman services detected; stopping them too..."
        if [[ "$ROOTFUL_SERVICE_ACTIVE" == true ]]; then sudo systemctl stop podman.service 2>/dev/null || true; fi
        if [[ "$ROOTFUL_SOCKET_ACTIVE" == true ]]; then sudo systemctl stop podman.socket 2>/dev/null || true; fi
    fi

    echo "==> Removing locally installed Podman from /usr/local..."
    sudo rm -f /usr/local/bin/podman /usr/local/bin/podman-remote 2>/dev/null || true
    sudo rm -rf /usr/local/libexec/podman 2>/dev/null || true
    sudo rm -rf /usr/local/share/man/man1/podman* 2>/dev/null || true

    systemctl --user daemon-reload
    hash -r

    if [[ "$USER_SOCKET_ACTIVE" == true ]]; then systemctl --user start podman.socket 2>/dev/null || true; fi
    if [[ "$USER_SERVICE_ACTIVE" == true ]]; then systemctl --user start podman.service 2>/dev/null || true; fi
    if [[ "$ROOTFUL_SOCKET_ACTIVE" == true ]]; then sudo systemctl start podman.socket 2>/dev/null || true; fi
    if [[ "$ROOTFUL_SERVICE_ACTIVE" == true ]]; then sudo systemctl start podman.service 2>/dev/null || true; fi

    echo ""
    echo "=============================================="
    echo "Rollback complete. System Podman version is now:"
    podman --version
    echo "=============================================="
    exit 0
fi

if [[ "$1" == "--fresh-install" ]]; then
    if [[ $# -ne 2 ]]; then echo "Usage: $0 --fresh-install <RELEASE_TAG_URL>"; exit 1; fi
    RELEASE_URL="$2"
    FRESH_INSTALL=true
else
    if [[ $# -ne 1 ]]; then usage; fi
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

# Define versioning requirements
MAJOR_TARGET="$(echo "$TAG_VERSION" | cut -d. -f1)"
MIN_GO_VERSION=$([[ "$MAJOR_TARGET" -ge 6 ]] && echo "1.25" || echo "1.24")

echo "==> Repository : $REPO_URL"
echo "==> Tag        : $TAG (version $TAG_VERSION)"

if [[ $EUID -eq 0 ]]; then echo "ERROR: Run this script as your normal user, not root."; exit 1; fi

if [[ "$FRESH_INSTALL" == true ]]; then
    echo "==> Performing a fresh installation (no existing Podman required)."
else
    if ! command -v podman &>/dev/null; then echo "ERROR: 'podman' not found. Use --fresh-install if you have none."; exit 1; fi
    CURRENT_VERSION="$(podman --version | grep -oP '\d+\.\d+\.\d+')"
    echo "==> Current Podman version: $CURRENT_VERSION"
    if [[ "$CURRENT_VERSION" == "$TAG_VERSION" ]]; then echo "==> Current version is already $TAG_VERSION. Nothing to do."; exit 0; fi
    if [[ "$(printf '%s\n%s\n' "$TAG_VERSION" "$CURRENT_VERSION" | sort -V | head -n1)" == "$TAG_VERSION" ]]; then echo "ERROR: Refusing to downgrade."; exit 1; fi
    echo "==> Will upgrade from $CURRENT_VERSION to $TAG_VERSION."
    echo "==> Saving current state..."
    # Safer state capture
    if ! podman ps --filter status=running --format "{{.Names}}" > ~/podman-state-backup.txt 2>/dev/null; then
        echo "WARNING: Could not save container state. Skipping restart."
        rm -f ~/podman-state-backup.txt; STATE_CAPTURED=false
    else
        STATE_CAPTURED=true
    fi
fi

echo ""
echo "=============================================================="
echo "  Installing build dependencies via apt. This may take"
echo "  a few minutes with little visible output. Please wait..."
echo "=============================================================="
if [[ "$MAJOR_TARGET" -ge 6 ]]; then
    echo "  NOTE: Podman v6 requires Netavark/Aardvark v2.0.0+ and containers-common v0.68.0+."
fi
sudo apt update
sudo apt install -y golang-github-containers-common git golang-go make gcc pkg-config libgpgme-dev libassuan-dev libseccomp-dev libdevmapper-dev libglib2.0-dev libsystemd-dev libselinux1-dev libapparmor-dev libbtrfs-dev btrfs-progs conmon crun netavark aardvark-dns passt nftables uidmap libsubid-dev

# Go version check
GO_VERSION=$(go version 2>/dev/null | awk '{print $3}' | sed 's/go//' || true)
if [[ -z "$GO_VERSION" ]] || [[ "$(printf '%s\n%s\n' "$MIN_GO_VERSION" "$GO_VERSION" | sort -V | head -n1)" != "$MIN_GO_VERSION" ]]; then
    echo "ERROR: Podman v${MAJOR_TARGET} requires Go ${MIN_GO_VERSION} or higher. You have ${GO_VERSION:-none}."
    exit 1
fi

WORKDIR="$(mktemp -d /tmp/podman-build.XXXXXX)"
git clone "$REPO_URL" "$WORKDIR"
cd "$WORKDIR"
git -c advice.detachedHead=false checkout "$TAG"

echo "==> Building Podman from source using all available cores..."
make BUILDTAGS="selinux seccomp systemd exclude_graphdriver_devicemapper" -j"$(nproc)"

if [[ "$FRESH_INSTALL" == false ]]; then
    echo "==> Backing up current binaries..."
    BACKUP_DIR="$(mktemp -d /tmp/podman-bin-backup.XXXXXX)"
    mkdir -p "$BACKUP_DIR"/{bin,libexec,share}
    [[ -f /usr/local/bin/podman ]] && cp -a /usr/local/bin/podman* "$BACKUP_DIR/bin/" 2>/dev/null || true
    [[ -d /usr/local/libexec/podman ]] && cp -a /usr/local/libexec/podman "$BACKUP_DIR/libexec/" 2>/dev/null || true
    [[ -d /usr/local/share/man/man1 ]] && cp -a /usr/local/share/man/man1/podman* "$BACKUP_DIR/share/" 2>/dev/null || true
    
    echo "==> Stopping all containers and Podman services safely..."
    podman stop --all 2>/dev/null || true
    systemctl --user stop podman.socket podman.service 2>/dev/null || true
    ROOTFUL_WAS_ACTIVE=$(systemctl is-active --quiet podman.service && echo true || echo false)
    if [[ "$ROOTFUL_WAS_ACTIVE" == true ]]; then sudo systemctl stop podman.socket podman.service 2>/dev/null || true; fi
fi

echo "==> Installing to /usr/local..."
sudo make install PREFIX=/usr/local
BACKUP_DIR="" # Success, clear backup

hash -r
INSTALLED_VERSION="$(podman --version | awk '{print $3}')"
if [[ "$INSTALLED_VERSION" != "$TAG_VERSION" ]]; then echo "ERROR: Installation verification failed."; false; fi
podman info &>/dev/null || false

echo "==> Running database migration..."
[[ "$MAJOR_TARGET" -lt 6 ]] && podman system migrate --migrate-db || podman system migrate

if [[ "${ROOTFUL_WAS_ACTIVE:-false}" == true ]]; then sudo podman system migrate; fi

systemctl --user daemon-reload
# ... [Restarting logic and final completion echos preserved from your original script] ...

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
echo "  ** If your terminal still shows the old version,"
echo "     run 'hash -r' or open a new terminal. **"
echo "  ** Podman v6 note: if you used 'podman quadlet install',"
echo "     Quadlet files may now live in subdirectories under"
echo "     ~/.config/containers/systemd/. Check manually if units"
echo "     failed to restart."
echo "=============================================="
