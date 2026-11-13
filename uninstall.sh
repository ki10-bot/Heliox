#!/bin/bash
set -euo pipefail

BUNDLE_ID="net.imput.helium"
HELIUM_REPO="imputnet/helium-macos"
SUPPORT="$HOME/Library/Application Support/Heliox"
BACKUP="$SUPPORT/Backup/Helium.app"
RECEIPT="$SUPPORT/receipt"

app=""
assume_yes=false
launch=true
workdir=""
mountpoint=""

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Heliox uninstaller

Usage: uninstall.sh [options]

  --app PATH     Helium.app that was modified (read from the installation by default)
  --no-launch    Do not open Helium after uninstalling
  --yes          Do not ask for confirmation
  --help         Show this help
USAGE
}

cleanup() {
  if [ -n "$mountpoint" ] && [ -d "$mountpoint" ]; then
    hdiutil detach "$mountpoint" -quiet -force >/dev/null 2>&1 || true
  fi
  if [ -n "$workdir" ] && [ -d "$workdir" ]; then
    rm -rf "$workdir"
  fi
}

confirm() {
  local answer=""
  if [ "$assume_yes" = true ]; then
    return 0
  fi
  printf '%s [y/N] ' "$1"
  if [ -t 0 ]; then
    read -r answer || true
  elif [ -r /dev/tty ]; then
    { read -r answer < /dev/tty; } 2>/dev/null || true
  fi
  case "$answer" in
    y|Y|yes|Yes|j|J|ja|Ja) return 0 ;;
    *) return 1 ;;
  esac
}

privileged() {
  if [ -w "$(dirname "$app")" ] && { [ ! -e "$app" ] || [ -w "$app" ]; }; then
    "$@"
  else
    sudo "$@"
  fi
}

bundle_id() {
  /usr/bin/defaults read "$1/Contents/Info" CFBundleIdentifier 2>/dev/null || true
}

receipt_value() {
  if [ -f "$RECEIPT" ]; then
    sed -n "s/^$1=//p" "$RECEIPT" | head -n 1
  fi
}

is_running() {
  pgrep -f "$app/Contents/MacOS/" >/dev/null 2>&1
}

quit_app() {
  local waited=0
  if ! is_running; then
    return
  fi
  confirm "Helium is running and has to be closed. Close it now?" || die "Uninstallation cancelled."
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  while is_running; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge 30 ]; then
      die "Helium did not close. Close it manually and run the uninstaller again."
    fi
  done
}

download_helium() {
  local arch url dmg source
  case "$(uname -m)" in
    arm64) arch=arm64 ;;
    *) arch=x86_64 ;;
  esac
  url="$(curl -fsSL "https://api.github.com/repos/$HELIUM_REPO/releases/latest" |
    sed -n 's/.*"browser_download_url": *"\([^"]*_'"$arch"'-macos\.dmg\)".*/\1/p' | head -n 1)"
  [ -n "$url" ] || return 1

  dmg="$workdir/helium.dmg"
  mountpoint="$workdir/mount"
  mkdir -p "$mountpoint"
  say "Downloading the original Helium"
  curl -fL --progress-bar -o "$dmg" "$url" || return 1
  hdiutil attach "$dmg" -nobrowse -readonly -noautoopen -quiet -mountpoint "$mountpoint" || return 1
  source="$mountpoint/Helium.app"
  [ -d "$source" ] || return 1
  privileged rm -rf "$app"
  privileged ditto "$source" "$app" || return 1
  privileged xattr -dr com.apple.quarantine "$app" >/dev/null 2>&1 || true
  hdiutil detach "$mountpoint" -quiet >/dev/null 2>&1 || true
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app) [ $# -ge 2 ] || die "--app needs a path"; app="$2"; shift 2 ;;
    --no-launch) launch=false; shift ;;
    --yes|-y) assume_yes=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = Darwin ] || die "Heliox is only available for macOS."

if [ -z "$app" ]; then
  app="$(receipt_value app)"
fi
app="${app%/}"

if [ -z "$app" ]; then
  die "Heliox is not installed."
fi

if [ -e "$app" ] && [ "$(bundle_id "$app")" != "$BUNDLE_ID" ]; then
  die "$app is not Helium."
fi

trap cleanup EXIT
workdir="$(mktemp -d "${TMPDIR:-/tmp}/heliox.XXXXXX")"

say "Heliox $(receipt_value version) is installed at $app"
confirm "Remove Heliox and restore the original Helium?" || die "Uninstallation cancelled."

quit_app

if [ -d "$BACKUP" ]; then
  say "Restoring the original Helium"
  privileged rm -rf "$app"
  privileged mv "$BACKUP" "$app"
elif ! download_helium; then
  die "The original Helium could not be downloaded. Heliox was left in place. Get Helium from https://helium.computer and run the uninstaller again."
fi

rm -rf "$SUPPORT"

say "Heliox was removed"
printf '    Your profile, tabs and settings were not touched.\n'

if [ "$launch" = true ]; then
  open "$app" || true
fi
