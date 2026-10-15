#!/usr/bin/env bash
# Install each tool from the distro when the package exists, otherwise upstream.
set -euo pipefail
_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=platform.sh
source "${_lib}/platform.sh"
# shellcheck source=upstream.sh
source "${_lib}/upstream.sh"

OPS_TOOLS=(
  fish starship zoxide fzf atuin rg fd bat eza btop tmux
  lazygit yazi mise direnv just gum jq yq shellcheck
  dust delta xh ast-grep procs sd tldr hyperfine
)

BASE_APT=(ca-certificates curl tar unzip xz-utils git jq)
BASE_PACMAN=(ca-certificates curl tar unzip xz git jq)

record_install() {
  local kind="$1" name="$2" detail="${3:-}"
  local snap="${CURRENT_SNAPSHOT:-}"
  [[ -n "$snap" ]] || return 0
  printf '%s\t%s\t%s\n' "$kind" "$name" "$detail" >>"${snap}/installed.tsv"
}

unique_lines() {
  awk 'NF && !seen[$0]++'
}

pm_install_new() {
  local -a incoming=("$@")
  local -a fresh=()
  local pkg
  ((${#incoming[@]})) || return 0
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    if pm_installed "$pkg"; then
      ok "$pkg ya instalado"
      continue
    fi
    fresh+=("$pkg")
  done < <(printf '%s\n' "${incoming[@]}" | unique_lines)
  ((${#fresh[@]})) || return 0
  pm_install "${fresh[@]}"
  for pkg in "${fresh[@]}"; do
    record_install "$PM" "$pkg" ""
  done
}

ensure_base() {
  local -a want=()
  case "$PM" in
    apt) want=("${BASE_APT[@]}") ;;
    pacman) want=("${BASE_PACMAN[@]}") ;;
  esac
  local -a inst=()
  local pkg
  for pkg in "${want[@]}"; do
    if pm_available "$pkg"; then
      inst+=("$pkg")
    else
      warn "Paquete base ausente en repos: $pkg"
    fi
  done
  pm_install_new "${inst[@]}"
  have_cmd curl || die "curl no quedó disponible"
  have_cmd tar || die "tar no quedó disponible"
}

link_canonical() {
  local name="$1"
  shift
  have_cmd "$name" && return 0
  local alt target dest
  for alt in "$@"; do
    if have_cmd "$alt"; then
      target="$(command -v "$alt")"
      dest="${PREFIX_BIN}/${name}"
      ln -sfn "$target" "$dest"
      record_install link "$name" "$dest"
      hash -r || true
      ok "Enlace ${name} → ${target}"
      return 0
    fi
  done
  return 1
}

canonicalize_bins() {
  hash -r || true
  link_canonical bat batcat || true
  link_canonical fd fdfind || true
  link_canonical sg ast-grep || true
  link_canonical ast-grep sg || true
  hash -r || true
}

install_one_upstream() {
  local tool="$1"
  upstream_install "$tool"
  tool_ready "$tool" || die "Después del upstream, ${tool} sigue ausente"
}

install_all_tools() {
  local -a pkgs=()
  local tool pkg

  pm_refresh
  ensure_base

  for tool in "${OPS_TOOLS[@]}"; do
    if tool_ready "$tool"; then
      ok "${tool} ya está en PATH"
      continue
    fi
    if pkg="$(first_available_pkg "$tool")"; then
      pkgs+=("$pkg")
    fi
  done

  if ((${#pkgs[@]})); then
    pm_install_new "${pkgs[@]}"
  fi
  hash -r || true

  for tool in "${OPS_TOOLS[@]}"; do
    if tool_ready "$tool"; then
      continue
    fi
    install_one_upstream "$tool"
  done

  canonicalize_bins

  local missing=0
  for tool in "${OPS_TOOLS[@]}"; do
    if ! tool_ready "$tool"; then
      warn "Sigue faltando: ${tool}"
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die "La instalación quedó incompleta"
}

print_plan() {
  local tool pkg where
  cat <<EOF
Sistema:  ${OS_PRETTY}
Gestor:   ${PM}
Usuario:  ${TARGET_USER}
Home:     ${TARGET_HOME}
Config:   ${CONFIG_HOME}
Prefix:   ${PREFIX_BIN}
Arch:     ${MACH}
PATH+:    $([[ "$NEED_USER_PATH" == 1 ]] && echo "hay que sumar ${PREFIX_BIN} al PATH del usuario" || echo "el login PATH ya incluye ${PREFIX_BIN}")

Herramienta   Origen
EOF
  for tool in "${OPS_TOOLS[@]}"; do
    if tool_ready "$tool"; then
      where="presente ($(tool_which "$tool" 2>/dev/null || echo '?'))"
    elif pkg="$(first_available_pkg "$tool")"; then
      where="${PM} → ${pkg}"
    else
      where="upstream release"
    fi
    printf '%-12s  %s\n' "$tool" "$where"
  done
}
