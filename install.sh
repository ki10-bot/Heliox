#!/bin/bash
set -euo pipefail

REPO="ki10-bot/Heliox"
BUNDLE_ID="net.imput.helium"
SUPPORT="$HOME/Library/Application Support/Heliox"
BACKUP="$SUPPORT/Backup/Helium.app"
RECEIPT="$SUPPORT/receipt"

app=""
dmg=""
tag=""
assume_yes=false
launch=true
workdir=""
mountpoint=""

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Heliox installer

Usage: install.sh [options]

  --app PATH     Helium.app to modify (found automatically by default)
  --dmg FILE     Install from a local Heliox disk image instead of downloading
  --tag TAG      Install a specific Heliox release instead of the latest
  --no-launch    Do not open Helium after installing
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

bundle_version() {
  /usr/bin/defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null || true
}

receipt_value() {
  if [ -f "$RECEIPT" ]; then
    sed -n "s/^$1=//p" "$RECEIPT" | head -n 1
  fi
}

find_app() {
  local candidate
  candidate="$(receipt_value app)"
  if [ -n "$candidate" ] && [ -d "$candidate" ]; then
    printf '%s\n' "$candidate"
    return
  fi
  for candidate in "/Applications/Helium.app" "$HOME/Applications/Helium.app"; do
    if [ -d "$candidate" ] && [ "$(bundle_id "$candidate")" = "$BUNDLE_ID" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  candidate="$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | grep -v "$SUPPORT" | head -n 1 || true)"
  if [ -n "$candidate" ] && [ -d "$candidate" ]; then
    printf '%s\n' "$candidate"
    return
  fi
  printf '%s\n' "/Applications/Helium.app"
}

is_running() {
  pgrep -f "$app/Contents/MacOS/" >/dev/null 2>&1
}

quit_app() {
  local waited=0
  if ! is_running; then
    return
  fi
  confirm "Helium is running and has to be closed. Close it now?" || die "Installation cancelled."
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  while is_running; do
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge 30 ]; then
      die "Helium did not close. Close it manually and run the installer again."
    fi
  done
}

resolve_tag() {
  local url
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" || true)"
  case "$url" in
    */releases/tag/*) printf '%s\n' "${url##*/}" ;;
    *) printf '\n' ;;
  esac
}

download() {
  local arch="$1" base
  if [ -z "$tag" ]; then
    tag="$(resolve_tag)"
  fi
  if [ -z "$tag" ]; then
    die "No Heliox release has been published yet. See https://github.com/$REPO/releases"
  fi
  base="https://github.com/$REPO/releases/download/$tag"
  dmg="$workdir/heliox-$arch.dmg"

  say "Downloading Heliox $tag for $arch"
  curl -fL --progress-bar -o "$dmg" "$base/heliox-$arch.dmg" ||
    die "Heliox $tag has no build for $arch. See https://github.com/$REPO/releases"
  curl -fsSL -o "$dmg.sha256" "$base/heliox-$arch.dmg.sha256" ||
    die "The checksum for Heliox $tag could not be downloaded."

  local expected actual
  expected="$(awk '{print $1}' "$dmg.sha256")"
  actual="$(shasum -a 256 "$dmg" | awk '{print $1}')"
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    die "The download is damaged (checksum mismatch). Please try again."
  fi
}

restore_backup() {
  if [ -d "$BACKUP" ] && [ ! -e "$app" ]; then
    warn "Restoring the original Helium"
    privileged mv "$BACKUP" "$app"
  fi
}

install_app() {
  local source
  mountpoint="$workdir/mount"
  mkdir -p "$mountpoint"
  hdiutil attach "$dmg" -nobrowse -readonly -noautoopen -quiet -mountpoint "$mountpoint" || return 1
  source="$mountpoint/Helium.app"
  if [ ! -d "$source" ] || [ "$(bundle_id "$source")" != "$BUNDLE_ID" ]; then
    warn "The disk image does not contain Helium."
    return 1
  fi
  privileged ditto "$source" "$app" || return 1
  privileged xattr -dr com.apple.quarantine "$app" >/dev/null 2>&1 || true
  hdiutil detach "$mountpoint" -quiet >/dev/null 2>&1 || true
}

while [ $# -gt 0 ]; do
  case "$1" in
    --app) [ $# -ge 2 ] || die "--app needs a path"; app="$2"; shift 2 ;;
    --dmg) [ $# -ge 2 ] || die "--dmg needs a file"; dmg="$2"; shift 2 ;;
    --tag) [ $# -ge 2 ] || die "--tag needs a release tag"; tag="$2"; shift 2 ;;
    --no-launch) launch=false; shift ;;
    --yes|-y) assume_yes=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = Darwin ] || die "Heliox is only available for macOS."

case "$(uname -m)" in
  arm64) arch=arm64 ;;
  x86_64) arch=x86_64 ;;
  *) die "Unsupported processor: $(uname -m)" ;;
esac

if [ -z "$app" ]; then
  app="$(find_app)"
fi
app="${app%/}"

if [ -e "$app" ] && [ "$(bundle_id "$app")" != "$BUNDLE_ID" ]; then
  die "$app is not Helium."
fi

if [ -n "$dmg" ] && [ ! -f "$dmg" ]; then
  die "$dmg does not exist."
fi

trap cleanup EXIT
workdir="$(mktemp -d "${TMPDIR:-/tmp}/heliox.XXXXXX")"

already_installed=false
if [ -f "$RECEIPT" ] && [ "$(receipt_value app)" = "$app" ] && [ -d "$app" ]; then
  already_installed=true
fi

if [ -d "$app" ]; then
  if [ "$already_installed" = true ]; then
    say "Heliox $(receipt_value version) is installed at $app and will be updated"
  else
    say "Found Helium $(bundle_version "$app") at $app"
  fi
else
  say "Helium was not found, Heliox will be installed to $app"
fi

confirm "Install Heliox?" || die "Installation cancelled."

if [ -z "$dmg" ]; then
  download "$arch"
else
  tag="${tag:-local}"
fi

quit_app

mkdir -p "$SUPPORT/Backup"
if [ -d "$app" ]; then
  if [ "$already_installed" = true ] && [ -d "$BACKUP" ]; then
    privileged rm -rf "$app"
  else
    say "Backing up the original Helium"
    rm -rf "$BACKUP"
    privileged mv "$app" "$BACKUP"
  fi
fi

say "Installing Heliox"
if ! install_app; then
  privileged rm -rf "$app"
  restore_backup
  die "Heliox could not be installed. Nothing was changed."
fi

{
  printf 'app=%s\n' "$app"
  printf 'version=%s\n' "$tag"
  printf 'installed=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RECEIPT"

say "Heliox is installed"
printf '    Open Settings > Appearance > Surface to choose a material.\n'
printf '    macOS may ask once for your password to unlock the Helium keychain entry.\n'

if [ "$launch" = true ]; then
  open "$app" || true
fi
