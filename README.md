# Ops Workstation

Workstation para ingenieros: shell, navegación, búsqueda, automatización y una consola de operaciones. El instalador es **agnóstico de distro**: no asume rutas ni nombres de Ubuntu. Detecta el gestor de paquetes, pregunta a los repos de *esa* máquina qué paquetes existen, resuelve el binario real (`bat`/`batcat`, `fd`/`fdfind`) y solo baja un release upstream cuando la distro no lo empaqueta.

Pensado para probar en VMs: Ubuntu 24.04, Debian 12, Debian 13, Arch y Omarchy (Arch, mismo `pacman`).

## Instalar

```bash
git clone https://github.com/Dyarita/ops-workstation.git
cd ops-workstation
sudo ./install
```

Equivalente: `sudo bash ./install`.

Eso, de principio a fin:

1. Snapshot de las configs del usuario que invocó `sudo` (no de root).
2. Instala el stack con `apt` o `pacman`, según lo que haya.
3. Completa lo que falte con el binario oficial, en `/usr/local/bin` (FHS, ya está en el PATH de login).
4. Escribe configs en el directorio XDG de ese usuario.
5. Deja `fish` como login shell.

Ver el plan sin tocar el sistema:

```bash
./install --plan
```

Si una herramienta falla, el instalador sigue con el resto. Al final lista los pendientes. Para volver a buscar el paquete y el release upstream de lo que faltó:

```bash
sudo ./install --repair
ops failures
```

Otro usuario: `sudo OPS_USER=nombre ./install`.

## Rollback

```bash
sudo ./rollback --list
sudo ./rollback                  # último snapshot
sudo ./rollback 20261015-031800
sudo ./rollback --files-only     # configs y shell, sin desinstalar paquetes
```

## Qué se adapta solo

| Se descubre en la máquina | No se hardcodea |
|---|---|
| `pacman` o `apt-get` | el nombre de la distro |
| si el paquete existe en *sus* repos | una lista fija de paquetes de Ubuntu |
| `bat` vs `batcat`, `fd` vs `fdfind` | el path del binario |
| home y grupo de `SUDO_USER` | `/home/...` |
| `command -v fish` | `/usr/bin/fish` |
| PATH de login (`/etc/environment` o el profile) | asumir que `~/.local/bin` está en el PATH |

`fish`, `tmux` y `btop` salen del gestor de la distro. El resto sale del gestor si el paquete existe y, si no, de un release upstream para `uname -m`.

## Consola

```bash
ops            # menú
ops status
ops search
just --list
```

En fish: `z` (zoxide), `ops-search`, `yy` (yazi y cd al salir).

## Stack

Fish, Starship, zoxide, fzf, Atuin, ripgrep, fd, bat, eza, btop, tmux, lazygit, yazi, mise, direnv, just, gum, jq, yq, ShellCheck, dust, git-delta, xh, ast-grep, procs, sd, tealdeer, hyperfine.
