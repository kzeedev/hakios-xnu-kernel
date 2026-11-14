#!/usr/bin/env bash
set -Eeuo pipefail

# Single entrypoint for a Droidspaces Debian container:
#   hakios-qemu install
#   hakios-qemu start
#   hakios-qemu stop
#   hakios-qemu status

REPO_URL="${HAKIOS_REPO_URL:-https://github.com/kzeedev/hakios-xnu-kernel.git}"
HAKIOS_HOME="${HAKIOS_HOME:-/opt/hakios-qemu}"
HAKIOS_REPO_DIR="${HAKIOS_REPO_DIR:-$HAKIOS_HOME/source}"
IPSW_NAME="iPhone10,3,iPhone10,6_16.5_20F66_Restore.ipsw"
IPSW_URL="https://updates.cdn-apple.com/2023SpringFCS/fullrestores/032-65246/0F89A1E3-C4D6-40C6-863A-95FA62A79D4B/$IPSW_NAME"
IPSW_BYTES=6165698198
QEMU_RAM_GB="${HAKIOS_QEMU_RAM_GB:-7}"
QEMU_SECONDS="${HAKIOS_QEMU_SECONDS:-86400}"
QEMU_LOG="${HAKIOS_LOG:-$HAKIOS_HOME/qemu.log}"
QEMU_PIDFILE="${HAKIOS_PIDFILE:-$HAKIOS_HOME/qemu.pid}"

usage() {
  cat <<'EOF'
HakiOS QEMU runner for Droidspaces containers

Commands:
  hakios-qemu install
      Install QEMU, firmware, and all HakiOS guest build deps.
      Downloads the iPhone X iOS 16.5 IPSW if needed and prepares the guest image.
  hakios-qemu start
      Start the HakiOS VM in the background.
  hakios-qemu stop
      Gracefully stop the VM.
  hakios-qemu status
      Show whether the VM is running.
  hakios-qemu help
      Show this message.

Environment:
  HAKIOS_HOME          Base dir for work files (default: /opt/hakios-qemu)
  HAKIOS_REPO_DIR      HakiOS source checkout (default: /opt/hakios-qemu/source)
  HAKIOS_REPO_URL      Git repo URL (default: https://github.com/kzeedev/hakios-xnu-kernel.git)
  HAKIOS_IPSW          Path to an existing IPSW archive
  HAKIOS_QEMU_RAM_GB   Guest memory, default 7
  HAKIOS_QEMU_SECONDS  Startup timeout or guest lifetime, default 86400
  HAKIOS_LOG           Log file, default /opt/hakios-qemu/qemu.log
  HAKIOS_PIDFILE       PID file, default /opt/hakios-qemu/qemu.pid

Notes:
  - VNC listens on 127.0.0.1:5900 inside the container.
  - Droidspaces needs a port forward if you want to reach VNC from Android.
  - This script prepares the HakiOS QEMU guest using the repo’s prebuilt assets and an IPSW.
EOF
}

die() {
  echo "hakios-qemu: $*" >&2
  exit 1
}

need_root() {
  [[ $EUID -eq 0 ]] || die "run this script as root"
}

install_7zip() {
  local z7 ver major arch page url tmpdir binary

  z7="$(command -v 7z || command -v 7zz || true)"
  if [[ -n "$z7" ]]; then
    ver="$("$z7" 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -n 1 || true)"
    major="${ver%%.*}"
    if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 23 )); then
      echo "Using 7-Zip $ver"
      return
    fi
  fi

  case "$(dpkg --print-architecture)" in
    arm64) arch=arm64 ;;
    amd64) arch=x64 ;;
    *) die "automatic 7-Zip install supports arm64 and amd64 only" ;;
  esac

  echo "Debian's 7-Zip is missing or too old; fetching the official Linux build..."
  page="$(python3 - <<'PY'
from urllib.request import urlopen
print(urlopen("https://www.7-zip.org/download.html", timeout=30).read().decode("utf-8", "replace"))
PY
)" || die "cannot read the 7-Zip download page"

  url="$(python3 - "$arch" "$page" <<'PY'
import re, sys
from html.parser import HTMLParser
arch, html = sys.argv[1:3]

class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            href = dict(attrs).get("href", "")
            if href:
                self.hrefs.append(href)

links = Links()
links.feed(html)
pattern = re.compile(rf"^/a/7z[0-9]+-linux-{re.escape(arch)}\\.tar\\.xz$")
for href in links.hrefs:
    if pattern.match(href):
        print("https://www.7-zip.org" + href)
        break
PY
)" || true

  [[ "$url" == https://www.7-zip.org/a/7z*-linux-"$arch".tar.xz ]] || die "could not find the official 7-Zip archive for $arch"

  tmpdir="$(mktemp -d)"
  curl -fL --retry 3 --connect-timeout 30 "$url" -o "$tmpdir/7zip.tar.xz"
  tar -xJf "$tmpdir/7zip.tar.xz" -C "$tmpdir"

  binary="$(find "$tmpdir" -type f -name 7zz -print -quit)"
  [[ -n "$binary" ]] || { rm -rf "$tmpdir"; die "7-Zip archive did not contain 7zz"; }

  install -m 0755 "$binary" /usr/local/bin/7zz
  ln -sfn /usr/local/bin/7zz /usr/local/bin/7z
  rm -rf "$tmpdir"
}

install_runtime() {
  need_root

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    build-essential ca-certificates clang curl file git lld make python3 qemu-system-arm \
    qemu-efi-aarch64 qemu-utils tar xz-utils lz4 util-linux iproute2 net-tools socat

  install_7zip

  command -v qemu-system-aarch64 >/dev/null || die "qemu-system-aarch64 is missing"
  qemu-system-aarch64 -device help 2>/dev/null | grep -q 'ramfb' || die "QEMU lacks ramfb support; update the package"
  [[ -f /usr/share/AAVMF/AAVMF_CODE.fd ]] || die "AArch64 UEFI firmware missing: /usr/share/AAVMF/AAVMF_CODE.fd"
  [[ -f /usr/share/AAVMF/AAVMF_VARS.fd ]] || die "UEFI vars missing: /usr/share/AAVMF/AAVMF_VARS.fd"

  mkdir -p "$HAKIOS_HOME" "$HAKIOS_HOME/downloads" "$HAKIOS_HOME/logs"

  if [[ ! -d "$HAKIOS_REPO_DIR/.git" ]]; then
    git clone --depth 1 "$REPO_URL" "$HAKIOS_REPO_DIR"
  else
    echo "Using existing checkout at $HAKIOS_REPO_DIR"
  fi

  local repo="$HAKIOS_REPO_DIR"
  local ipsw
  if [[ -n "${HAKIOS_IPSW:-}" ]]; then
    [[ -f "$HAKIOS_IPSW" ]] || die "HAKIOS_IPSW file not found: $HAKIOS_IPSW"
    ipsw="$(readlink -f "$HAKIOS_IPSW")"
  else
    ipsw="$HAKIOS_HOME/downloads/$IPSW_NAME"
    if [[ ! -f "$ipsw" ]]; then
      echo "Downloading the iPhone X iOS 16.5 IPSW from Apple's CDN (~6.2 GB)."
      curl -fL --retry 5 --retry-delay 3 --connect-timeout 30 "$IPSW_URL" -o "$ipsw.part"
      mv "$ipsw.part" "$ipsw"
    fi
  fi

  [[ -s "$ipsw" ]] || die "IPSW is empty or missing: $ipsw"
  [[ "$(stat -c '%s' "$ipsw")" == "$IPSW_BYTES" ]] || die "IPSW size mismatch: expected $IPSW_BYTES bytes, got $(stat -c '%s' "$ipsw")"

  echo "Preparing HakiOS guest artifacts from the IPSW..."
  (cd "$repo" && sysimage/unpack.sh "$ipsw")
  (cd "$repo" && PREBUILT=1 REST=1 userland/build.sh)
  (cd "$repo" && xnuloader/mkidentity.sh "$ipsw" && xnuloader/build.sh)

  [[ -s "$repo/userland/system.apfs" && -s "$repo/userland/root.apfs" && -s "$repo/xnuloader/loader.efi" ]] || die "guest image build did not produce all required files"

  cat > "$HAKIOS_HOME/config.env" <<EOF
HAKIOS_REPO_DIR='$repo'
HAKIOS_QEMU_RAM_GB='$QEMU_RAM_GB'
HAKIOS_QEMU_SECONDS='$QEMU_SECONDS'
EOF

  install -m 0755 /usr/local/bin/hakios-qemu "$0" 2>/dev/null || true
  echo "Install complete."
  echo "Guest images: $repo/userland/system.apfs and $repo/userland/root.apfs"
  echo "VNC: 127.0.0.1:5900 inside the container"
}

load_config() {
  [[ -f "$HAKIOS_HOME/config.env" ]] || die "not installed; run 'hakios-qemu install' first"
  # shellcheck disable=SC1090
  source "$HAKIOS_HOME/config.env"
  [[ -d "$HAKIOS_REPO_DIR" ]] || die "HakiOS repo dir missing: $HAKIOS_REPO_DIR"
}

start_vm() {
  need_root
  load_config

  if [[ -f "$QEMU_PIDFILE" ]]; then
    local pid
    pid="$(cat "$QEMU_PIDFILE" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      echo "HakiOS QEMU is already running (PID $pid)"
      return
    fi
    rm -f "$QEMU_PIDFILE"
  fi

  [[ -s "$HAKIOS_REPO_DIR/userland/system.apfs" && -s "$HAKIOS_REPO_DIR/userland/root.apfs" ]] || die "guest images are missing; run 'hakios-qemu install' again"

  echo "Starting HakiOS QEMU..."
  mkdir -p "$(dirname "$QEMU_LOG")"
  nohup env QEMU_INSTANCE=0 QEMU_RAM_GB="$QEMU_RAM_GB" \
    "$HAKIOS_REPO_DIR/qemu/run-darwin.sh" "$QEMU_SECONDS" -display "vnc=127.0.0.1:0" \
    >>"$QEMU_LOG" 2>&1 </dev/null &
  local pid=$!
  printf '%s\n' "$pid" > "$QEMU_PIDFILE"

  sleep 2
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$QEMU_PIDFILE"
    tail -n 40 "$QEMU_LOG" >&2 || true
    die "QEMU did not remain running; see $QEMU_LOG"
  fi

  echo "Started successfully (PID $pid). VNC is on 127.0.0.1:5900."
}

stop_vm() {
  need_root
  load_config

  if [[ ! -f "$QEMU_PIDFILE" ]]; then
    echo "HakiOS QEMU is not running."
    return
  fi

  local pid
  pid="$(cat "$QEMU_PIDFILE" 2>/dev/null || true)"
  if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$QEMU_PIDFILE"
    echo "HakiOS QEMU is not running."
    return
  fi

  echo "Requesting shutdown..."
  QEMU_INSTANCE=0 "$HAKIOS_REPO_DIR/qemu/stop.sh" || true
  sleep 2

  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi

  rm -f "$QEMU_PIDFILE"
  echo "HakiOS QEMU stopped."
}

status_vm() {
  local pid
  pid="$(cat "$QEMU_PIDFILE" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    echo "HakiOS QEMU is running (PID $pid)."
    echo "Log: $QEMU_LOG"
    return 0
  fi
  rm -f "$QEMU_PIDFILE"
  echo "HakiOS QEMU is stopped."
  return 1
}

case "${1:-help}" in
  install) install_runtime ;;
  start) start_vm ;;
  stop) stop_vm ;;
  status) status_vm ;;
  help|-h|--help) usage ;;
  *) usage >&2; die "unknown command: $1" ;;
esac
