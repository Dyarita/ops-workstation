# Ops Workstation recipes
set shell := ["bash", "-cu"]

root := justfile_directory()

# List recipes
default:
    @just --list

# Show what the installer would do on this machine
plan:
    {{root}}/install --plan

# Full install (asks for sudo)
install:
    sudo {{root}}/install

# Rollback last snapshot
rollback:
    sudo {{root}}/rollback

# List snapshots
snapshots:
    {{root}}/rollback --list

# Health check
status:
    {{root}}/bin/ops status

# Interactive ops menu
ops:
    {{root}}/bin/ops

# Lint shell scripts
lint:
    shellcheck -x -P {{root}}/lib {{root}}/install {{root}}/rollback {{root}}/bin/ops {{root}}/lib/*.sh

# Doctor
doctor:
    {{root}}/bin/ops doctor
