#!/usr/bin/env bash
# Snapshots of the target user's configs, plus a manifest of what this run installed.
set -euo pipefail
_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_lib}/common.sh"
# shellcheck source=platform.sh
source "${_lib}/platform.sh"

create_snapshot() {
  local id
  id="$(timestamp)"
  CURRENT_SNAPSHOT="${SNAPSHOTS_DIR}/${id}"
  mkdir -p "${CURRENT_SNAPSHOT}/files"

  cat >"${CURRENT_SNAPSHOT}/meta.json" <<EOF
{
  "id": "${id}",
  "created_at": "$(date -Iseconds)",
  "hostname": "$(hostname)",
  "user": "${TARGET_USER}",
  "home": "${TARGET_HOME}",
  "pm": "${PM}",
  "os": "${OS_PRETTY}",
  "ops_root": "${OPS_ROOT}",
  "shell_before": "$(getent passwd "$TARGET_USER" | cut -d: -f7)"
}
EOF
  getent passwd "$TARGET_USER" | cut -d: -f7 >"${CURRENT_SNAPSHOT}/shell_before.txt"

  : >"${CURRENT_SNAPSHOT}/tracked_existed.txt"
  local path rel dest
  for path in "${TRACKED_PATHS[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then
      printf '%s\n' "$path" >>"${CURRENT_SNAPSHOT}/tracked_existed.txt"
      rel="${path#"${TARGET_HOME}"/}"
      dest="${CURRENT_SNAPSHOT}/files/${rel}"
      mkdir -p "$(dirname "$dest")"
      cp -a "$path" "$dest"
    fi
  done

  : >"${CURRENT_SNAPSHOT}/installed.tsv"
  printf '%s\n' "$id" >"${OPS_DATA}/last-snapshot"
  ln -sfn "$CURRENT_SNAPSHOT" "${OPS_DATA}/latest"
  own "$OPS_DATA"
  ok "Snapshot creado: ${id}"
  export CURRENT_SNAPSHOT
}

list_snapshots() {
  if [[ ! -d "$SNAPSHOTS_DIR" ]] || [[ -z "$(ls -A "$SNAPSHOTS_DIR" 2>/dev/null || true)" ]]; then
    warn "No hay snapshots en ${SNAPSHOTS_DIR}"
    return 0
  fi
  local d id
  for d in "$SNAPSHOTS_DIR"/*/; do
    [[ -d "$d" ]] || continue
    id="$(basename "$d")"
    if [[ -f "$d/meta.json" ]]; then
      printf '%s  %s\n' "$id" "$(grep created_at "$d/meta.json" | head -1 | tr -d ' ",')"
    else
      printf '%s\n' "$id"
    fi
  done
}

resolve_snapshot() {
  local want="${1:-}"
  if [[ -z "$want" ]]; then
    [[ -f "${OPS_DATA}/last-snapshot" ]] || die "No hay snapshot al cual hacer rollback"
    want="$(cat "${OPS_DATA}/last-snapshot")"
  fi
  local path="${SNAPSHOTS_DIR}/${want}"
  [[ -d "$path" ]] || die "Snapshot no encontrado: ${want} (en ${SNAPSHOTS_DIR})"
  printf '%s\n' "$path"
}

restore_snapshot_files() {
  local snap="$1"
  local path rel dest

  for path in "${TRACKED_PATHS[@]}"; do
    if ! grep -qxF "$path" "${snap}/tracked_existed.txt" 2>/dev/null; then
      if [[ -e "$path" || -L "$path" ]]; then
        log "Quitando overlay nuevo: $path"
        rm -rf "$path"
      fi
    fi
  done

  for path in "${TRACKED_PATHS[@]}"; do
    rel="${path#"${TARGET_HOME}"/}"
    dest="${snap}/files/${rel}"
    if [[ -e "$dest" || -L "$dest" ]]; then
      mkdir -p "$(dirname "$path")"
      rm -rf "$path"
      cp -a "$dest" "$path"
      own "$path"
      ok "Restaurado: $path"
    fi
  done
}

remove_recorded() {
  local kind="$1" name="$2" detail="${3:-}"
  case "$kind" in
    apt|pacman)
      log "Quitando paquete (${kind}): ${name}"
      PM="$kind"
      pm_remove "$name" || warn "No se pudo quitar ${name}"
      ;;
    bin|link)
      if [[ -n "$detail" && -e "$detail" ]]; then
        rm -f "$detail"
        ok "Eliminado: ${detail}"
      elif [[ -e "${PREFIX_BIN}/${name}" ]]; then
        rm -f "${PREFIX_BIN}/${name}"
        ok "Eliminado: ${PREFIX_BIN}/${name}"
      else
        warn "No está ${name} (${detail})"
      fi
      ;;
    cargo)
      if have_cmd cargo; then
        log "cargo uninstall ${name}"
        cargo uninstall "$name" 2>/dev/null || warn "cargo uninstall ${name} falló"
      fi
      ;;
    *)
      warn "Tipo desconocido en manifiesto: ${kind} ${name}"
      ;;
  esac
}

rollback_packages() {
  local snap="$1"
  local tsv="${snap}/installed.tsv"
  [[ -f "$tsv" ]] || { warn "Sin manifiesto de paquetes"; return 0; }
  local kind name detail
  tac "$tsv" | while IFS=$'\t' read -r kind name detail; do
    [[ -n "${kind:-}" ]] || continue
    remove_recorded "$kind" "$name" "$detail"
  done
}

rollback_shell() {
  local snap="$1" before now
  before="$(cat "${snap}/shell_before.txt" 2>/dev/null || true)"
  [[ -n "$before" ]] || return 0
  now="$(getent passwd "$TARGET_USER" | cut -d: -f7)"
  if [[ "$now" != "$before" ]]; then
    log "Restaurando shell de ${TARGET_USER}: ${before}"
    chsh -s "$before" "$TARGET_USER" || warn "chsh falló. Manual: chsh -s ${before} ${TARGET_USER}"
  fi
}
