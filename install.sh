#!/bin/sh
# Synapse installer / uninstaller — the only file this project publishes.
#
#   install:    curl -fsSL https://raw.githubusercontent.com/D-7J/synapse/main/install.sh | sudo sh
#   uninstall:  curl -fsSL https://raw.githubusercontent.com/D-7J/synapse/main/install.sh | sudo sh -s uninstall
#
# Install downloads the prebuilt binary for this host's CPU architecture from the GitHub
# release, verifies it against the release checksums, installs /usr/local/bin/synapse and
# opens the interactive menu. Uninstall stops and deletes every synapse-* service, the
# binary and /etc/synapse.
#
# Supported: any Linux distribution — Ubuntu/Debian, CentOS/AlmaLinux/Rocky, Fedora, Arch,
# openSUSE, Alpine. The binary is static (built CGO-free), so there is one artefact per
# architecture (amd64, arm64), never one per distro. `iptables` is needed only for the
# RST-drop firewall option, `iproute2` only for tun mode, systemd only to run as a service.
#
# POSIX sh on purpose: a fresh VPS image is not guaranteed to have bash, and `curl | sh` on
# a box with no bash failing at line 1 is a bad first impression.
set -eu

REPO="${SYNAPSE_REPO:-D-7J/synapse}"
VERSION="${SYNAPSE_VERSION:-latest}"
BIN_DIR="${SYNAPSE_BIN_DIR:-/usr/local/bin}"
BIN_NAME="synapse"
CONFIG_DIR="/etc/synapse"
UNIT_DIR="/etc/systemd/system"

# --- output ----------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET='\033[0m'; C_GREEN='\033[32m'; C_RED='\033[31m'
  C_YELLOW='\033[33m'; C_CYAN='\033[36m'; C_GRAY='\033[90m'
else
  C_RESET=''; C_GREEN=''; C_RED=''; C_YELLOW=''; C_CYAN=''; C_GRAY=''
fi

say()  { printf "%b[*]%b %s\n" "$C_GRAY" "$C_RESET" "$1"; }
ok()   { printf "%b✓%b %s\n"   "$C_GREEN" "$C_RESET" "$1"; }
warn() { printf "%b!%b %s\n"   "$C_YELLOW" "$C_RESET" "$1"; }
die()  { printf "%b✗%b %s\n"   "$C_RED" "$C_RESET" "$1" >&2; exit 1; }

need_root() { [ "$(id -u)" = "0" ] || die "run as root (prefix the command with sudo)"; }

# --- uninstall -------------------------------------------------------------------------

uninstall() {
  need_root
  say "removing synapse"

  # Stop, disable and delete every tunnel service this project installed. Stopping the unit
  # sends the process SIGTERM, which is also what makes it withdraw its own firewall rules
  # before it exits, so there is nothing left in iptables to sweep by hand.
  if command -v systemctl >/dev/null 2>&1; then
    UNITS=$(systemctl list-unit-files --no-legend "$BIN_NAME-*.service" 2>/dev/null | awk '{print $1}')
    for u in $UNITS; do
      systemctl disable --now "$u" >/dev/null 2>&1 && ok "stopped $u" || warn "could not stop $u"
    done
    rm -f "$UNIT_DIR/$BIN_NAME-"*.service
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  rm -f "$BIN_DIR/$BIN_NAME"
  ok "removed $BIN_DIR/$BIN_NAME"

  # Config holds the tunnel tokens; take it too, but ask first when a human is present so a
  # reinstall-in-place does not silently lose every tunnel's settings.
  if [ -d "$CONFIG_DIR" ]; then
    REPLY=y
    if [ -t 0 ]; then
      printf "%bremove %s and all tunnel configs? [Y/n] %b" "$C_YELLOW" "$CONFIG_DIR" "$C_RESET"
      read -r REPLY || REPLY=y
    fi
    case "${REPLY:-y}" in
      n|N) say "kept $CONFIG_DIR" ;;
      *)   rm -rf "$CONFIG_DIR"; ok "removed $CONFIG_DIR" ;;
    esac
  fi

  ok "synapse uninstalled"
  exit 0
}

# --- install ---------------------------------------------------------------------------

install_synapse() {
  need_root
  [ "$(uname -s)" = "Linux" ] || die "synapse ships Linux binaries only; this is $(uname -s)"

  case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die "no prebuilt binary for $(uname -m) — only amd64 and arm64 are published" ;;
  esac

  # One of curl or wget is enough; minimal images sometimes carry only one.
  if command -v curl >/dev/null 2>&1; then
    fetch()      { curl -fsSL "$1"; }
    fetch_file() { curl -fsSL "$1" -o "$2"; }
  elif command -v wget >/dev/null 2>&1; then
    fetch()      { wget -qO- "$1"; }
    fetch_file() { wget -qO "$2" "$1"; }
  else
    die "need curl or wget"
  fi
  command -v tar >/dev/null 2>&1 || die "need tar"

  if [ "$VERSION" = "latest" ]; then
    say "resolving the latest release..."
    # Parse the tag out of the releases API rather than following /releases/latest, which
    # redirects to an HTML page some minimal images cannot follow.
    VERSION=$(fetch "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -n1)
    [ -n "$VERSION" ] || die "could not resolve the latest release (network blocked? set SYNAPSE_VERSION=vX.Y.Z)"
  fi
  say "installing synapse $VERSION for linux/$ARCH"

  BASE="https://github.com/$REPO/releases/download/$VERSION"
  TARBALL="synapse_${VERSION}_linux_${ARCH}.tar.gz"

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT INT TERM

  say "downloading $TARBALL"
  fetch_file "$BASE/$TARBALL" "$TMP/$TARBALL" || die "download failed: $BASE/$TARBALL"

  # The checksum is not optional. This binary terminates a tunnel and holds its token; a
  # truncated download over a lossy link is the *likely* failure here, not the exotic one,
  # and it would install a corrupt binary that systemd then restart-loops on.
  if fetch_file "$BASE/checksums.txt" "$TMP/checksums.txt" 2>/dev/null; then
    if command -v sha256sum >/dev/null 2>&1; then
      # Match the filename in field 2 whether sha256sum wrote it in text mode ("<hash>  file")
      # or binary mode ("<hash> *file") — the separator differs by platform, the hash does not.
      EXPECTED=$(awk -v f="$TARBALL" '{ n=$2; sub(/^\*/, "", n); if (n == f) print $1 }' "$TMP/checksums.txt")
      ACTUAL=$(sha256sum "$TMP/$TARBALL" | awk '{print $1}')
      [ -n "$EXPECTED" ] || die "no checksum listed for $TARBALL"
      [ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch — got $ACTUAL, expected $EXPECTED"
      ok "checksum verified"
    else
      warn "sha256sum not found; skipping verification"
    fi
  else
    warn "no checksums.txt in the release; skipping verification"
  fi

  tar -xzf "$TMP/$TARBALL" -C "$TMP" || die "tar failed — the download is probably truncated"
  [ -f "$TMP/$BIN_NAME" ] || die "$BIN_NAME missing from the tarball"

  mkdir -p "$BIN_DIR"
  # Install to a temporary name and rename into place: mv within one filesystem is atomic,
  # so an upgrade can never leave a half-written binary where a running service will exec it.
  install -m 0755 "$TMP/$BIN_NAME" "$BIN_DIR/.$BIN_NAME.new"
  mv -f "$BIN_DIR/.$BIN_NAME.new" "$BIN_DIR/$BIN_NAME"
  ok "installed $BIN_DIR/$BIN_NAME ($("$BIN_DIR/$BIN_NAME" -v))"

  if command -v systemctl >/dev/null 2>&1; then
    RUNNING=$(systemctl list-units --type=service --state=running --no-legend "$BIN_NAME-*" 2>/dev/null \
      | awk '{print $1}')
    if [ -n "$RUNNING" ]; then
      say "restarting existing tunnels onto the new binary"
      for unit in $RUNNING; do
        systemctl restart "$unit" && ok "restarted $unit" || warn "could not restart $unit"
      done
    fi
  fi

  printf "\n"
  ok "done. Run %bsynapse menu%b to configure or remove a tunnel." "$C_CYAN" "$C_RESET"
  say "uninstall everything later with:  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sudo sh -s uninstall"

  # Only launch the menu when a human is at the keyboard. `curl | sh` gives the script no
  # usable stdin, so read from the terminal explicitly; in CI or a provisioning script there
  # is no terminal and we exit quietly instead of hanging on a prompt forever.
  if [ -t 0 ]; then
    exec "$BIN_DIR/$BIN_NAME" menu
  elif [ -r /dev/tty ]; then
    exec "$BIN_DIR/$BIN_NAME" menu < /dev/tty
  fi
}

# --- dispatch --------------------------------------------------------------------------

case "${1:-install}" in
  uninstall|remove|rm) uninstall ;;
  install|"")          install_synapse ;;
  *)                   die "unknown command: $1 (use 'install' or 'uninstall')" ;;
esac
