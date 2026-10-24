#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ] || [ ! -t 0 ] || [ ! -t 2 ]; then
    printf 'Error: Bash and an interactive terminal required. Use ssh -t.\n' >&2
    exit 1
fi

set -euo pipefail

if (( EUID != 0 )); then
    printf 'Error: run this script as root.\n' >&2
    exit 1
fi

if pgrep -x sshd >/dev/null; then
    printf 'Error: stop sshd before running this script.\n' >&2
    exit 1
fi

MIN_SSH_VERSION=10.6p1
SSH_SERVER_PACKAGES=(openssh-server dropbear dropbear-bin tinysshd lsh-server)

ts_ip=$(tailscale ip -4)
if ! perl -MSocket=inet_pton,AF_INET -e 'exit !defined inet_pton(AF_INET, $ARGV[0])' "$ts_ip"; then
    printf 'Error: invalid Tailscale IPv4 address.\n' >&2
    exit 1
fi

installed() {
    [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == 'install ok installed' ]]
}

confirm() {
    local answer
    read -r -p "$1 [y/N] " answer || return 1
    [[ ${answer,,} == y || ${answer,,} == yes ]]
}

SSHD=$(command -v sshd || true)
if [[ -z $SSHD ]]; then
    printf 'Error: sshd is not installed or not in PATH.\n' >&2
    exit 1
fi

for package in "${SSH_SERVER_PACKAGES[@]}"; do
    [[ $package != openssh-server ]] || continue
    installed "$package" || continue

    printf '\nInstalled: %s. Removing it could lock you out of SSH.\n' "$package"
    if confirm "Have you tested a second OpenSSH connection and want to remove $package?"; then
        apt-get remove "$package"
    fi
done

if systemctl is-active --quiet ssh.socket; then
    systemctl stop ssh.socket
fi
systemctl stop ssh.service

if pgrep -x sshd >/dev/null; then
    printf 'Error: sshd processes remain after stopping the service.\n' >&2
    exit 1
fi

sshd_version=$("$SSHD" -V 2>&1)
if [[ ! $sshd_version =~ OpenSSH_([0-9]+\.[0-9]+p[0-9]+) ]] ||
    ! dpkg --compare-versions "${BASH_REMATCH[1]}" ge "$MIN_SSH_VERSION"; then
    printf 'Error: OpenSSH %s or newer required; found %s.\n' "$MIN_SSH_VERSION" "$sshd_version" >&2
    exit 1
fi

config_entry=$(find /etc/ssh/sshd_config.d/ -mindepth 1 -maxdepth 1 -print -quit)
if [[ -n $config_entry ]]; then
    printf 'Error: /etc/ssh/sshd_config.d/ must be empty.\n' >&2; exit 1
fi

perl -ni -e 'print unless m{^[ \t]*Include[ \t]+/etc/ssh/sshd_config\.d/\*\.conf[ \t]*(?:#.*)?$}i' /etc/ssh/sshd_config

if grep -Ei '^[[:space:]]*(Include|Match)([[:space:]=]|$)' /etc/ssh/sshd_config; then
    printf 'Error: active Include and Match directives are not supported.\n' >&2
    exit 1
fi

temp_file=$(mktemp)
trap 'rm -f "$temp_file"' EXIT
cat /etc/ssh/sshd_config > "$temp_file"

perl -0777 -pi -e 's/^[ \t]*#?[ \t]*KexAlgorithms\b.*/KexAlgorithms mlkem768x25519-sha256/im or $_ .= "\nKexAlgorithms mlkem768x25519-sha256\n"' "$temp_file"
perl -0777 -pi -e 's/^[ \t]*#?[ \t]*PermitRootLogin\b.*/PermitRootLogin no/im or $_ .= "\nPermitRootLogin no\n"' "$temp_file"
perl -0777 -pi -e 's/^[ \t]*#?[ \t]*PasswordAuthentication\b.*/PasswordAuthentication no/im or $_ .= "\nPasswordAuthentication no\n"' "$temp_file"
perl -0777 -pi -e 's/^[ \t]*#?[ \t]*KbdInteractiveAuthentication\b.*/KbdInteractiveAuthentication no/im or $_ .= "\nKbdInteractiveAuthentication no\n"' "$temp_file"
perl -0777 -pi -e 's/^[ \t]*#?[ \t]*PermitEmptyPasswords\b.*/PermitEmptyPasswords no/im or $_ .= "\nPermitEmptyPasswords no\n"' "$temp_file"
perl -0777 -pi -e 's/^[ \t]*#?[ \t]*PubkeyAuthentication\b.*/PubkeyAuthentication yes/im or $_ .= "\nPubkeyAuthentication yes\n"' "$temp_file"

perl -0777 -pi -e 's/^[ \t]*#?[ \t]*PubkeyAcceptedAlgorithms\b.*/PubkeyAcceptedAlgorithms ssh-mldsa44-ed25519/im or $_ .= "\nPubkeyAcceptedAlgorithms ssh-mldsa44-ed25519\n"' "$temp_file"

TS_IP="$ts_ip" perl -0777 -pi -e 's/^[ \t]*#?[ \t]*ListenAddress\b.*\n?//img; $_ = "ListenAddress $ENV{TS_IP}\n" . $_' "$temp_file"

install -d -o root -g root -m 0755 /run/sshd
"$SSHD" -t -f "$temp_file"

{
    install -o root -g root -m 0644 "$temp_file" /etc/ssh/sshd_config
    effective_config=$("$SSHD" -T | awk '{$1 = tolower($1); print}')
    if [[ $(grep '^listenaddress ' <<< "$effective_config" | cut -d: -f1 | sort -u) != "listenaddress $ts_ip" ]]; then
        printf 'Validation failed: expected only ListenAddress %s.\n' "$ts_ip" >&2
        exit 1
    fi
    while IFS= read -r option; do
        if ! grep -Fxq "$option" <<< "$effective_config"; then
            printf 'Validation failed: %s\n' "$option" >&2
            exit 1
        fi
        printf 'Verified: %s\n' "$option"
    done <<'OPTIONS'
kexalgorithms mlkem768x25519-sha256
permitrootlogin no
passwordauthentication no
kbdinteractiveauthentication no
permitemptypasswords no
pubkeyauthentication yes
pubkeyacceptedalgorithms ssh-mldsa44-ed25519
OPTIONS
}
