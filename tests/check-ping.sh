#!/bin/sh

# -------------------------
# Configuration
# -------------------------

INFO=1
DEBUG=1

TIMER=30        # Main loop delay timer in seconds

LOGFILE="/var/log/hub-switcher-wd.log"
HUBSFILE="/etc/hubs.json"

INTERFACE="mgre1"       # DMVPN/NHRP tunnel interface name (must be set!)

PROVIDER="megafon"      # Current provider name (must be set!) (ex. 'megafon', 'letai', 'mts'; see hubs.json file)

LOCALITY1="Niznekamsk"  # Locality of main DMVPN/NHRP hub HUAWEI AR6710-L26T2X4
LOCALITY2="Kazan"       # Locality of backup DMVPN/NHRP hub HUAWEI AR6710-L26T2X4

REGION=$LOCALITY1       # Default DMVPN/NHRP hub locality (must be set!) (will change during script execution)

# -------------------------
# Finite State Machine (FSM) variables
# -------------------------

SLIDING_WINDOW=600              # Sliding window for score calculation in seconds
ESCALATION_THRESHOLD=15         # Threshold for escalation
NETWORK_STABILIZATION_TIMER=60  # Delay to allow the network to stabilize after configuration changes in seconds

EVENT_LOG="/tmp/wd_event_log"        # Log of events (each line: timestamp + weight) for sliding window health score calculation
PREFIX_STATE="/tmp/wd_prefix_state"  # Stores the last known state of the critical BGP prefix (0=absent, 1=present) to detect flaps
STATE_FILE="/tmp/wd_state_file"      # Current escalation state of the hs-watchdog (OK, DEGRADED, RECOVERY, FORCED_RESTART)

# -------------------------
# Helpers
# -------------------------

current_time() { date +%s; }    # Print current time in UNIX format (in seconds from 1970-01-01)

# -----------------------------
# Log processing
# -----------------------------

# Save to system log (ex. 'log_info "UBUS event detected"')
log_info() {
        [ -n "$INFO" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') hub-switcher-wd INFO: $1" >> "$LOGFILE"
}

# Save to log file (ex. 'log_debug "Channel is down"')
log_debug() {
        [ -n "$DEBUG" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') hub-switcher-wd DEBUG: $1" >> "$LOGFILE"
}

# -------------------------
# Data plane checks
# -------------------------

# Check by ping HUAWEI AR6710-L26T2X4 hubs DMVPN/NHRP tunnel interfaces
check_ping() {
        local locality="$1"
        local proto_addr

        proto_addr="$(echo "$HUBS_JSON" | jsonfilter -e "@.${locality}.${PROVIDER}.proto_addr")"

        ping -c 4 -w 2 "$proto_addr" | grep -q "64 bytes from $proto_addr: icmp_req=" >/dev/null 2>&1
}

# Check availability of "MARS Arsenal" service
check_tcp() {
        local locality="$1"
        local server_addr tcp_port

        server_addr="$(echo "$HUBS_JSON" | jsonfilter -e "@.${locality}.data.server_addr")"
        tcp_port="$(echo "$HUBS_JSON" | jsonfilter -e "@.${locality}.data.tcp_port")"

        nc -z -v -w 3 "$server_addr" "$tcp_port" 2>&1 | awk '{print $1, $3, $4}' | grep -q "$server_addr $tcp_port open" >/dev/null 2>&1 
}

HUBS_JSON=$(cat "$HUBSFILE")


# Data-plane checks
check_ping "$REGION" || echo "Ping to host $(echo "$HUBS_JSON" | jsonfilter -e "@.${REGION}.${PROVIDER}.proto_addr") failed"
check_tcp "$REGION" || echo "TCP check to server $(echo "$HUBS_JSON" | jsonfilter -e "@.${REGION}.data.server_addr") failed"


has_locality1=$(echo "$HUBS_JSON" | jsonfilter -e "@.${LOCALITY1}.${PROVIDER}.operator" 2>/dev/null || echo "has't_locality1")
has_locality2=$(echo "$HUBS_JSON" | jsonfilter -e "@.${LOCALITY2}.${PROVIDER}.operator" 2>/dev/null || echo "has't_locality2")

echo "has_locality1 $has_locality1"
echo "has_locality2 $has_locality2"
