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

add_event() {
        echo "$(current_time) $1" >> "$EVENT_LOG" # file format <timestamp> <weight>
}


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
# Control plane checks
# -------------------------

HUBS_JSON=$(cat "$HUBSFILE")

# Check BGP neighbor is up
check_bgp_neighbor() {
        local locality="$1"

        local proto_addr="$(echo "$HUBS_JSON" | jsonfilter -e "@.${locality}.${PROVIDER}.proto_addr")"

        vtysh -c "show ip bgp neighbors" 2>/dev/null | grep -A 2 "BGP neighbor is $proto_addr" | grep -q "BGP state = Established" >/dev/null 2>&1
}

# Check BGP critical prefix exists
check_bgp_prefix() {
        local locality="$1"

        local prefix="$(echo "$HUBS_JSON" | jsonfilter -e "@.${locality}.data.prefix")"

        vtysh -c "show ip bgp $prefix" 2>/dev/null | grep -q "$prefix" >/dev/null 2>&1
}

# Check BGP prefix flaps
check_bgp_prefix_flap() {
        local locality="$1"
        local old_state current_state prefix

        current_state=0
        prefix="$(echo "$HUBS_JSON" | jsonfilter -e "@.${locality}.data.prefix")"

        check_bgp_prefix $locality && current_state=1

        [ -f "$PREFIX_STATE" ] || touch "$PREFIX_STATE"

        old_state=$(cat "$PREFIX_STATE" 2>/dev/null || echo "1")

        if [ "$current_state" -ne "$old_state" ]; then
                log_info "BGP prefix $prefix flap detected, add_event 4"
                add_event 4
        fi

    echo "$current_state" > "$PREFIX_STATE"
}

# Control-plane checks
check_bgp_neighbor "$REGION" || echo "BGP neighbor $(echo "$HUBS_JSON" | jsonfilter -e "@.${REGION}.${PROVIDER}.proto_addr") down"
check_bgp_prefix_flap "$REGION" || echo "BGP neighbor $(echo "$HUBS_JSON" | jsonfilter -e "@.${REGION}.${PROVIDER}.proto_addr") flaps"
