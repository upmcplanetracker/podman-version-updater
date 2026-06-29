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
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "$WORKDIR" || true    
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
  NOTE: Podman must already be installed (sudo apt install podman) before running this script.

  The <RELEASE_TAG_URL> must be a GitHub release tag URL, e.g.:
      https://github.com/podman-container-tools/podman/releases/tag/v5.8.3
EOF
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

# ---------- ROLLBACK MODE ----------
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

    echo "==> Disabling and masking system-level Podman services (rootless Quadlet setup only)..."
    sudo systemctl disable --now \
        podman.service podman.socket \
        podman-auto-update.service podman-auto-update.timer \
        podman-clean-transient.service podman-restart.service 2>/dev/null || true
    sudo systemctl mask \
        podman.service podman.socket \
        podman-auto-update.service podman-auto-update.timer \
        podman-clean-transient.service podman-restart.service 2>/dev/null || true
    sudo systemctl daemon-reload
    echo "==> System-level Podman services masked. User-level Quadlet services unaffected."
    echo "    (masking prevents systemd preset processing from re-enabling them on future upgrades)"

    echo "==> Removing locally installed Podman from /usr/local..."
    sudo rm -f /usr/local/bin/podman /usr/local/bin/podman-remote 2>/dev/null || true
    sudo rm -rf /usr/local/libexec/podman 2>/dev/null || true
    sudo rm -rf /usr/local/share/man/man1/podman* 2>/dev/null || true

    systemctl --user daemon-reload
    hash -r

    if [[ "$USER_SOCKET_ACTIVE" == true ]]; then systemctl --user start podman.socket 2>/dev/null || true; fi
    if [[ "$USER_SERVICE_ACTIVE" == true ]]; then systemctl --user start podman.service 2>/dev/null || true; fi

    echo ""
    echo "=============================================="
    echo "Rollback complete. System Podman version is now:"
    podman --version
    echo "=============================================="
    exit 0
fi

if [[ $# -ne 1 ]]; then usage; fi
RELEASE_URL="$1"

if [[ ! "$RELEASE_URL" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/tag/(.+)$ ]]; then
    echo "ERROR: URL must be a GitHub release tag URL, e.g.:"
    echo "       https://github.com/podman-container-tools/podman/releases/tag/v5.8.3"
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

# ---------- OS Compatibility Guardrail ----------
if [[ ! -f /etc/os-release ]]; then
    echo "ERROR: /etc/os-release not found. Cannot determine operating system."
    exit 1
fi

. /etc/os-release
if [[ "$ID" != "ubuntu" ]] || ! [[ "$VERSION_ID" == "26.04" || "$VERSION_ID" == "25.10" ]]; then
    echo "ERROR: This script is intended for Ubuntu 25.10 and 26.04."
    echo "Detected: ${PRETTY_NAME:-Unknown OS}"
    exit 1
fi
echo "==> OS Check Passed: $PRETTY_NAME"
# ----------------------------------------------

# ---------- Check runtime dependencies for Podman v6+ (binary versions) ----------
if [[ "$MAJOR_TARGET" -ge 6 ]]; then
    echo "==> Checking required runtime dependencies for Podman v6..."
    MISSING_DEPS=()

    check_binary_version() {
        local cmd="$1" min_ver="$2" label="$3"
        if ! command -v "$cmd" &>/dev/null; then
            MISSING_DEPS+=("$label binary not found in PATH (looked for $cmd)")
            return
        fi
        local ver
        ver=$("$cmd" --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        if [[ -z "$ver" ]]; then
            MISSING_DEPS+=("$label: cannot determine version from $cmd --version")
        elif [[ "$(printf '%s\n%s\n' "$min_ver" "$ver" | sort -V | head -n1)" != "$min_ver" ]]; then
            MISSING_DEPS+=("$label >= $min_ver (found $ver)")
        fi
    }

    check_binary_version /usr/lib/podman/netavark "2.0.0" "netavark"
    check_binary_version /usr/lib/podman/aardvark-dns "2.0.0" "aardvark-dns"

    if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
        echo "ERROR: Missing required runtime dependencies for Podman v6:"
        for dep in "${MISSING_DEPS[@]}"; do echo "  - $dep"; done
        echo ""
        echo "Run the prepare-for-podman6.sh script first, then retry."
        exit 1
    fi
    echo "==> All runtime dependencies are satisfied."
fi

# ---------- Upgrade logic ----------
if ! command -v podman &>/dev/null; then
    echo "ERROR: 'podman' not found. Install it first with 'sudo apt install podman'."
    exit 1
fi
CURRENT_VERSION="$(podman --version | grep -oP '\d+\.\d+\.\d+')"
echo "==> Current Podman version: $CURRENT_VERSION"
if [[ "$CURRENT_VERSION" == "$TAG_VERSION" ]]; then echo "==> Already at $TAG_VERSION. Nothing to do."; exit 0; fi
if [[ "$(printf '%s\n%s\n' "$TAG_VERSION" "$CURRENT_VERSION" | sort -V | head -n1)" == "$TAG_VERSION" ]]; then echo "ERROR: Refusing to downgrade."; exit 1; fi
echo "==> Will upgrade from $CURRENT_VERSION to $TAG_VERSION."
echo "==> Saving current state..."
if ! podman ps --filter status=running --format "{{.Names}}" > ~/podman-state-backup.txt 2>/dev/null; then
    echo "WARNING: Could not save container state. Skipping restart."
    rm -f ~/podman-state-backup.txt; STATE_CAPTURED=false
else
    STATE_CAPTURED=true
fi

echo ""
echo "=============================================================="
echo "  Installing build dependencies via apt. This may take"
echo "  a few minutes with little visible output. Please wait..."
echo "=============================================================="

if [[ "$MAJOR_TARGET" -ge 6 ]]; then
    echo "  NOTE: Podman v6 requires Netavark/Aardvark v2.0.0+ and containers-common v0.68.0+."
fi
# netavark and aardvark-dns are intentionally excluded here —
# for Podman v6, versions 2.0.0+ are required and must be built
# from source via prepare-for-podman6.sh before running this script.
sudo apt update
sudo apt install -y golang-github-containers-common git golang-go make gcc pkg-config libgpgme-dev libassuan-dev libseccomp-dev libdevmapper-dev libglib2.0-dev libsystemd-dev libselinux1-dev libapparmor-dev libbtrfs-dev btrfs-progs conmon crun passt nftables uidmap libsubid-dev
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

echo "==> Backing up current binaries..."
BACKUP_DIR="$(mktemp -d /tmp/podman-bin-backup.XXXXXX)"
mkdir -p "$BACKUP_DIR"/{bin,libexec,share}
[[ -f /usr/local/bin/podman ]] && cp -a /usr/local/bin/podman* "$BACKUP_DIR/bin/" 2>/dev/null || true
[[ -d /usr/local/libexec/podman ]] && cp -a /usr/local/libexec/podman "$BACKUP_DIR/libexec/" 2>/dev/null || true
[[ -d /usr/local/share/man/man1 ]] && cp -a /usr/local/share/man/man1/podman* "$BACKUP_DIR/share/" 2>/dev/null || true
    
echo "==> Stopping all containers and Podman services safely..."
podman stop --all 2>/dev/null || true
systemctl --user stop podman.socket podman.service 2>/dev/null || true

echo "==> Installing to /usr/local..."
sudo make install PREFIX=/usr/local
echo "==> Disabling system-level Podman services (rootless Quadlet setup only)..."
sudo systemctl disable --now podman.service podman.socket \
    podman-auto-update.service podman-auto-update.timer \
    podman-clean-transient.service podman-restart.service 2>/dev/null || true
sudo systemctl daemon-reload
echo "==> System-level Podman services disabled. User-level Quadlet services unaffected."
BACKUP_DIR="" # Success, clear backup

# ---------- Use absolute path to verify the new binary ----------
INSTALLED_PODMAN="/usr/local/bin/podman"

# First, do a quick version check
INSTALLED_VERSION="$("$INSTALLED_PODMAN" --version 2>/dev/null | awk '{print $3}' || echo "")"
if [[ "$INSTALLED_VERSION" != "$TAG_VERSION" ]]; then
    echo "ERROR: Installation verification failed. $INSTALLED_PODMAN reports version ${INSTALLED_VERSION:-unknown}, expected $TAG_VERSION."
    false
fi

# Now test podman info with debug output on failure
echo "==> Verifying new Podman binary..."
if ! "$INSTALLED_PODMAN" info &>/dev/null; then
    echo "ERROR: New podman binary fails to run 'podman info'. Debug output:"
    "$INSTALLED_PODMAN" --log-level=debug info 2>&1 | tail -20 || true
    false
fi

echo "==> Running database migration..."
if [[ "$MAJOR_TARGET" -lt 6 ]]; then
    "$INSTALLED_PODMAN" system migrate --migrate-db
else
    "$INSTALLED_PODMAN" system migrate
fi

systemctl --user daemon-reload

# Restart services that were previously active
if systemctl --user is-enabled podman.socket &>/dev/null; then
    systemctl --user restart podman.socket 2>/dev/null || true
fi
    
if [[ "${STATE_CAPTURED:-false}" == true && -s ~/podman-state-backup.txt ]]; then
    echo "==> Restarting previously running containers..."
    while read -r container; do
        [[ -n "$container" ]] && "$INSTALLED_PODMAN" start "$container" 2>/dev/null || true
    done < ~/podman-state-backup.txt
    rm -f ~/podman-state-backup.txt
fi

hash -r

rm -rf "$WORKDIR"

# ---------- AppArmor Fix for /usr/local/bin ----------
echo "==> Patching AppArmor profile to allow rootless Podman execution from /usr/local/bin..."
if [[ -f /etc/apparmor.d/podman ]]; then
    # This sed command is safe to run multiple times; it will only match if the unpatched string exists.
    sudo sed -Ei 's!^profile podman /usr/bin/podman!profile podman /usr/{bin,local/bin}/podman!' /etc/apparmor.d/podman
    sudo apparmor_parser -r /etc/apparmor.d/podman 2>/dev/null || true
    echo "==> AppArmor profile updated and reloaded."
else
    echo "==> No default AppArmor profile found for Podman. Skipping patch."
fi
# -----------------------------------------------------

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
echo "  ** Podman v6.x.x note: if you used 'podman quadlet install',"
echo "     Quadlet files may now live in subdirectories under"
echo "     ~/.config/containers/systemd/. Check manually if units"
echo "     failed to restart."
echo "  ** NOTE: Podman hardcodes netavark/aardvark-dns to /usr/lib/podman/ —"
echo "     if networks fail in 6.x.x, verify versions with:"
echo "       /usr/lib/podman/netavark --version"
echo "       /usr/lib/podman/aardvark-dns --version"
echo "     Both should report 2.0.0 for Podman v6."
echo "=============================================="
