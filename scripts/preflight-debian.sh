#!/usr/bin/env bash
# OceanMail Station 0.2 — Debian/local verification workstation preflight
# Read-only: this script does not install packages, load modules, or modify configuration.

set -u

section() {
    printf '\n== %s ==\n' "$1"
}

have() {
    command -v "$1" >/dev/null 2>&1
}

resolve_cmd() {
    local cmd="$1"
    local path
    path="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -n "$path" ]]; then
        printf '%s\n' "$path"
        return 0
    fi
    for path in "/usr/sbin/$cmd" "/sbin/$cmd"; do
        if [[ -x "$path" ]]; then
            printf '%s\n' "$path"
            return 0
        fi
    done
    return 1
}

section "OceanMail Station preflight"
printf 'UTC: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'Host: %s\n' "$(hostname 2>/dev/null || printf unknown)"
printf 'Kernel: %s\n' "$(uname -srmo 2>/dev/null || uname -a)"

section "Operating system"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf 'ID=%s\n' "${ID:-unknown}"
    printf 'VERSION_ID=%s\n' "${VERSION_ID:-unknown}"
    printf 'VERSION_CODENAME=%s\n' "${VERSION_CODENAME:-unknown}"
    printf 'PRETTY_NAME=%s\n' "${PRETTY_NAME:-unknown}"
else
    printf 'WARN: /etc/os-release not readable\n'
fi
printf 'Architecture: %s\n' "$(dpkg --print-architecture 2>/dev/null || uname -m)"

section "Required build and lab commands"
commands=(git gcc make pkg-config python3 sha256sum setsid pkill aplay arecord ss)
for cmd in "${commands[@]}"; do
    if have "$cmd"; then
        version="$($cmd --version 2>/dev/null | head -n 1 || true)"
        printf 'OK   %-12s %s\n' "$cmd" "${version:-present}"
    else
        printf 'MISS %-12s\n' "$cmd"
    fi
done

section "Mercury source-build packages"
packages=(
    build-essential
    pkg-config
    libasound2-dev
    libpulse-dev
    libhamlib-dev
    make
    git
    alsa-utils
    procps
    util-linux
    iproute2
    kmod
)

if have dpkg-query; then
    for pkg in "${packages[@]}"; do
        status="$(dpkg-query -W -f='${db:Status-Abbrev} ${Version}' "$pkg" 2>/dev/null || true)"
        if [[ "$status" == ii\ * ]]; then
            printf 'OK   %-20s %s\n' "$pkg" "${status#ii }"
        else
            printf 'MISS %-20s\n' "$pkg"
        fi
    done
else
    printf 'WARN: dpkg-query unavailable; package state not checked\n'
fi

section "ALSA loopback capability"
MODINFO="$(resolve_cmd modinfo || true)"
if [[ -n "$MODINFO" ]]; then
    printf 'INFO modinfo resolved to %s\n' "$MODINFO"
    if "$MODINFO" snd-aloop >/dev/null 2>&1; then
        printf 'OK   snd-aloop kernel module is available\n'
    else
        printf 'MISS snd-aloop kernel module was not found for this kernel\n'
    fi
else
    printf 'WARN: modinfo unavailable; cannot verify snd-aloop availability\n'
fi

if grep -q '^snd_aloop ' /proc/modules 2>/dev/null; then
    printf 'INFO snd-aloop is currently loaded\n'
else
    printf 'INFO snd-aloop is not currently loaded (preflight will not load it)\n'
fi

if [[ -r /proc/asound/cards ]]; then
    printf '%s\n' '-- /proc/asound/cards --'
    cat /proc/asound/cards
else
    printf 'INFO /proc/asound/cards is unavailable\n'
fi

section "Candidate Mercury loopsim TCP ports"
ports=(8100 8200 8300 8301 8400 8401)
if have ss; then
    listeners="$(ss -H -ltn 2>/dev/null || true)"
    for port in "${ports[@]}"; do
        if awk '{print $4}' <<<"$listeners" | grep -Eq "[:.]${port}$"; then
            printf 'BUSY %5s\n' "$port"
        else
            printf 'FREE %5s\n' "$port"
        fi
    done
else
    printf 'WARN: ss unavailable; TCP port conflicts not checked\n'
fi

section "Resources"
if have free; then
    free -h
fi
if have df; then
    df -h .
fi

section "Git identity and SSH client"
printf 'git user.name: %s\n' "$(git config --global --get user.name 2>/dev/null || printf '<unset>')"
printf 'git user.email: %s\n' "$(git config --global --get user.email 2>/dev/null || printf '<unset>')"
if have ssh; then
    printf 'SSH client: %s\n' "$(ssh -V 2>&1 | head -n 1)"
else
    printf 'MISS ssh client\n'
fi

section "Preflight complete"
printf '%s\n' 'No system changes were made.'
printf '%s\n' 'Paste the complete output into the OceanMail development thread before installing or configuring the HERMES/Mercury stack.'
