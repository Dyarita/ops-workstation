#!/usr/bin/env bash
# Identity, paths, and logging. No distro-specific locations.
# shellcheck disable=SC2034
set -euo pipefail

OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Falta comando requerido: $1"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

timestamp() { date +%Y%m%d-%H%M%S; }

own() {
  [[ "$(id -u)" -eq 0 ]] || return 0
  [[ -n "${TARGET_USER:-}" && "$TARGET_USER" != "root" ]] || return 0
  chown -R "${TARGET_USER}:${TARGET_GROUP}" "$@"
}

resolve_identity() {
  if [[ -n "${OPS_USER:-}" ]]; then
    TARGET_USER="$OPS_USER"
  elif [[ "$(id -u)" -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    TARGET_USER="$SUDO_USER"
  else
    TARGET_USER="$(id -un)"
  fi

  local entry
  entry="$(getent passwd "$TARGET_USER")" || die "Usuario inexistente: $TARGET_USER"
  TARGET_HOME="$(printf '%s\n' "$entry" | cut -d: -f6)"
  TARGET_GROUP="$(id -gn "$TARGET_USER")"
  [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Home inválido para $TARGET_USER"

  # XDG defaults. Login profiles on these distros rarely relocate them;
  # if the directory is a symlink, later writes follow it.
  CONFIG_HOME="${OPS_CONFIG_HOME:-$TARGET_HOME/.config}"
  DATA_HOME="${OPS_DATA_HOME:-$TARGET_HOME/.local/share}"
  STATE_HOME="${OPS_STATE_HOME:-$TARGET_HOME/.local/state}"

  OPS_DATA="${DATA_HOME}/ops-workstation"
  OPS_STATE="${STATE_HOME}/ops-workstation"
  SNAPSHOTS_DIR="${OPS_DATA}/snapshots"
  MANIFEST_CURRENT="${OPS_DATA}/current-manifest.json"

  TRACKED_PATHS=(
    "${CONFIG_HOME}/fish"
    "${CONFIG_HOME}/starship.toml"
    "${CONFIG_HOME}/tmux"
    "${CONFIG_HOME}/yazi"
    "${CONFIG_HOME}/atuin"
    "${CONFIG_HOME}/mise"
    "${CONFIG_HOME}/direnv"
    "${CONFIG_HOME}/ripgreprc"
    "${TARGET_HOME}/.gitconfig"
    "${TARGET_HOME}/.tmux.conf"
  )
}

default_login_path() {
  local path=""
  if [[ -f /etc/environment ]]; then
    path="$(sed -n 's/^PATH=//p' /etc/environment | head -1 | tr -d "\"'")"
  fi
  if [[ -z "$path" ]]; then
    if [[ "$(id -un)" == "$TARGET_USER" ]]; then
      # shellcheck disable=SC2016
      path="$(/bin/sh -lc 'printf %s "$PATH"' 2>/dev/null || true)"
    elif have_cmd runuser; then
      # $PATH must expand in the target user's shell, not here.
      # shellcheck disable=SC2016
      path="$(runuser -u "$TARGET_USER" -- /bin/sh -lc 'printf %s "$PATH"' 2>/dev/null || true)"
    fi
  fi
  if [[ -z "$path" ]]; then
    path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  fi
  printf '%s\n' "$path"
}

detect_prefix() {
  # FHS location for admin-installed binaries. Not a distro path:
  # Debian, Ubuntu, Arch and Omarchy all ship it on the login PATH.
  PREFIX_BIN="/usr/local/bin"
  local path
  path="$(default_login_path)"
  NEED_USER_PATH=0
  if [[ ":${path}:" != *":${PREFIX_BIN}:"* ]]; then
    NEED_USER_PATH=1
  fi
}

detect_machine() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64)
      MACH="x86_64"
      GOARCH="amd64"
      LINUX_ARCH="x86_64"
      ;;
    aarch64|arm64)
      MACH="aarch64"
      GOARCH="arm64"
      LINUX_ARCH="arm64"
      ;;
    *)
      die "Arquitectura no soportada: $m"
      ;;
  esac
}

ops_init() {
  resolve_identity
  detect_prefix
  detect_machine
  export PATH="${PREFIX_BIN}:${PATH}"
}
