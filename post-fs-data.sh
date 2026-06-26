#!/system/bin/sh
MODDIR=${0%/*}

# iptables redirection is intentionally NOT applied here. Applying DNAT rules before
# dnscrypt-proxy is listening creates a DNS blackhole during early boot. service.sh
# applies the rules via start_service -> apply_iptables once the service is ready.
