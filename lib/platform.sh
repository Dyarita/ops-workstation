#!/usr/bin/env bash
# Package manager discovery. Branches on the tool that exists, not on /etc/os-release.
# shellcheck disable=SC2034
set -euo pipefail
_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_lib}/common.sh"

detect_pm() {
  if have_cmd pacman; then
    PM="pacman"
  elif have_cmd apt-get; then
    PM="apt"
  else
    die "No hay pacman ni apt-get. Hace falta el gestor de paquetes de la distro."
  fi

  OS_ID="unknown"
  OS_VERSION=""
  OS_PRETTY="unknown"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
  fi
}

pm_refresh() {
  log "Actualizando índices de paquetes ($PM)"
  case "$PM" in
    apt) apt-get update -y || return 1 ;;
    pacman) pacman -Sy --noconfirm || return 1 ;;
    *) die "Gestor no soportado: $PM" ;;
  esac
}

pm_installed() {
  local pkg="$1"
  case "$PM" in
    apt) dpkg -s "$pkg" >/dev/null 2>&1 ;;
    pacman) pacman -Q "$pkg" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

pm_available() {
  local pkg="$1" cand
  case "$PM" in
    apt)
      cand="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
      [[ -n "$cand" && "$cand" != "(none)" ]]
      ;;
    pacman)
      pacman -Si "$pkg" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

pm_install() {
  local -a pkgs=("$@")
  ((${#pkgs[@]})) || return 0
  log "Instalando vía $PM: ${pkgs[*]}"
  case "$PM" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" || return 1
      ;;
    pacman)
      pacman -S --needed --noconfirm "${pkgs[@]}" || return 1
      ;;
    *) die "Gestor no soportado: $PM" ;;
  esac
}

pm_remove() {
  local pkg="$1"
  case "$PM" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get remove -y "$pkg" ;;
    pacman) pacman -R --noconfirm "$pkg" ;;
    *) warn "No sé desinstalar $pkg con $PM"; return 1 ;;
  esac
}

# Package names are not the binary names. Probe candidates that exist
# in THIS distro's repositories; the first hit wins.
tool_pkg_candidates() {
  local tool="$1"
  case "${PM}:${tool}" in
    apt:rg) printf '%s\n' ripgrep ;;
    apt:fd) printf '%s\n' fd-find ;;
    apt:delta) printf '%s\n' git-delta ;;
    apt:tldr) printf '%s\n' tealdeer ;;
    apt:yq) return 0 ;;
    pacman:rg) printf '%s\n' ripgrep ;;
    pacman:delta) printf '%s\n' git-delta ;;
    pacman:tldr) printf '%s\n' tealdeer ;;
    pacman:yq) printf '%s\n' go-yq ;;
    *) printf '%s\n' "$tool" ;;
  esac
}

first_available_pkg() {
  local tool="$1" cand
  while IFS= read -r cand; do
    [[ -n "$cand" ]] || continue
    if pm_available "$cand"; then
      printf '%s\n' "$cand"
      return 0
    fi
  done < <(tool_pkg_candidates "$tool")
  return 1
}

yq_is_mikefarah() {
  local bin
  bin="$(command -v yq 2>/dev/null || true)"
  [[ -n "$bin" ]] || return 1
  "$bin" --version 2>&1 | grep -Eiq 'mikefarah|github.com/mikefarah'
}

tool_ready() {
  local tool="$1"
  case "$tool" in
    yq) yq_is_mikefarah ;;
    rg) have_cmd rg ;;
    fd) have_cmd fd || have_cmd fdfind ;;
    bat) have_cmd bat || have_cmd batcat ;;
    delta) have_cmd delta ;;
    tldr) have_cmd tldr ;;
    ast-grep) have_cmd ast-grep || have_cmd sg ;;
    *) have_cmd "$tool" ;;
  esac
}

tool_which() {
  local tool="$1" cmd
  case "$tool" in
    fd) cmd="fd" ;;
    bat) cmd="bat" ;;
    ast-grep) cmd="sg" ;;
    *) cmd="$tool" ;;
  esac
  if have_cmd "$cmd"; then
    command -v "$cmd"
    return 0
  fi
  case "$tool" in
    fd) have_cmd fdfind && command -v fdfind && return 0 ;;
    bat) have_cmd batcat && command -v batcat && return 0 ;;
    ast-grep) have_cmd ast-grep && command -v ast-grep && return 0 ;;
  esac
  return 1
}
