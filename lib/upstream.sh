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
  if [[ "${OPS_REFRESH_UPSTREAM:-0}" != "1" && -n "${GH_JSON_CACHE[$repo]:-}" ]]; then
    printf '%s\n' "${GH_JSON_CACHE[$repo]}"
    return 0
  fi
  local json
  json="$(curl -fsSL --retry 3 --retry-delay 1 \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${repo}/releases/latest")" || {
    printf 'GitHub API falló para %s\n' "$repo" >&2
    return 1
  }
  if printf '%s' "$json" | grep -q 'API rate limit exceeded'; then
    printf 'GitHub API rate limit en %s\n' "$repo" >&2
    return 1
  fi
  GH_JSON_CACHE[$repo]="$json"
  printf '%s\n' "$json"
}

github_asset() {
  local repo="$1" regex="$2" json url=""
  json="$(github_latest_json "$repo")" || return 1
  if have_cmd jq; then
    url="$(printf '%s\n' "$json" | jq -r --arg re "$regex" 'first(.assets[].browser_download_url | select(test($re; "i"))) // empty')"
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

# Last resort: ignore the expected filename and pick a Linux asset for this CPU.
heuristic_assets() {
  local repo="$1" tokens json
  case "$MACH" in
    x86_64) tokens='x86_64|amd64|linux-x64' ;;
    aarch64) tokens='aarch64|arm64|linux-arm64' ;;
    *) return 1 ;;
  esac
  json="$(github_latest_json "$repo")" || return 1
  have_cmd jq || return 1
  printf '%s\n' "$json" | jq -r --arg tok "$tokens" '
    [ .assets[]
      | select(.name | test("sha256|sha512|\\.asc$|\\.sig$|\\.deb$|\\.rpm$|\\.msi$|\\.exe$|sbom|darwin|apple|windows|freebsd|checksum"; "i") | not)
      | select(.name | test($tok; "i"))
    ]
    | sort_by(
        (if .name | test("\\.(tar\\.gz|tgz|tar\\.xz|zip)$"; "i") then 0 else 1 end),
        (if .name | test("musl"; "i") then 0 else 1 end)
      )
    | .[0:3][]
    | .browser_download_url
  '
}

collect_assets() {
  local repo="$1"
  shift
  local regex url seen=""
  for regex in "$@"; do
    url="$(github_asset "$repo" "$regex" || true)"
    if [[ -n "$url" && "$seen" != *"|$url|"* ]]; then
      printf '%s\n' "$url"
      seen="${seen}|${url}|"
    fi
  done
  while IFS= read -r url; do
    [[ -n "$url" ]] || continue
    if [[ "$seen" != *"|$url|"* ]]; then
      printf '%s\n' "$url"
      seen="${seen}|${url}|"
    fi
  done < <(heuristic_assets "$repo" || true)
}

install_unpacked_bin() {
  local tool="$1" src="$2" dest_name
  dest_name="${3:-$tool}"
  if [[ ! -f "$src" ]]; then
    printf 'No está el binario %s para %s\n' "$dest_name" "$tool" >&2
    return 1
  fi
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

try_install_url() {
  local tool="$1" url="$2" bin_name="$3"
  local tmp found status
  tmp="$(mktemp -d)"
  set +e
  fetch_and_unpack "$url" "$tmp"
  status=$?
  set -e
  if [[ "$status" -eq 2 ]]; then
    if install_unpacked_bin "$tool" "$tmp/asset" "$bin_name"; then
      status=0
    else
      status=1
    fi
  elif [[ "$status" -eq 0 ]]; then
    found="$(find_unpacked "$tmp" "$bin_name")"
    if [[ -z "$found" && "$bin_name" == "tldr" ]]; then
      found="$(find_unpacked "$tmp" tealdeer)"
    fi
    if [[ -z "$found" && "$bin_name" == "ast-grep" ]]; then
      found="$(find_unpacked "$tmp" sg)"
    fi
    if [[ -z "$found" ]]; then
      printf 'El archivo de %s no contiene %s\n' "$tool" "$bin_name" >&2
      status=1
    elif install_unpacked_bin "$tool" "$found" "$bin_name"; then
      status=0
    else
      status=1
    fi
  else
    printf 'No se pudo descargar %s\n' "$url" >&2
    status=1
  fi
  rm -rf "$tmp"
  return "$status"
}

install_release() {
  local tool="$1" repo="$2" bin_name="$3"
  shift 3
  local -a urls=()
  local url tried=0
  while IFS= read -r url; do
    [[ -n "$url" ]] && urls+=("$url")
  done < <(collect_assets "$repo" "$@")
  if ((${#urls[@]} == 0)); then
    printf 'sin asset de %s para %s en %s\n' "$tool" "$MACH" "$repo" >&2
    return 1
  fi
  for url in "${urls[@]}"; do
    tried=$((tried + 1))
    log "Upstream ${tool} ← ${url}"
    if try_install_url "$tool" "$url" "$bin_name"; then
      return 0
    fi
    warn "${tool}: ese asset falló, busco otro"
  done
  printf 'ningún asset de %s se pudo instalar (%s intentos)\n' "$tool" "$tried" >&2
  return 1
}

run_quiet() {
  local out status
  out="$(mktemp)"
  set +e
  "$@" >"$out" 2>&1
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    tail -n 20 "$out" >&2
  fi
  rm -f "$out"
  return "$status"
}

install_starship_upstream() {
  log "Upstream starship"
  if run_quiet bash -c "curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir '$PREFIX_BIN'"; then
    if [[ -x "${PREFIX_BIN}/starship" ]] || have_cmd starship; then
      record_install bin starship "${PREFIX_BIN}/starship"
      return 0
    fi
  fi
  warn "instalador oficial de starship no dejó el binario; busco el release"
  install_release starship starship/starship starship \
    "/starship-${MACH}-unknown-linux-musl\\.tar\\.gz$" \
    "/starship-${MACH}-unknown-linux-gnu\\.tar\\.gz$"
}

install_mise_upstream() {
  log "Upstream mise"
  local arch_token="x64"
  [[ "$MACH" == "aarch64" ]] && arch_token="arm64"
  if run_quiet bash -c "curl -fsSL https://mise.run | env MISE_INSTALL_PATH='${PREFIX_BIN}/mise' sh"; then
    if [[ -x "${PREFIX_BIN}/mise" ]] || have_cmd mise; then
      record_install bin mise "${PREFIX_BIN}/mise"
      return 0
    fi
  fi
  warn "instalador oficial de mise no dejó el binario; busco el release"
  install_release mise jdx/mise mise \
    "/mise-.+-linux-${arch_token}\\.tar\\.gz$" \
    "/mise-.+-${MACH}-unknown-linux"
}

install_zoxide_upstream() {
  log "Upstream zoxide"
  if run_quiet bash -c "curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh -s -- --bin-dir '$PREFIX_BIN'"; then
    if [[ -x "${PREFIX_BIN}/zoxide" ]] || have_cmd zoxide; then
      record_install bin zoxide "${PREFIX_BIN}/zoxide"
      return 0
    fi
  fi
  warn "instalador oficial de zoxide no dejó el binario; busco el release"
  install_release zoxide ajeetdsouza/zoxide zoxide \
    "/zoxide-.+-${MACH}-unknown-linux-musl\\.tar\\.gz$"
}

install_yazi_upstream() {
  local url tmp yazi ya
  url="$(collect_assets sxyazi/yazi "/yazi-${MACH}-unknown-linux-musl\\.zip$" | head -1)"
  if [[ -z "$url" ]]; then
    printf 'sin asset de yazi para %s\n' "$MACH" >&2
    return 1
  fi
  log "Upstream yazi ← ${url}"
  tmp="$(mktemp -d)"
  if ! fetch_and_unpack "$url" "$tmp"; then
    rm -rf "$tmp"
    printf 'no se pudo descomprimir yazi\n' >&2
    return 1
  fi
  yazi="$(find_unpacked "$tmp" yazi)"
  ya="$(find_unpacked "$tmp" ya)"
  if [[ -z "$yazi" ]]; then
    rm -rf "$tmp"
    printf 'el archivo de yazi no contiene el binario\n' >&2
    return 1
  fi
  install_unpacked_bin yazi "$yazi" yazi || { rm -rf "$tmp"; return 1; }
  if [[ -n "$ya" ]]; then
    install_unpacked_bin yazi "$ya" ya || true
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
    yq)
      install_release yq mikefarah/yq yq \
        "/yq_linux_${GOARCH}$"
      ;;
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
      printf '%s no está en los repos de esta distro y no hay binario upstream\n' "$tool" >&2
      return 1
      ;;
    *)
      printf 'sin método upstream para %s\n' "$tool" >&2
      return 1
      ;;
  esac
  hash -r || true
}
