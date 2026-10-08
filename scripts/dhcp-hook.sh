#!/bin/sh
# udhcpc invokes this with lease information in environment variables.
# Only addresses/routes in the invoking network namespace are changed.
# Deliberately do not write /etc/resolv.conf or change the shared hostname.
set -eu
case "${1:-}" in
  deconfig)
    ip -4 addr flush dev "$interface"
    ;;
  bound|renew)
    # Both configured lab pools are /24; reject an unexpected lease shape.
    [ "${subnet:-}" = '255.255.255.0' ] || exit 1
    ip -4 addr flush dev "$interface"
    ip addr add "$ip/24" dev "$interface"
    if [ -n "${router:-}" ]; then
      gateway=${router%% *}
      ip route replace default via "$gateway" dev "$interface"
    fi
    printf 'DHCP %s: %s/24 gateway=%s dns=%s\n' "$1" "$ip" "${router:-none}" "${dns:-none}"
    ;;
esac
