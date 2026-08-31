#!/bin/sh
# Install codexbar-to-greptimedb from a GitHub Release.
# Usage: curl -fsSL https://raw.githubusercontent.com/smartcrabai/codexbar-to-greptimedb/main/install.sh | sh

set -eu

REPOSITORY="${CODEXBAR_TO_GREPTIMEDB_REPOSITORY:-smartcrabai/codexbar-to-greptimedb}"
BINARY_NAME="codexbar-to-greptimedb"
APP_NAME="CodexBarToGreptimeDB.app"
INSTALL_DIR="${CODEXBAR_TO_GREPTIMEDB_INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${CODEXBAR_TO_GREPTIMEDB_VERSION:-latest}"

usage() {
  cat <<'EOF'
Usage: install.sh [--version VERSION] [--install-dir DIRECTORY]

Environment variables:
  CODEXBAR_TO_GREPTIMEDB_VERSION       Release version, such as 0.1.0 or v0.1.0.
  CODEXBAR_TO_GREPTIMEDB_INSTALL_DIR   Destination directory. Default: $HOME/.local/bin.
  CODEXBAR_TO_GREPTIMEDB_REPOSITORY    GitHub owner/repository. Default: smartcrabai/codexbar-to-greptimedb.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version|--install-dir)
      if [ "$#" -lt 2 ]; then
        printf '%s\n' "error: option requires a value: $1" >&2
        exit 2
      fi
      if [ "$1" = "--version" ]; then
        VERSION="$2"
      else
        INSTALL_DIR="$2"
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf '%s\n' "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "error: required command not found: $1" >&2
    exit 1
  fi
}

require_command curl
require_command tar
require_command awk
require_command install
require_command mktemp

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    printf '%s\n' "error: required checksum command not found: sha256sum or shasum" >&2
    exit 1
  fi
}

case "$(uname -s)" in
  Darwin) platform="macos" ;;
  Linux) platform="linux" ;;
  *)
    printf '%s\n' "error: unsupported operating system: $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64|aarch64) architecture="arm64" ;;
  x86_64|amd64) architecture="x86_64" ;;
  *)
    printf '%s\n' "error: unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

case "$platform-$architecture" in
  macos-arm64|macos-x86_64|linux-x86_64) ;;
  linux-arm64)
    printf '%s\n' "error: Linux arm64 release archives are not published" >&2
    exit 1
    ;;
esac

if [ "$platform" = "macos" ]; then
  require_command ditto
fi

if [ "$VERSION" = "latest" ]; then
  VERSION="$(
    curl --fail --location --retry 3 --silent --show-error \
      "https://api.github.com/repos/$REPOSITORY/releases/latest" \
      | awk -F '"' '/"tag_name"/ { print $4; exit }'
  )"
  if [ -z "$VERSION" ]; then
    printf '%s\n' "error: could not determine the latest release version" >&2
    exit 1
  fi
fi

case "$VERSION" in
  v*) release_tag="$VERSION" ;;
  *) release_tag="v$VERSION" ;;
esac

version_without_prefix="${release_tag#v}"
asset_name="$BINARY_NAME-$version_without_prefix-$platform-$architecture.tar.gz"
release_url="https://github.com/$REPOSITORY/releases/download/$release_tag"
asset_url="$release_url/$asset_name"
checksum_url="$asset_url.sha256"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/$BINARY_NAME.XXXXXX")"
temporary_binary=""
temporary_app=""
cleanup() {
  if [ -n "$temporary_binary" ]; then
    rm -f "$temporary_binary"
  fi
  if [ -n "$temporary_app" ]; then
    rm -rf "$temporary_app"
  fi
  rm -rf "$work_dir"
}
trap cleanup 0 HUP INT TERM

printf '%s\n' "Downloading $asset_name from $REPOSITORY $release_tag"
curl --fail --location --retry 3 --silent --show-error \
  --output "$work_dir/$asset_name" \
  "$asset_url"
curl --fail --location --retry 3 --silent --show-error \
  --output "$work_dir/$asset_name.sha256" \
  "$checksum_url"

expected_checksum="$(awk 'NR == 1 { print $1 }' "$work_dir/$asset_name.sha256")"
actual_checksum="$(sha256_file "$work_dir/$asset_name")"
if [ -z "$expected_checksum" ] || [ "$expected_checksum" != "$actual_checksum" ]; then
  printf '%s\n' "error: SHA-256 verification failed for $asset_name" >&2
  exit 1
fi

tar -xzf "$work_dir/$asset_name" -C "$work_dir"
mkdir -p "$INSTALL_DIR"

archive_root="$work_dir"
if [ ! -e "$archive_root/$APP_NAME" ] && [ -d "$archive_root/$BINARY_NAME" ]; then
  archive_root="$archive_root/$BINARY_NAME"
fi

if [ "$platform" = "macos" ] && [ -d "$archive_root/$APP_NAME" ]; then
  app_source="$archive_root/$APP_NAME"
  temporary_app="$INSTALL_DIR/.$APP_NAME.tmp.$$"
  rm -rf "$temporary_app"
  ditto "$app_source" "$temporary_app"
  rm -rf "$INSTALL_DIR/$APP_NAME"
  mv "$temporary_app" "$INSTALL_DIR/$APP_NAME"
  temporary_app=""

  temporary_binary="$INSTALL_DIR/.$BINARY_NAME.tmp.$$"
  rm -f "$temporary_binary"
  ln -s "$APP_NAME/Contents/MacOS/$BINARY_NAME" "$temporary_binary"
  mv -f "$temporary_binary" "$INSTALL_DIR/$BINARY_NAME"
  temporary_binary=""
elif [ -f "$archive_root/$BINARY_NAME" ]; then
  temporary_binary="$INSTALL_DIR/.$BINARY_NAME.tmp.$$"
  install -m 755 "$archive_root/$BINARY_NAME" "$temporary_binary"
  mv -f "$temporary_binary" "$INSTALL_DIR/$BINARY_NAME"
  temporary_binary=""
else
  printf '%s\n' "error: release archive does not contain $APP_NAME or $BINARY_NAME" >&2
  exit 1
fi

printf '%s\n' "Installed $BINARY_NAME $release_tag to $INSTALL_DIR/$BINARY_NAME"
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) printf '%s\n' "Add $INSTALL_DIR to PATH to run $BINARY_NAME directly." ;;
esac
