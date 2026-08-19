#!/usr/bin/env bash
#
# harden.sh - baseline hardening for Debian 13 on a Hostinger KVM instance
#
#   bash harden.sh              report only, changes nothing (default)
#   bash harden.sh --apply      perform the changes
#   bash harden.sh --confirm    cancel the firewall auto-rollback
#
# Idempotent: running it repeatedly is harmless.

set -uo pipefail

MODE="check"
case "${1:-}" in
  --apply)    MODE="apply" ;;
  --confirm)  MODE="confirm" ;;
  --check|"") MODE="check" ;;
  *) echo "Unknown option: $1"; exit 2 ;;
esac

SSHD_DROPIN="/etc/ssh/sshd_config.d/00-hardening.conf"
CLOUDINIT_DROPIN="/etc/ssh/sshd_config.d/50-cloud-init.conf"
NFT_CONF="/etc/nftables.conf"
# The ruleset is a sibling file, not embedded here: one source of truth, and
# CI can validate it with "nft -c -f" without executing this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLLBACK_UNIT="fw-rollback"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/root/harden-backup-$STAMP"

ok()   { echo "  [ok]      $*"; }
todo() { echo "  [TODO]    $*"; }
did()  { echo "  [done]    $*"; }
warn() { echo "  [WARNING] $*"; }

if [ "$(id -u)" -ne 0 ]; then echo "Must run as root."; exit 1; fi

# ---------------------------------------------------------------- confirm mode
if [ "$MODE" = "confirm" ]; then
  if systemctl list-timers --all --no-legend 2>/dev/null | grep -q "$ROLLBACK_UNIT"; then
    systemctl stop "${ROLLBACK_UNIT}.timer" 2>/dev/null
    systemctl reset-failed "${ROLLBACK_UNIT}.service" 2>/dev/null
    did "Firewall rollback cancelled - rules are now permanent."
  else
    ok "No rollback pending. Firewall rules are already permanent."
  fi
  echo
  echo "Active ruleset:"
  nft list ruleset | sed 's/^/    /'
  exit 0
fi

echo "=============================================="
echo " harden.sh  -  mode: $MODE"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "=============================================="
[ "$MODE" = "apply" ] && { mkdir -p "$BACKUP"; echo "Backups: $BACKUP"; }
echo

# ---------------------------------------------------------------- 0. preflight
echo "--- 0. Safety preflight ---"
KEYCOUNT=$(grep -Ev '^\s*(#|$)' /root/.ssh/authorized_keys 2>/dev/null | wc -l)
KEYCOUNT=${KEYCOUNT:-0}
if [ "$KEYCOUNT" -lt 1 ]; then
  warn "root has NO authorized_keys. Disabling password login would lock you out."
  echo "  Aborting."
  exit 1
fi
ok "root has $KEYCOUNT SSH key(s) installed"
ssh-keygen -lf /root/.ssh/authorized_keys 2>/dev/null | sed 's/^/            /'
echo

# ---------------------------------------------------------------- 1. cloud-init user
echo "--- 1. cloud-init user 'debian' ---"
if id debian >/dev/null 2>&1; then
  SHADOW=$(awk -F: '$1=="debian"{print $2}' /etc/shadow)
  case "$SHADOW" in
    '!'*|'*') ok "password locked ($SHADOW) - no password login possible" ;;
    '')       warn "EMPTY password!" ;;
    *)        warn "has a password set" ;;
  esac
  if [ -f /home/debian/.ssh/authorized_keys ]; then
    warn "has its own authorized_keys:"
    ssh-keygen -lf /home/debian/.ssh/authorized_keys 2>/dev/null | sed 's/^/            /'
  else
    ok "no SSH keys of its own"
  fi
  SUDO=$(grep -rl 'debian' /etc/sudoers.d/ 2>/dev/null | head -3)
  [ -n "$SUDO" ] && warn "sudo rules: $SUDO" || ok "no sudo rules of its own"
  echo "            -> reported only, this script does not touch the account"
else
  ok "does not exist"
fi
echo

# ---------------------------------------------------------------- 2. SSH daemon
echo "--- 2. SSH daemon ---"
CUR_PW=$(sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')
CUR_ROOT=$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2}')
echo "  current: passwordauthentication=$CUR_PW  permitrootlogin=$CUR_ROOT"

if [ "$CUR_PW" = "no" ] && [ "$CUR_ROOT" = "prohibit-password" ]; then
  ok "already hardened"
else
  if [ "$MODE" = "check" ]; then
    todo "create drop-in $SSHD_DROPIN (numbered 00 so it wins over 50-cloud-init)"
    todo "  PasswordAuthentication no / PermitRootLogin prohibit-password"
    todo "  KbdInteractiveAuthentication no / X11Forwarding no / MaxAuthTries 3"
    [ -f "$CLOUDINIT_DROPIN" ] && todo "neutralise $CLOUDINIT_DROPIN (contains: $(tr '\n' ' ' < $CLOUDINIT_DROPIN))"
  else
    [ -d /etc/ssh/sshd_config.d ] && cp -a /etc/ssh/sshd_config.d "$BACKUP/" 2>/dev/null
    cat > "$SSHD_DROPIN" <<'EOF'
# Baseline hardening.
# Deliberately numbered 00: OpenSSH keeps the FIRST value it sees for a
# directive, and /etc/ssh/sshd_config.d/ is read in lexical order. A file
# numbered above 50-cloud-init.conf would be silently ignored.
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 120
ClientAliveCountMax 3
EOF
    chmod 600 "$SSHD_DROPIN"
    if [ -f "$CLOUDINIT_DROPIN" ]; then
      sed -i 's/^PasswordAuthentication.*/# neutralised by harden.sh: PasswordAuthentication yes/' "$CLOUDINIT_DROPIN"
    fi
    if sshd -t 2>/dev/null; then
      systemctl reload ssh
      did "sshd config written, validated and reloaded (open sessions survive)"
      sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|maxauthtries)' | sed 's/^/            /'
    else
      warn "sshd -t failed - rolling back, nothing changed"
      rm -f "$SSHD_DROPIN"
      [ -d "$BACKUP/sshd_config.d" ] && cp -a "$BACKUP/sshd_config.d/." /etc/ssh/sshd_config.d/
      sshd -t && echo "            rollback ok"
    fi
  fi
fi
echo

# ---------------------------------------------------------------- 3. firewall
echo "--- 3. Firewall (nftables) ---"
# The stock Debian 13 cloud image ships without the nftables package, so the
# binary has to be checked for separately - an absent 'nft' is not a config error.
NFT_PRESENT=no
command -v nft >/dev/null 2>&1 && NFT_PRESENT=yes

if [ "$NFT_PRESENT" = "yes" ] && nft list ruleset 2>/dev/null | grep -q 'chain input'; then
  ok "ruleset already present"
else
  if [ "$MODE" = "check" ]; then
    [ "$NFT_PRESENT" = "no" ] && todo "install the nftables package (not present in this image)"
    todo "install nftables ruleset: inbound SSH(22) + ICMP + established only"
    todo "  80/443 stay CLOSED until something is actually served"
    todo "  auto-rollback after 10 minutes in case it locks you out"
  else
    if [ "$NFT_PRESENT" = "no" ]; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y -qq nftables >/dev/null 2>&1
      if command -v nft >/dev/null 2>&1; then
        did "nftables package installed"
      else
        warn "could not install nftables - skipping firewall"
        echo; echo "=============================================="; exit 1
      fi
    fi
    [ -f "$NFT_CONF" ] && cp -a "$NFT_CONF" "$BACKUP/" 2>/dev/null
    if [ ! -f "$SCRIPT_DIR/nftables.conf" ]; then
      warn "$SCRIPT_DIR/nftables.conf not found - run this script from its repository checkout"
      echo; echo "=============================================="; exit 1
    fi
    install -m 0755 "$SCRIPT_DIR/nftables.conf" "$NFT_CONF"
    if nft -c -f "$NFT_CONF" 2>/dev/null; then
      # Dead man's switch: wipes the ruleset in 10 minutes unless --confirm runs.
      systemd-run --unit="$ROLLBACK_UNIT" --on-active=600 \
        /usr/sbin/nft flush ruleset >/dev/null 2>&1
      nft -f "$NFT_CONF"
      systemctl enable nftables >/dev/null 2>&1
      systemctl start nftables >/dev/null 2>&1
      did "ruleset active and persistent across reboots"
      warn "DEAD MAN'S SWITCH ARMED: the firewall wipes itself in 10 minutes."
      echo "            If you can still log in, confirm now:"
      echo "                bash harden.sh --confirm"
    else
      warn "ruleset syntax error - nothing activated"
      nft -c -f "$NFT_CONF"
    fi
  fi
fi
echo

# ---------------------------------------------------------------- 4. LLMNR
echo "--- 4. LLMNR / port 5355 ---"
if ss -tulpn 2>/dev/null | grep -q ':5355'; then
  if [ "$MODE" = "check" ]; then
    todo "disable LLMNR in systemd-resolved - closes port 5355"
  else
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nLLMNR=no\nMulticastDNS=no\n' > /etc/systemd/resolved.conf.d/00-no-llmnr.conf
    systemctl restart systemd-resolved
    did "LLMNR and mDNS disabled"
  fi
else
  ok "port 5355 already closed"
fi
echo

# ---------------------------------------------------------------- 5. auto updates
echo "--- 5. Automatic security updates ---"
UU_CONF="/etc/apt/apt.conf.d/52-harden-unattended"
if [ -f "$UU_CONF" ]; then
  ok "already configured"
else
  if [ "$MODE" = "check" ]; then
    todo "restrict unattended-upgrades to security updates only"
    todo "  automatic reboot OFF - an unattended 04:00 reboot has broken a stack before"
  else
    cat > "$UU_CONF" <<'EOF'
// Written by harden.sh
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
// Deliberately off: an unattended reboot can tear down running services.
// Kernel updates are installed but only take effect on a manual reboot;
// 'needrestart' reports when one is due.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::MailReport "on-change";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    systemctl enable --now unattended-upgrades >/dev/null 2>&1
    did "unattended-upgrades: security only, no automatic reboot"
  fi
fi
echo

# ---------------------------------------------------------------- 6. locales
echo "--- 6. Locales (the setlocale warning on login) ---"
if locale -a 2>/dev/null | grep -qi 'en_US.utf8'; then
  ok "en_US.UTF-8 present"
else
  if [ "$MODE" = "check" ]; then
    todo "generate en_US.UTF-8 and de_DE.UTF-8, set system LANG"
    todo "  (macOS sends LC_CTYPE=UTF-8, which Debian does not know)"
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq locales >/dev/null 2>&1
    sed -i 's/^# *\(en_US.UTF-8\|de_DE.UTF-8\)/\1/' /etc/locale.gen
    locale-gen >/dev/null 2>&1
    update-locale LANG=en_US.UTF-8 >/dev/null 2>&1
    printf 'AcceptEnv LANG LC_*\n' > /etc/ssh/sshd_config.d/01-locale.conf
    sshd -t && systemctl reload ssh
    did "locales generated, LANG=en_US.UTF-8"
  fi
fi
echo

# ---------------------------------------------------------------- 7. base tools
echo "--- 7. Base tooling ---"
MISSING=""
for p in git curl ca-certificates jq htop tmux rsync needrestart; do
  dpkg -s "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"
done
if [ -z "$MISSING" ]; then
  ok "all present"
else
  if [ "$MODE" = "check" ]; then
    todo "install:$MISSING"
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq $MISSING >/dev/null 2>&1
    did "installed:$MISSING"
  fi
fi
echo

# ---------------------------------------------------------------- 8. journald
echo "--- 8. Journal size ---"
if [ -f /etc/systemd/journald.conf.d/00-limits.conf ]; then
  ok "already capped"
else
  if [ "$MODE" = "check" ]; then
    todo "cap the journal at 300M so it cannot fill the disk"
  else
    mkdir -p /etc/systemd/journald.conf.d
    printf '[Journal]\nSystemMaxUse=300M\nMaxRetentionSec=1month\n' > /etc/systemd/journald.conf.d/00-limits.conf
    systemctl restart systemd-journald
    did "journal capped at 300M / 1 month"
  fi
fi
echo

echo "=============================================="
if [ "$MODE" = "check" ]; then
  echo " Nothing changed. To apply:"
  echo "     bash harden.sh --apply"
else
  echo " Done."
  echo
  echo " IMPORTANT - keep this session open and verify"
  echo " login from a SECOND terminal:"
  echo "     ssh <this host>          # a fresh login, not the one you are in"
  echo
  echo " If that works, cancel the firewall rollback:"
  echo "     bash harden.sh --confirm"
  echo
  echo " If you do nothing, the firewall removes itself"
  echo " after 10 minutes. Locking yourself out is not possible."
fi
echo "=============================================="
