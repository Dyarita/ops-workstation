#!/usr/bin/env bash
# Upstream release binaries for tools the distro does not package.
# Asset selection follows uname -m, not a distro name.
set -euo pipefail
_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_lib}/common.sh"

declare -gA GH_JSON_CACHE=()

github_latest_json() {
  local repo="$1"
  if [[ -n "${GH_JSON_CACHE[$repo]:-}" ]]; then
    printf '%s\n' "${GH_JSON_CACHE[$repo]}"
    return 0
  fi
  local json
  json="$(curl -fsSL --retry 3 --retry-delay 1 \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${repo}/releases/latest")" || die "GitHub API falló para ${repo}"
  if printf '%s' "$json" | grep -q '"API rate limit exceeded"'; then
    die "GitHub API rate limit. Reintentá en unos minutos."
  fi
  GH_JSON_CACHE[$repo]="$json"
  printf '%s\n' "$json"
}

github_asset() {
  local repo="$1" regex="$2" json url=""
  json="$(github_latest_json "$repo")"
  if have_cmd jq; then
    url="$(printf '%s\n' "$json" | jq -r --arg re "$regex" 'first(.assets[].browser_download_url | select(test($re))) // empty')"
  elif have_cmd python3; then
    url="$(printf '%s\n' "$json" | python3 -c '
import json, re, sys
rx = re.compile(sys.argv[1])
data = json.load(sys.stdin)
for asset in data.get("assets", []):
    url = asset.get("browser_download_url", "")
    if rx.search(url):
        print(url)
        break
' "$regex")"
  else
    url="$(printf '%s\n' "$json" | grep -oE 'https://[^"]+' | grep -E "$regex" | head -1 || true)"
  fi
  printf '%s\n' "$url"
}

first_asset() {
  local repo="$1" regex url=""
  shift
  for regex in "$@"; do
    url="$(github_asset "$repo" "$regex")"
    if [[ -n "$url" ]]; then
      printf '%s\n' "$url"
      return 0
    fi
  done
  return 1
}

install_unpacked_bin() {
  local tool="$1" src="$2" dest_name
  dest_name="${3:-$tool}"
  [[ -f "$src" ]] || die "No está el binario ${dest_name} para ${tool}"
  install -m 0755 "$src" "${PREFIX_BIN}/${dest_name}"
  record_install bin "$dest_name" "${PREFIX_BIN}/${dest_name}"
}

fetch_and_unpack() {
  local url="$1" tmp="$2" archive
  archive="$tmp/asset"
  curl -fsSL --retry 3 --retry-delay 1 -o "$archive" "$url"
  case "$url" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$tmp" ;;
    *.tar.xz) tar -xJf "$archive" -C "$tmp" ;;
    *.zip) unzip -q "$archive" -d "$tmp" ;;
    *) return 2 ;;
  esac
  return 0
}

find_unpacked() {
  local tmp="$1" name="$2"
  find "$tmp" -type f -name "$name" ! -name '*.sha256' | head -1
}

install_release() {
  local tool="$1" repo="$2" bin_name="$3"
  shift 3
  local url tmp found status
  url="$(first_asset "$repo" "$@")" || die "No hay release de ${tool} para ${MACH}"
  log "Upstream ${tool} ← ${url}"
  tmp="$(mktemp -d)"
  set +e
  fetch_and_unpack "$url" "$tmp"
  status=$?
  set -e
  if [[ "$status" -eq 2 ]]; then
    install_unpacked_bin "$tool" "$tmp/asset" "$bin_name"
  elif [[ "$status" -eq 0 ]]; then
    found="$(find_unpacked "$tmp" "$bin_name")"
    if [[ -z "$found" && "$bin_name" == "tldr" ]]; then
      found="$(find_unpacked "$tmp" tealdeer)"
    fi
    if [[ -z "$found" && "$bin_name" == "ast-grep" ]]; then
      found="$(find_unpacked "$tmp" sg)"
    fi
    [[ -n "$found" ]] || die "El archivo de ${tool} no contiene ${bin_name}"
    install_unpacked_bin "$tool" "$found" "$bin_name"
  else
    die "No se pudo descargar ${tool}"
  fi
  rm -rf "$tmp"
}

install_starship_upstream() {
  log "Upstream starship (instalador oficial)"
  curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir "$PREFIX_BIN"
  record_install bin starship "${PREFIX_BIN}/starship"
}

install_mise_upstream() {
  log "Upstream mise (instalador oficial)"
  curl -fsSL https://mise.run | env MISE_INSTALL_PATH="${PREFIX_BIN}/mise" sh
  record_install bin mise "${PREFIX_BIN}/mise"
}

install_zoxide_upstream() {
  log "Upstream zoxide (instalador oficial)"
  curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh \
    | sh -s -- --bin-dir "$PREFIX_BIN"
  record_install bin zoxide "${PREFIX_BIN}/zoxide"
}

install_yq_upstream() {
  local url tmp
  url="$(first_asset mikefarah/yq "/yq_linux_${GOARCH}$")" || die "No hay release de yq para ${GOARCH}"
  log "Upstream yq ← ${url}"
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 -o "$tmp/yq" "$url"
  install_unpacked_bin yq "$tmp/yq" yq
  rm -rf "$tmp"
}

install_yazi_upstream() {
  local url tmp yazi ya
  url="$(first_asset sxyazi/yazi "/yazi-${MACH}-unknown-linux-musl\\.zip$")" \
    || die "No hay release de yazi para ${MACH}"
  log "Upstream yazi ← ${url}"
  tmp="$(mktemp -d)"
  fetch_and_unpack "$url" "$tmp" >/dev/null
  yazi="$(find_unpacked "$tmp" yazi)"
  ya="$(find_unpacked "$tmp" ya)"
  install_unpacked_bin yazi "$yazi" yazi
  if [[ -n "$ya" ]]; then
    install_unpacked_bin yazi "$ya" ya
  fi
  rm -rf "$tmp"
}

upstream_install() {
  local tool="$1"
  hash -r || true
  case "$tool" in
    starship) install_starship_upstream ;;
    mise) install_mise_upstream ;;
    zoxide) install_zoxide_upstream ;;
    yq) install_yq_upstream ;;
    yazi) install_yazi_upstream ;;
    atuin)
      install_release atuin atuinsh/atuin atuin \
        "/atuin-${MACH}-unknown-linux-gnu\\.tar\\.gz$"
      ;;
    gum)
      install_release gum charmbracelet/gum gum \
        "/gum_.+_Linux_${LINUX_ARCH}\\.tar\\.gz$"
      ;;
    lazygit)
      install_release lazygit jesseduffield/lazygit lazygit \
        "/lazygit_.+_Linux_${LINUX_ARCH}\\.tar\\.gz$"
      ;;
    dust)
      install_release dust bootandy/dust dust \
        "/dust-v.+-${MACH}-unknown-linux-musl\\.tar\\.gz$"
      ;;
    xh)
      install_release xh ducaale/xh xh \
        "/xh-v.+-${MACH}-unknown-linux-musl\\.tar\\.gz$"
      ;;
    sd)
      install_release sd chmln/sd sd \
        "/sd-v.+-${MACH}-unknown-linux-musl\\.tar\\.gz$"
      ;;
    eza)
      install_release eza eza-community/eza eza \
        "/eza_${MACH}-unknown-linux-gnu\\.tar\\.gz$"
      ;;
    delta)
      install_release delta dandavison/delta delta \
        "/delta-.+-${MACH}-unknown-linux-musl\\.tar\\.gz$"
      ;;
    fd)
      install_release fd sharkdp/fd fd \
        "/fd-v.+-${MACH}-unknown-linux-musl\\.tar\\.gz$"
      ;;
    bat)
      install_release bat sharkdp/bat bat \
        "/bat-v.+-${MACH}-unknown-linux-musl\\.tar\\.gz$"
      ;;
    rg)
      install_release rg BurntSushi/ripgrep rg \
        "/ripgrep-.+-${MACH}-unknown-linux-musl\\.tar\\.gz$"
      ;;
    fzf)
      install_release fzf junegunn/fzf fzf \
        "/fzf-.+-linux_${GOARCH}\\.tar\\.gz$"
      ;;
    just)
      install_release just casey/just just \
        "/just-.+-${MACH}-unknown-linux-musl\\.tar\\.gz$"
      ;;
    hyperfine)
      install_release hyperfine sharkdp/hyperfine hyperfine \
        "/hyperfine-v.+-${MACH}-unknown-linux-musl\\.tar\\.gz$"
      ;;
    shellcheck)
      install_release shellcheck koalaman/shellcheck shellcheck \
        "shellcheck-.+\\.linux\\.${MACH}\\.tar\\.xz$"
      ;;
    direnv)
      install_release direnv direnv/direnv direnv \
        "/direnv\\.linux-${GOARCH}$"
      ;;
    tldr)
      install_release tldr tealdeer-rs/tealdeer tldr \
        "/tealdeer-linux-${MACH}-musl$"
      ;;
    procs)
      install_release procs dalance/procs procs \
        "/procs-v.+-${MACH}-linux\\.zip$" \
        "/procs-v.+-${MACH}-unknown-linux-gnu\\.zip$"
      ;;
    ast-grep)
      install_release ast-grep ast-grep/ast-grep ast-grep \
        "/app-${MACH}-unknown-linux-gnu\\.zip$"
      ;;
    jq)
      install_release jq jqlang/jq jq \
        "/jq-linux-${GOARCH}$"
      ;;
    fish|btop|tmux)
      die "${tool} tiene que venir del gestor de paquetes de la distro (paquete no encontrado)"
      ;;
    *)
      die "Sin método upstream para ${tool}"
      ;;
  esac
  hash -r || true
}
