#!/usr/bin/env bash
#
# docker.sh - install Docker Engine on Debian from the upstream repository
#
#   bash docker.sh              report only, changes nothing (default)
#   bash docker.sh --apply      perform the installation
#
# Idempotent: on a host that already has Docker, every section reports [ok]
# and nothing is written.
#
# Debian ships a "docker.io" package, but it lags upstream and does not carry
# the compose plugin. This uses Docker's own repository instead.

set -uo pipefail

MODE="check"
case "${1:-}" in
  --apply)    MODE="apply" ;;
  --check|"") MODE="check" ;;
  *) echo "Unknown option: $1"; exit 2 ;;
esac

KEYRING="/etc/apt/keyrings/docker.asc"
SOURCES="/etc/apt/sources.list.d/docker.list"
DAEMON_JSON="/etc/docker/daemon.json"

ok()   { echo "  [ok]      $*"; }
todo() { echo "  [TODO]    $*"; }
did()  { echo "  [done]    $*"; }
warn() { echo "  [WARNING] $*"; }

if [ "$(id -u)" -ne 0 ]; then echo "Must run as root."; exit 1; fi

CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
ARCH="$(dpkg --print-architecture)"

echo "=============================================="
echo " docker.sh  -  mode: $MODE"
echo " debian $CODENAME / $ARCH"
echo "=============================================="
echo

# ---------------------------------------------------------------- 1. repository
echo "--- 1. Upstream repository ---"
if [ -f "$KEYRING" ] && [ -f "$SOURCES" ]; then
  ok "already configured"
else
  if [ "$MODE" = "check" ]; then
    todo "add Docker's signing key to $KEYRING"
    todo "add $SOURCES for suite '$CODENAME'"
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq ca-certificates curl >/dev/null 2>&1
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o "$KEYRING"
    chmod a+r "$KEYRING"
    printf 'deb [arch=%s signed-by=%s] https://download.docker.com/linux/debian %s stable\n' \
      "$ARCH" "$KEYRING" "$CODENAME" > "$SOURCES"
    did "repository configured for '$CODENAME'"
  fi
fi
echo

# ---------------------------------------------------------------- 2. packages
echo "--- 2. Packages ---"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "docker $(docker --version | awk '{print $3}' | tr -d ,) with compose plugin"
else
  if [ "$MODE" = "check" ]; then
    todo "install docker-ce, containerd, buildx and compose plugins"
  else
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
    if command -v docker >/dev/null 2>&1; then
      did "installed $(docker --version)"
    else
      warn "installation failed"
      exit 1
    fi
  fi
fi
echo

# ---------------------------------------------------------------- 3. daemon
echo "--- 3. Daemon configuration ---"
if [ -f "$DAEMON_JSON" ]; then
  ok "already configured"
else
  if [ "$MODE" = "check" ]; then
    todo "cap container logs - the json-file driver is unbounded by default"
    todo "enable live-restore so containers survive a daemon restart"
  else
    mkdir -p /etc/docker
    cat > "$DAEMON_JSON" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
EOF
    systemctl restart docker
    did "logs capped at 3x10 MB per container, live-restore on"
  fi
fi
echo

# ---------------------------------------------------------------- 4. firewall
echo "--- 4. Firewall interaction ---"
if command -v nft >/dev/null 2>&1 && nft list chain inet filter forward 2>/dev/null | grep -q 'docker0'; then
  ok "forward chain permits Docker bridges"
else
  if command -v nft >/dev/null 2>&1; then
    warn "the forward chain does not mention docker0"
    echo "            A bare 'policy drop' there blocks all container traffic,"
    echo "            regardless of Docker's own rules. Apply this repository's"
    echo "            bootstrap/nftables.conf before starting any stack."
  else
    ok "no nftables ruleset present, nothing to reconcile"
  fi
fi
echo

echo "=============================================="
if [ "$MODE" = "check" ]; then
  echo " Nothing changed. To install:"
  echo "     bash docker.sh --apply"
else
  echo " Done. Verify with:"
  echo "     docker run --rm hello-world"
fi
echo "=============================================="
