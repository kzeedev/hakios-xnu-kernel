#!/usr/bin/env bash
set -Eeuo pipefail

# Install QEMU + firmware + runtime support in a Debian Droidspaces container,
# download the HakiOS open-kernel bundle from this repo, and manage start/stop/status.
#
# Usage:
#   hakios-open-qemu install
#   hakios-open-qemu start
#   hakios-open-qemu stop
#   hakios-open-qemu status
#
# The bundle is a GitHub release artifact from kzeedev/hakios-xnu-kernel.
# If no release exists, the script will fall back to the repo's latest default branch
# and fetch the generated tarball from GitHub Actions artifact URL if one is published.

HOMEDIR="${HAKIOS_HOME:-/opt/hakios-open-qemu}"
BUNDLE_DIR="${HAKIOS_BUNDLE_DIR:-$HOMEDIR/bundle}"
ASSET_URL="${HAKIOS_QEMU_ASSET_URL:-}"
GITHUB_REPO="${HAKIOS_GITHUB_REPO:-kzeedev/hakios-xnu-kernel}"
QEMU_LOG="${HAKIOS_QEMU_LOG:-$HOMEDIR/qemu.log}"
QEMU_PIDFILE="${HAKIOS_QEMU_PIDFILE:-$HOMEDIR/qemu.pid}"

usage() {
  cat <<'EOF'
HakiOS open-kernel QEMU runner for a Droidspaces container

Commands:
  hakios-open-qemu install
      Install QEMU + firmware and fetch the HakiOS QEMU bundle.
  hakios-open-qemu start
      Start the HakiOS QEMU guest.
  hakios-open-qemu stop
      Stop the HakiOS QEMU guest.
  hakios-open-qemu status
      Show QEMU status.
  hakios-open-qemu help
      Show this help.
EOF
}

die() { echo "hakios-open-qemu: $*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "run as root inside the container"; }

ensure_qemu() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    make \
    python3 \
    qemu-system-arm \
    qemu-efi-aarch64 \
    qemu-utils \
    tar \
    xz-utils \
    lz4 \
    file \
    util-linux \
    iproute2 \
    net-tools \
    socat
}

fetch_release_asset() {
  local asset_url="$1"

  if [[ -n "$asset_url" ]]; then
    curl -fsSL "$asset_url" -o "$HOMEDIR/hakios-qemu-bundle.tar.gz"
    return
  fi

  # Prefer the latest GitHub release asset if it exists.
  local release_json
  release_json="$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" 2>/dev/null || true)"
  if [[ -n "$release_json" ]]; then
    local asset_name
    asset_name="$(printf '%s' "$release_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((a["browser_download_url"] for a in d.get("assets", []) if "hakios-qemu" in a["name"] or "qemu-open" in a["name"]), ""))' 2>/dev/null || true)"
    if [[ -n "$asset_name" ]]; then
      curl -fsSL "$asset_name" -o "$HOMEDIR/hakios-qemu-bundle.tar.gz"
      return
    fi
  fi

  # Fallback: GitHub Actions artifact URL pattern if you publish one.
  # The repo owner and workflow name may vary; the URL is usually known only after the artifact is published.
  echo "No release asset available yet; skipping bundle download." >&2
  echo "Set HAKIOS_QEMU_ASSET_URL to a valid tar.gz asset URL." >&2
  exit 1
}

install_runtime() {
  need_root
  ensure_qemu

  mkdir -p "$HOMEDIR"
  mkdir -p "$HOMEDIR/bin"
  mkdir -p "$HOMEDIR/logs"

  if [[ ! -f "$HOMEDIR/hakios-qemu-bundle.tar.gz" ]]; then
    fetch_release_asset
  fi

  rm -rf "$BUNDLE_DIR"
  mkdir -p "$BUNDLE_DIR"
  tar -xzf "$HOMEDIR/hakios-qemu-bundle.tar.gz" -C "$BUNDLE_DIR" --strip-components=1

  # Sanity checks
  [[ -f "$BUNDLE_DIR/qemu/payload.bin" ]] || die "bundle is missing qemu/payload.bin"
  [[ -f "$BUNDLE_DIR/prebuilt/loader.efi" ]] || die "bundle is missing prebuilt/loader.efi"
  [[ -f "$BUNDLE_DIR/userland/hello" ]] || die "bundle is missing userland/hello"

  install -m 0755 "$0" /usr/local/bin/hakios-open-qemu

  echo "Bundle installed at $BUNDLE_DIR"
  echo "VNC: 127.0.0.1:5900 inside the container"
  echo "Use: hakios-open-qemu start"
}

start_qemu() {
  need_root

  [[ -d "$BUNDLE_DIR" ]] || die "bundle not installed; run 'hakios-open-qemu install' first"

  if [[ -f "$QEMU_PIDFILE" ]]; then
    local pid
    pid="$(cat "$QEMU_PIDFILE" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      echo "HakiOS QEMU already running (PID $pid)"
      return
    fi
    rm -f "$QEMU_PIDFILE"
  fi

  echo "Starting HakiOS open-kernel QEMU in the background..."
  nohup env QEMU_SMP=1 QEMU_MEM=6G \
    bash -c 'cd "$1" && qemu/run.sh 600 -display vnc=127.0.0.1:0' _ "$BUNDLE_DIR" \
    >>"$QEMU_LOG" 2>&1 </dev/null &

  local pid=$!
  echo "$pid" > "$QEMU_PIDFILE"

  sleep 2
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$QEMU_PIDFILE"
    echo "QEMU did not remain running; see $QEMU_LOG" >&2
    exit 1
  fi

  echo "Started successfully."
  echo "VNC: 127.0.0.1:5900"
  echo "Log: $QEMU_LOG"
}

stop_qemu() {
  need_root

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

  echo "Stopping HakiOS QEMU..."
  kill "$pid" 2>/dev/null || true
  sleep 2
  rm -f "$QEMU_PIDFILE"
  echo "Stopped."
}

status_qemu() {
  if [[ -f "$QEMU_PIDFILE" ]]; then
    local pid
    pid="$(cat "$QEMU_PIDFILE" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      echo "HakiOS QEMU is running (PID $pid)."
      echo "Log: $QEMU_LOG"
      return 0
    fi
  fi
  rm -f "$QEMU_PIDFILE"
  echo "HakiOS QEMU is stopped."
  return 1
}

case "${1:-help}" in
  install) install_runtime ;;
  start) start_qemu ;;
  stop) stop_qemu ;;
  status) status_qemu ;;
  help|-h|--help) usage ;;
  *) usage >&2; die "unknown command: $1" ;;
esac
