#!/usr/bin/env bash
set -Eeuo pipefail

echo "=============================================="
echo "  Preparing system for Podman v6.0.0"
echo "  This will:"
echo "    - Build & install Netavark 2.0.0"
echo "    - Build & install Aardvark-dns 2.0.0"
echo "    - Create rootless storage config files"
echo "    - (Optional) Run the Podman upgrade script"
echo "=============================================="
echo ""

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

# ---------- Ensure build tools ----------
echo "==> Installing build dependencies (cargo, protoc, git)..."
sudo apt update -qq
sudo apt install -y -qq git make cargo rustc protobuf-compiler

BUILD_DIR=""
trap '[[ -n "$BUILD_DIR" ]] && rm -rf "$BUILD_DIR"' EXIT

# ---------- Netavark 2.0.0 ----------
if command -v netavark &>/dev/null && [[ "$(netavark --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')" == "2.0.0" ]]; then
    echo "==> Netavark 2.0.0 already present, skipping."
else
    echo "==> Building Netavark 2.0.0..."
    BUILD_DIR=$(mktemp -d)
    cd "$BUILD_DIR"
    git clone --branch v2.0.0 --depth 1 https://github.com/containers/netavark.git
    cd netavark
    make build
    sudo cp bin/netavark /usr/local/bin/netavark
    echo "Netavark 2.0.0 installed to /usr/local/bin/netavark"
fi

# ---------- Aardvark-dns 2.0.0 ----------
if command -v aardvark-dns &>/dev/null && [[ "$(aardvark-dns --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')" == "2.0.0" ]]; then
    echo "==> Aardvark-dns 2.0.0 already present, skipping."
else
    echo "==> Building Aardvark-dns 2.0.0..."
    BUILD_DIR=$(mktemp -d)
    cd "$BUILD_DIR"
    git clone --branch v2.0.0 --depth 1 https://github.com/containers/aardvark-dns.git
    cd aardvark-dns
    make build
    sudo cp bin/aardvark-dns /usr/local/bin/aardvark-dns
    echo "Aardvark-dns 2.0.0 installed to /usr/local/bin/aardvark-dns"
fi

echo "==> Installing netavark and aardvark-dns to /usr/lib/podman/..."
sudo mkdir -p /usr/lib/podman
sudo cp /usr/local/bin/netavark /usr/lib/podman/netavark

if [[ "$(/usr/lib/podman/aardvark-dns --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+')" != "2.0.0" ]]; then
    pkill -f aardvark-dns 2>/dev/null || true
    sudo cp /usr/local/bin/aardvark-dns /usr/lib/podman/aardvark-dns
else
    echo "==> /usr/lib/podman/aardvark-dns already 2.0.0, skipping."
fi

echo "==> Verifying:"
/usr/lib/podman/netavark --version
/usr/lib/podman/aardvark-dns --version

# ---------- Config files ----------
echo "==> Setting up containers configuration for rootless Podman v6..."
sudo mkdir -p /etc/containers /usr/share/containers /usr/share/containers/seccomp

# Try to use the official containers/common v0.68.0 configs; fall back to minimal
if git clone --depth 1 --branch v0.68.0 https://github.com/containers/common.git /tmp/common-0.68.0 2>/dev/null; then
    sudo cp /tmp/common-0.68.0/pkg/config/containers.conf /etc/containers/containers.conf
    sudo cp /tmp/common-0.68.0/pkg/config/containers.conf /usr/share/containers/containers.conf
    sudo cp /tmp/common-0.68.0/pkg/config/registries.conf /etc/containers/registries.conf
    sudo cp /tmp/common-0.68.0/pkg/config/storage.conf /etc/containers/storage.conf
    sudo cp /tmp/common-0.68.0/pkg/seccomp/*.json /usr/share/containers/seccomp/ 2>/dev/null || true
    rm -rf /tmp/common-0.68.0
    echo "Installed official containers-common v0.68.0 configs."
else
    echo "Tag v0.68.0 not found; creating minimal rootless config."
    cat <<'CFG' | sudo tee /etc/containers/containers.conf > /dev/null
[engine]
events_logger = "journald"
runtime = "crun"
[network]
network_backend = "netavark"
CFG
    USER_ID=$(id -u)
    cat <<STOCFG | sudo tee /etc/containers/storage.conf > /dev/null
[storage]
driver = "overlay"
runroot = "/run/user/${USER_ID}/containers"
graphroot = "/home/${USER}/.local/share/containers/storage"
STOCFG
    sudo cp /etc/containers/containers.conf /usr/share/containers/containers.conf
    echo "Minimal rootless config created."
fi

# ---------- Verify ----------
echo ""
echo "New versions:"
netavark --version
aardvark-dns --version
echo "Config files in /etc/containers:"
ls -l /etc/containers/containers.conf /etc/containers/storage.conf

echo ""
echo "=============================================="
echo " Dependencies are ready for Podman v6.0.0!"
echo " You can now run your Podman upgrade script:"
echo "   ./podman-version-updater.sh https://github.com/podman-container-tools/podman/releases/tag/v6.0.0"
echo "=============================================="

# ---------- Optional automatic upgrade ----------
if [[ $# -ge 1 ]]; then
    UPDATE_SCRIPT="$1"
    PODMAN_TAG="${2:-https://github.com/podman-container-tools/podman/releases/tag/v6.0.0}"
    if [[ -x "$UPDATE_SCRIPT" ]]; then
        echo ""
        echo "==> Automatically running: $UPDATE_SCRIPT $PODMAN_TAG"
        "$UPDATE_SCRIPT" "$PODMAN_TAG"
    else
        echo "ERROR: $UPDATE_SCRIPT not found or not executable."
        exit 1
    fi
fi
