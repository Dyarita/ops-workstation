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

declare -gA FAIL_MSG=()

BASE_APT=(ca-certificates curl tar unzip xz-utils git jq)
BASE_PACMAN=(ca-certificates curl tar unzip xz git jq)

record_install() {
  local kind="$1" name="$2" detail="${3:-}"
  local snap="${CURRENT_SNAPSHOT:-}"
  [[ -n "$snap" ]] || return 0
  printf '%s\t%s\t%s\n' "$kind" "$name" "$detail" >>"${snap}/installed.tsv"
}

clear_failures() {
  mkdir -p "$(dirname "$FAILURES_FILE")"
  : >"$FAILURES_FILE"
  own "$FAILURES_FILE" 2>/dev/null || true
}

note_failure() {
  local tool="$1" msg="$2" tmp
  FAIL_MSG["$tool"]="$msg"
  warn "${tool}: ${msg}"
  [[ -n "${FAILURES_FILE:-}" ]] || return 0
  mkdir -p "$(dirname "$FAILURES_FILE")"
  tmp="$(mktemp)"
  if [[ -f "$FAILURES_FILE" ]]; then
    awk -F '\t' -v t="$tool" '$1 != t' "$FAILURES_FILE" >"$tmp"
  fi
  printf '%s\t%s\n' "$tool" "$msg" >>"$tmp"
  mv "$tmp" "$FAILURES_FILE"
  own "$FAILURES_FILE" 2>/dev/null || true
}

failure_count() {
  if [[ ! -s "${FAILURES_FILE:-}" ]]; then
    printf '0\n'
    return 0
  fi
  awk 'NF { n++ } END { print n + 0 }' "$FAILURES_FILE"
}

print_failure_report() {
  local n
  n="$(failure_count)"
  if [[ "$n" == "0" ]]; then
    ok "Todo el stack quedó instalado"
    return 0
  fi
  printf '\nPendientes: %s. El resto de la instalación siguió.\n' "$n"
  local tool msg
  while IFS=$'\t' read -r tool msg; do
    [[ -n "${tool:-}" ]] || continue
    printf '  %-12s %s\n' "$tool" "$msg"
  done <"$FAILURES_FILE"
  cat <<EOF

Reintento (vuelve a consultar los repos y los releases upstream):
  sudo ${OPS_ROOT}/install --repair
  ops repair
EOF
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
  local errf
  for pkg in "${fresh[@]}"; do
    errf="$(mktemp)"
    if pm_install "$pkg" >"$errf" 2>&1; then
      record_install "$PM" "$pkg" ""
    else
      note_failure "$pkg" "$(tr '\n' ' ' <"$errf" | tail -c 300)"
    fi
    rm -f "$errf"
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
  local tool="$1" errf status msg
  errf="$(mktemp)"
  set +e
  upstream_install "$tool" 2>"$errf"
  status=$?
  set -e
  hash -r || true
  if [[ "$status" -eq 0 ]] && tool_ready "$tool"; then
    rm -f "$errf"
    return 0
  fi
  if [[ -s "$errf" ]]; then
    cat "$errf" >&2
    msg="$(tr '\n' ' ' <"$errf" | sed 's/[[:space:]]\+/ /g' | tail -c 300)"
  else
    msg="el upstream no dejó el binario en PATH"
  fi
  rm -f "$errf"
  note_failure "$tool" "$msg"
  return 0
}

rewrite_open_failures() {
  local key msg tmp
  tmp="$(mktemp)"
  for key in "${!FAIL_MSG[@]}"; do
    local drop=0
    local tool
    for tool in "${OPS_TOOLS[@]}"; do
      if [[ "$tool" == "$key" ]] && tool_ready "$tool"; then
        drop=1
        break
      fi
    done
    [[ "$drop" -eq 1 ]] && continue
    msg="${FAIL_MSG[$key]}"
    printf '%s\t%s\n' "$key" "$msg" >>"$tmp"
  done
  mkdir -p "$(dirname "$FAILURES_FILE")"
  mv "$tmp" "$FAILURES_FILE"
  own "$FAILURES_FILE" 2>/dev/null || true
}

install_all_tools() {
  local tool pkg errf
  declare -gA FAIL_MSG=()
  clear_failures

  if ! pm_refresh; then
    note_failure "gestor" "no se pudieron actualizar los índices de ${PM}; sigo con la caché local"
  fi
  ensure_base

  for tool in "${OPS_TOOLS[@]}"; do
    if tool_ready "$tool"; then
      ok "${tool} ya está en PATH"
      continue
    fi
    if pkg="$(first_available_pkg "$tool")"; then
      if pm_installed "$pkg"; then
        ok "${pkg} ya instalado"
      else
        errf="$(mktemp)"
        if pm_install "$pkg" >"$errf" 2>&1; then
          record_install "$PM" "$pkg" ""
          ok "${tool} vía ${PM} (${pkg})"
        else
          note_failure "$tool" "paquete ${pkg}: $(tr '\n' ' ' <"$errf" | tail -c 240)"
          cat "$errf" >&2 || true
        fi
        rm -f "$errf"
      fi
    fi
    hash -r || true
    if tool_ready "$tool"; then
      unset "FAIL_MSG[$tool]"
      continue
    fi
    install_one_upstream "$tool"
    if tool_ready "$tool"; then
      unset "FAIL_MSG[$tool]"
    elif [[ -z "${FAIL_MSG[$tool]:-}" ]]; then
      note_failure "$tool" "sigue ausente"
    fi
  done

  canonicalize_bins
  rewrite_open_failures
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
