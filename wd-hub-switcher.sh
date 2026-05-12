#!/bin/sh

# =========================================================
# wd-hub-switcher.sh
#
# Description:
#   Watchdog script for DMVPN/NHRP hub switching with
#   health scoring, escalation FSM, and auto-recovery.
#
# Author:        Evgeny Uzov
# Email:         uzov@cg.ru
# Phone:         +7-917-396-14-24
# Company:       CENTER
#
# Created:       2026-03-26
# Last Modified: 2026-04-30
# Version:       2.0
#
# Notes:
#   - Requires ubus, jsonfilter, vtysh, nc
#   - Designed for OpenWRT-based systems
#
# =========================================================

# . /lib/irz/network_utils.sh
# . /lib/functions.sh
. /usr/share/libubox/jshn.sh

# -------------------------
# Configuration
# -------------------------

INFO=1
DEBUG=1

LOOP_TIMER=30			# Main loop delay timer in seconds
MAX_CYCLES_TO_REBOOT=10		# Max number of SWITCHING cycles before reboot
CYCLE=$MAX_CYCLES_TO_REBOOT	# Start and then remain "SWITCHING" cycles before reboot (can change during execution)
SCORE_0_COUNTER=0		# Counter for consecutive events with health score=0

LOGFILE="/var/log/wd-hub-switcher.log"	# Path to main log file
MAX_BACKUPS=2				# Maximum number of rotated log backups to keep
ROTATED_AT=$(date '+%Y-%m-%d')		# Date when logs were last rotated

HUBSFILE="/etc/hubs.json"	# Main configuration file

INTERFACE="mgre1"	# DMVPN/NHRP tunnel interface name

PROVIDER="Beeline"		# Default provider name (ex. 'MegaFon', 'Letai', 'MTS RUS', 'Beeline', 'Tele2', 'Yota'; use only these names in hubs.json file!) or 'Auto' (must be set!)
SET_PROVIDER_AUTO=1		# Auto-detect provider (1=yes, 0=use default provider name)  
WAIT_FOR_MOBILE_TIMER=120	# Max time to wait for mobile interface to come up in seconds

LOCALITY1="Niznekamsk"	# Main DMVPN/NHRP hub HUAWEI AR6710-L26T2X4 location
LOCALITY2="Kazan"	# Backup DMVPN/NHRP hub HUAWEI AR6710-L26T2X4 location

DEFAULT_REGION=$LOCALITY1	# Default/preferred DMVPN/NHRP hub location
REGION=$DEFAULT_REGION		# Start and then current DMVPN/NHRP hub locality (can change during execution)
SWITCHED_AT=$(date '+%Y-%m-%d')	# Date when the switch to the default/preferred DMVPN/NHRP hub occurred			

# -------------------------------------------------
# Finite State Machine (FSM) variables and timers
# -------------------------------------------------

SLIDING_WINDOW_TIMER=300	# Sliding window for score calculation in seconds (approx. 8*TIMER+10)
ESCALATION_THRESHOLD=15		# Health score threshold to trigger escalation
NETWORK_STABILIZATION_TIMER=120	# Delay after reconfiguring network to allow stabilization in seconds

EVENT_LOG="/tmp/wd_event_log"        # Log of events (each line: timestamp + weight) for sliding window health score calculation
PREFIX_STATE="/tmp/wd_prefix_state"  # Stores the last known state of the critical BGP prefix (0=absent, 1=present) to detect flaps
STATE_FILE="/tmp/wd_state_file"      # Current escalation state of the hs-watchdog (OK, DEGRADED, RECOVERY, SWITCHING, FORCED_RESTART)

# -------------------------
# Routines
# -------------------------

# Print current time in UNIX format (in seconds from 1970-01-01)
current_time() { date +%s; }

# Normalize operator name: substitue spaces, "-", russian letters with "_"
normalize() {
    echo "$1" | tr -c 'a-zA-Z0-9' '_'
}

# Validate ip address
is_valid_ip() {
    echo "$1" | grep -Eq '^(25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})(\.(25[0-5]|2[0-4][0-9]|1?[0-9]{1,2})){3}$'
}

# Parse HUBS_JSON, validate IPs, and cache parameters using jshn 
load_cache() {
	json_load "$HUBS_JSON"
	json_get_keys localities

	for locality in $localities; do
		json_select "$locality" 2>/dev/null
		json_get_keys providers
			for provider in $providers; do
				json_select "$provider"
				if [ "$provider" != "data" ]; then
					json_get_var operator operator
					operator_safe=$(normalize "$operator")
					json_get_var ipaddr ipaddr
					json_get_var proto_addr proto_addr
					json_get_var nbma_addr nbma_addr
					json_get_var tunlink tunlink

					# Validate IPs 
					for addr in "$ipaddr" "$proto_addr" "$nbma_addr"; do 
						if ! is_valid_ip "$addr" >/dev/null 2>&1; then 
							log_debug "Invalid IP in cache [$locality/$operator]: $addr"
							json_select .. 2>/dev/null 
						return 1 
						fi 
					done

					# Store into cache
					provider_safe=$(normalize "$provider")
					eval "CACHE_${locality}_${provider_safe}_operator=\"$operator_safe\""
					eval "CACHE_${locality}_${provider_safe}_ipaddr=\"$ipaddr\""
					eval "CACHE_${locality}_${provider_safe}_proto_addr=\"$proto_addr\""
					eval "CACHE_${locality}_${provider_safe}_nbma_addr=\"$nbma_addr\""
					eval "CACHE_${locality}_${provider_safe}_tunlink=\"$tunlink\""
				else
					json_get_var server_addr server_addr
					
					if ! is_valid_ip "$server_addr" >/dev/null 2>&1; then
						log_debug "Invalid IP in cache [$locality/data]: $server_addr"
						json_select .. 2>/dev/null
					return 1
					fi

					json_get_var prefix prefix
					json_get_var tcp_port tcp_port

					# Store into cache
					eval "CACHE_${locality}_server_addr=\"$server_addr\""
					eval "CACHE_${locality}_prefix=\"$prefix\""
					eval "CACHE_${locality}_tcp_port=\"$tcp_port\""
				fi

				json_select .. 2>/dev/null
			done					

		json_select .. 2>/dev/null
	done
}

# Wait for one of mobile interface is up and get provider name
wait_mobile_is_up() {
	local timeout=$1
	local i=1
	local start_time=$(date +%s)
	local ubus_json_output state operator ipaddr mask rssi mode l3_device dots

	while [ $(( $(date +%s) - start_time )) -lt "$timeout" ]; do
		for iface in sim1 sim2; do

			ubus_json_output=$(ubus call network.interface.$iface status 2>/dev/null)
			[ -z "$ubus_json_output" ] && continue

			json_load "$ubus_json_output"

			json_get_var state up
			case "$state" in
				1|true)
					# l3_device
					json_get_var l3_device l3_device
					l3_device=${l3_device:-"N/A"}

					# ipv4
					json_select 'ipv4-address' 2>/dev/null
					json_select 1 2>/dev/null
					json_get_var ipaddr address
					json_get_var mask mask
					ipaddr=${ipaddr:-"N/A"}
					mask=${mask:-"N/A"}
					json_select .. 2>/dev/null
					json_select .. 2>/dev/null

					# data/info
					json_select data 2>/dev/null
					json_select info 2>/dev/null

					json_get_var operator operator
					json_get_var rssi rssi
					json_get_var mode mode

					operator=${operator:-"N/A"}
					rssi=${rssi:-"N/A"}
					mode=${mode:-"N/A"}

					json_select .. 2>/dev/null
					json_select .. 2>/dev/null

					log_info "Mobile $iface is up: operator=$operator, mode=$mode, rssi=${rssi}dB, ip=${ipaddr}/${mask}, dev=$l3_device"
					if [ "${SET_PROVIDER_AUTO:-0}" = "1" ] && [ -n "$operator" ] && [ "$operator" != "N/A" ]; then
						PROVIDER="$operator"
						PROVIDER_SAFE=$(normalize "$operator")
						return 0
					fi
					;;
			esac
		done
		dots=$(printf '%*s' "$i" '' | tr ' ' '.')
		log_debug "Waiting for mobile interface${dots}elapsed: $(( $(date +%s) - start_time )) sec"
		i=$((i + 1))
		sleep 5
	done
		log_info "Timeout (${timeout} sec): no mobile interface is up, will use default provider name $PROVIDER"
		return 1
}

# -----------------------------
# Log processing
# -----------------------------

# Save to system log (ex. 'log_info "UBUS event detected"') 
log_info() {
	[ -n "$INFO" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') wd-hub-switcher INFO: $1" >> "$LOGFILE"
}

# Save to log file (ex. 'log_debug "Channel is down"')
log_debug() {
	[ -n "$DEBUG" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') wd-hub-switcher DEBUG: $1" >> "$LOGFILE"
}

# Archives the current log file to a timestamped tar.gz file in the same directory and keeps only the last N backups
log_rotate() {
	local logfile="$1"
	local max_backups="${2:-7}"
	local dir timestamp count oldest

	[ -f "$logfile" ] || return 0  # Exit if log file does not exist

	dir=$(dirname "$logfile")
	timestamp=$(date '+%Y-%m-%d_%H-%M')
	tar -czf "$dir/$(basename "$logfile")_$timestamp.tar.gz" "$logfile"

	# Clear the current log
	: > "$logfile"

	# Remove oldest archives if exceeding max_backups
	count=$(ls "$dir"/$(basename "$logfile")_*.tar.gz 2>/dev/null | wc -l)
	while [ "$count" -gt "$max_backups" ]; do
		oldest=$(ls -1 "$dir"/$(basename "$logfile")_*.tar.gz | head -n1)
		rm -f "$oldest"
		count=$((count - 1))
	done
}

# -------------------------
# Sliding window functions
# -------------------------

cleanup_events() {
	local now tmpfile
	
	now=$(current_time)
	tmpfile="${EVENT_LOG}.tmp"
	
	[ -f "$EVENT_LOG" ] || touch "$EVENT_LOG"
	
	# Keep only events within the last SLIDING_WINDOW_TIMER seconds
	awk -v time="$now" -v win="$SLIDING_WINDOW_TIMER" '
		($1 + 0) > (time - win)    
	' "$EVENT_LOG" > "$tmpfile" && mv "$tmpfile" "$EVENT_LOG"
}

add_event() {
    	echo "$(current_time) $1" >> "$EVENT_LOG" # file format <timestamp> <weight>
}

calculate_score() {
	local score ts weight    	

	score=0

	cleanup_events
    	while read -r ts weight; do # ts - column 1, weight - column 2
		score=$((score + weight)) 
	done < "$EVENT_LOG"
    	echo "$score" # do return function value!
}

# -------------------------
# Data plane checks
# -------------------------

# Check by ping HUAWEI AR6710-L26T2X4 hubs DMVPN/NHRP tunnel interfaces
check_ping() { 
	local locality="$1"
	local proto_addr; eval "proto_addr=\$CACHE_${locality}_${PROVIDER_SAFE}_proto_addr"

	[ -z "$proto_addr" ] && {
		log_info "proto_addr for $locality / $PROVIDER missing, skipping ping check"
		return 1
	}
	
	ping -c 4 -w 2 "$proto_addr" | grep -q "64 bytes from $proto_addr: icmp_req=" >/dev/null 2>&1
}

# Check service availability (TCP check)
check_tcp() {
	local locality="$1"
        local server_addr tcp_port
	
	eval "server_addr=\$CACHE_${locality}_server_addr"
	[ -z "$server_addr" ] && {
		log_info "Server address for $locality / $PROVIDER missing, skipping TCP check"
		return 1
	}

	eval "tcp_port=\$CACHE_${locality}_tcp_port"	
	[ -z "$tcp_port" ] && {
		log_info "TCP port for $locality / $PROVIDER missing, skipping TCP check"
		return 1
	}

	nc -z -v -w 3 "$server_addr" "$tcp_port" 2>&1 | awk '{print $1, $3, $4}' | grep -q "$server_addr $tcp_port open" >/dev/null 2>&1 
}

# -------------------------
# Control plane checks
# -------------------------

# Check BGP neighbor is up
check_bgp_neighbor() {
	local locality="$1"
	local proto_addr; eval "proto_addr=\$CACHE_${locality}_${PROVIDER_SAFE}_proto_addr"
	
	[ -z "$proto_addr" ] && {
		log_info "proto_addr for $locality / $PROVIDER missing, skipping BGP neighbor check"
		return 1
	}

	vtysh -c "show ip bgp neighbors" 2>/dev/null | grep -A 2 "BGP neighbor is $proto_addr" | grep -q "BGP state = Established" >/dev/null 2>&1
}	

# Check BGP critical prefix exists
check_bgp_prefix() {
	local locality="$1"

	eval "prefix=\$CACHE_${locality}_prefix"

	[ -z "$prefix" ] && {
		log_info "BGP prefix for $locality / $PROVIDER missing, skipping BGP prefix check"
		return 1
	}

	vtysh -c "show ip bgp $prefix" 2>/dev/null | grep -q "$prefix" >/dev/null 2>&1
}

# Check BGP prefix flaps
check_bgp_prefix_flap() {
	local locality="$1"
	local old_prefix old_state old_count
	local current_prefix current_state count

	current_state=0
	eval "current_prefix=\$CACHE_${locality}_prefix"

	check_bgp_prefix "$locality" && current_state=1

	# Init file if empty
	[ -f "$PREFIX_STATE" ] || touch "$PREFIX_STATE"
	[ -s "$PREFIX_STATE" ] || echo "$current_prefix $current_state 0" > "$PREFIX_STATE"

	read old_prefix old_state old_count < "$PREFIX_STATE" 2>/dev/null

	# Fallback safety
	old_count=${old_count:-0}
	count=$old_count

	# If same prefix - track changes
	if [ "$current_prefix" = "$old_prefix" ]; then
		if [ "$current_state" -ne "$old_state" ]; then
			count=$((old_count + 1))
			log_debug "Prefix $current_prefix state changed ($old_state -> $current_state), count=$count"

			#If flap = 3 or more changes
			if [ "$count" -ge 3 ]; then
				log_info "BGP prefix $current_prefix flap detected (changes=$count), add_event 4"
                		add_event 4
            		fi
        	fi
	else
		# If prefix changed - reset counter
		count=0
		log_debug "Prefix changed from $old_prefix to $current_prefix, reset flap counter"
	fi

    echo "$current_prefix $current_state $count" > "$PREFIX_STATE"
}

# -------------------------
# Actions
# -------------------------

# Soft reset BGP neighbor
reset_bgp_neighbor_soft() {
	local neighbor="$1"

	log_info "Soft reseting BGP neighbor $neighbor"

	vtysh -c "clear ip bgp $neighbor in"  >/dev/null 2>&1
	vtysh -c "clear ip bgp $neighbor out" >/dev/null 2>&1
	vtysh -c "clear ip bgp $neighbor soft" >/dev/null 2>&1

	sleep 3
	log_info "BGP neighbor $neighbor soft reset completed"
}

# Hard reset BGP neighbor
reset_bgp_neighbor() {
	local neighbor="$1"
	local asn
	
	asn=$(vtysh -c "show ip bgp summary" | awk -v n="$neighbor" '$1 == n {print $3}')
	
	[ -n "$asn" ] || { log_debug "Neighbor $neighbor not found, skipping reset"; return 1; }

	log_info "Hard resetting BGP neighbor $neighbor (ASN $asn)"

	vtysh <<EOF >/dev/null 2>&1
configure terminal
router bgp $asn
neighbor $neighbor shutdown
end
EOF
	sleep 3
	vtysh <<EOF >/dev/null 2>&1
configure terminal
router bgp $asn
no neighbor $neighbor shutdown
end
write memory
EOF
	sleep 3
	log_info "BGP neighbor $neighbor hard reset completed"
}

# Switch to another hub
switch_hub() {	
	local locality="$1"
	local proto_addr nbma_addr tunlink old_tunlink new_tunlink ipaddr old_ipaddr new_ipaddr

	old_ipaddr=$(uci get network.$INTERFACE.ipaddr 2>/dev/null)
	old_tunlink=$(uci get network.$INTERFACE.tunlink 2>/dev/null)

	eval "ipaddr=\$CACHE_${locality}_${PROVIDER_SAFE}_ipaddr"	
	[ -z "$ipaddr" ] && {
		log_info "ipaddr for $locality / $PROVIDER missing, skipping hub switch"
		return 1
	}
	
	if [ "$old_ipaddr" != "$ipaddr" ]; then
		
		eval "proto_addr=\$CACHE_${locality}_${PROVIDER_SAFE}_proto_addr"		
		[ -z "$proto_addr" ] && {
			log_info "proto_addr for $locality / $PROVIDER missing, skipping hub switch"
			return 1
		}
		eval "nbma_addr=\$CACHE_${locality}_${PROVIDER_SAFE}_nbma_addr"
		[ -z "$nbma_addr" ] && {
			log_info "nbma_addr for $locality / $PROVIDER missing, skipping hub switch"
    			return 1
		}
		eval "tunlink=\$CACHE_${locality}_${PROVIDER_SAFE}_tunlink"
		[ -z "$tunlink" ] && {
			log_info "tunlink for $locality / $PROVIDER missing, skipping hub switch"
			return 1
		}

		uci set network.${INTERFACE}.ipaddr="$ipaddr" >/dev/null 2>&1
		uci set network.${INTERFACE}.proto_addr="$proto_addr" >/dev/null 2>&1
		uci set network.${INTERFACE}.nbma_addr="$nbma_addr" >/dev/null 2>&1
		uci set network.${INTERFACE}.tunlink="$tunlink" >/dev/null 2>&1
		uci commit network.${INTERFACE} >/dev/null 2>&1
		log_debug "Interface $INTERFACE ipaddr changed: $old_ipaddr -> $ipaddr"
		log_debug "Interface $INTERFACE tunlink changed: $old_tunlink -> $tunlink"		

		ubus call network reload >/dev/null 2>&1
		sleep 2

		new_ipaddr="$(ubus call network.interface.$INTERFACE status | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)"
		new_tunlink="$(uci get network.$INTERFACE.tunlink)"
	
		if [ "$new_ipaddr" = "$ipaddr" ]; then
			log_debug "DMVPN/NHRP tunnel on interface $INTERFACE ipaddr reconfigured: $old_ipaddr -> $new_ipaddr"
			log_debug "DMVPN/NHRP tunnel on interface $INTERFACE ipaddr reconfigured: $old_tunlink -> $new_tunlink"
		fi
	
		log_debug "Waiting $NETWORK_STABILIZATION_TIMER seconds for network to stabilize..."
		sleep $NETWORK_STABILIZATION_TIMER  # Delay to allow the network to stabilize after configuration changes
	else
		log_debug "No change required: $INTERFACE ipaddr ($old_ipaddr) already equals target ($ipaddr), DMVPN/NHRP hub switch skipped."
	fi
}

# Escalates recovery actions when the health score exceeds the ESCALATION_THRESHOLD
escalate() {
	local state has_locality1 has_locality2 neighbor
	eval "neighbor=\$CACHE_${REGION}_${PROVIDER_SAFE}_proto_addr"

	[ -z "$neighbor" ] && {
		log_info "Neighbor address missing, skipping escalation step"
		return 1
	}

	[ -f "$STATE_FILE" ] || touch "$STATE_FILE"
	[ -s "$STATE_FILE" ] || echo "OK" > "$STATE_FILE"

	state=$(cat "$STATE_FILE" 2>/dev/null || echo "OK")
	log_debug "Escalation triggered. Current state is $state"

	case "$state" in
		OK)
			echo "DEGRADED" > "$STATE_FILE"
			;;
		DEGRADED)
			reset_bgp_neighbor_soft "$neighbor"
			echo "RECOVERY" > "$STATE_FILE"
			;;
		RECOVERY)
			reset_bgp_neighbor"$neighbor"			
			echo "SWITCHING" > "$STATE_FILE"
            		;;
		SWITCHING)
			eval "has_locality1=\$CACHE_${LOCALITY1}_${PROVIDER_SAFE}_operator"
			has_locality1=${has_locality1:-"has't_locality1"}
			eval "has_locality2=\$CACHE_${LOCALITY2}_${PROVIDER_SAFE}_operator"
			has_locality2=${has_locality2:-"has't_locality2"}

			if [ "$has_locality1" = "$has_locality2" ]; then
				REGION=$([ "$REGION" = "$LOCALITY1" ] && echo "$LOCALITY2" || echo "$LOCALITY1") # Switch current region first!
				log_debug "Current state is $state, switching to $REGION DMVPN/NHRP hub"
				switch_hub "$REGION"
			else
				log_debug "Provider $PROVIDER missing in one of localities in $HUBSFILE, DMVPN/NHRP hub switch skipped!"
			fi
			
			log_debug "$CYCLE SWITCHING cycles remained before reboot!"
			
			if [ "$CYCLE" -gt 0 ]; then
				echo "DEGRADED" > "$STATE_FILE"
				CYCLE=$((CYCLE - 1))
			else 
				echo "FORCED_RESTART" > "$STATE_FILE"
				log_debug "No cycles left, escalating to FORCED_RESTART"
			fi
			;;
		FORCED_RESTART)
			log_debug "Current state is $state, rebooting device"
            		reboot
            		;;
	esac

	echo "$(current_time) $((ESCALATION_THRESHOLD - 2))" > "$EVENT_LOG" # Reset event log after escalation to threshold score, uncomment for debug only!
}

# Run necessary checks
run_checks() {
	# Control-plane checks

	if check_bgp_neighbor "$REGION"; then
		log_debug "BGP neighbor $(eval "echo \$CACHE_${REGION}_${PROVIDER_SAFE}_proto_addr") is up"
	else
		add_event 5
		log_info "BGP neighbor $(eval "echo \$CACHE_${REGION}_${PROVIDER_SAFE}_proto_addr") is down, add_event 5"
	fi

	# Data-plane checks

	if check_ping "$REGION"; then
		log_debug "Ping to host $(eval "echo \$CACHE_${REGION}_${PROVIDER_SAFE}_proto_addr") successful"
	else
		add_event 3
		log_info "Ping to host $(eval "echo \$CACHE_${REGION}_${PROVIDER_SAFE}_proto_addr") failed, add_event 3"
	fi
	if check_tcp "$REGION"; then
		log_debug "TCP check to server $(eval "echo \$CACHE_${REGION}_server_addr") successful"
	else
		add_event 2
		log_info "TCP check to server $(eval "echo \$CACHE_${REGION}_server_addr") failed, add_event 2"
	fi

	# Control-plane checks again

	check_bgp_prefix_flap "$REGION"
}

# -----------------------------
# Init
# -----------------------------

log_info "----------------------------------------------------"
log_info " "
log_info "The wd-hub-switcher.sh shell script watchdog started"
log_info " "
log_info "----------------------------------------------------"

PROVIDER_SAFE=$(normalize "$PROVIDER")

[ -f "$STATE_FILE" ] && echo "OK" > "$STATE_FILE" # Reset escalation state file
[ -f "$EVENT_LOG" ] && : > "$EVENT_LOG" # Reset event log file

wait_mobile_is_up $WAIT_FOR_MOBILE_TIMER
log_debug "Current provider is $PROVIDER"

# -----------------------------
# Main loop
# -----------------------------

while true; do
	if [ -f "$HUBSFILE" ] && [ -s "$HUBSFILE" ]; then
		HUBS_JSON=$(cat "$HUBSFILE")

		if ! echo "$HUBS_JSON" | jsonfilter -e '@' >/dev/null 2>&1; then
    			log_info "Hubs JSON invalid, skipping iteration"
    			sleep $LOOP_TIMER
    			continue
		fi

		if ! load_cache >/dev/null 2>&1; then
			sleep $LOOP_TIMER
			continue
		fi

		run_checks

	# Calculate current health score

		[ -s "$EVENT_LOG" ] && log_debug "$(printf 'EVENT_LOG contents:\n%s\n' "$(cat "$EVENT_LOG")")"
		score=$(calculate_score)
		log_debug "Current health score=$score / threshold=$ESCALATION_THRESHOLD, score zero counter=$SCORE_0_COUNTER" 
		log_info "Current region is $REGION. Current state is $(cat "$STATE_FILE" 2>/dev/null || echo "OK")"
		
		# Escalation state must return to OK after the system has stabilized
		if [ "${score:-1}" -eq 0 ]; then
			echo "OK" > "$STATE_FILE"
			SCORE_0_COUNTER=$((SCORE_0_COUNTER + 1))
		else
			SCORE_0_COUNTER=$((SCORE_0_COUNTER - 1))
			[ "$SCORE_0_COUNTER" -lt 0 ] && SCORE_0_COUNTER=0
		fi	
			
		# Trigger escalation if threshold exceeded
		[ "${score:-1}" -ge "$ESCALATION_THRESHOLD" ] && escalate

	# Increase SWITCHING cycles by 1 if more than 100 consecutive events have score=0 (max $MAX_CYCLES_TO_REBOOT)

        	if [ "$SCORE_0_COUNTER" -gt 100 ]; then
                	CYCLE=$((CYCLE + 1))
                	[ "$CYCLE" -gt "$MAX_CYCLES_TO_REBOOT" ] && CYCLE=$MAX_CYCLES_TO_REBOOT
                	log_debug "Event count with score=0 greater than 100, increasing SWITCHING cycles to $CYCLE"
                	SCORE_0_COUNTER=0
        	fi
	else
		log_info "Error in file hubs.json or file not exists, do nothing!"
	fi
	
	sleep $LOOP_TIMER

# -----------------------------
# Schedule some events
# -----------------------------

	# Start log rotate once at 01:00

	if [ $(date +%H) -eq 1 ] && [ $(date +%M) -eq 0 ] && [ "$ROTATED_AT" != "$(date '+%Y-%m-%d')" ]; then
		log_rotate "$LOGFILE" "$MAX_BACKUPS"
		ROTATED_AT="$(date '+%Y-%m-%d')"
		log_info "Log $LOGFILE rotated at $(date '+%Y-%m-%d_%H-%M')"
	fi

	# Start automatic switch to the main region hub once at 02:00

	if [ $(date +%H) -eq 2 ] && [ $(date +%M) -eq 0 ] && [ "$SWITCHED_AT" != "$(date '+%Y-%m-%d')" ]; then
		if [ "$REGION" != "$DEFAULT_REGION" ] && [ "${score:-1}" -eq 0 ]; then
    			log_info "Start switching to default/preferred region $DEFAULT_REGION at $(date '+%Y-%m-%d_%H-%M')"
			REGION="$DEFAULT_REGION"
			switch_hub "$REGION"
			SWITCHED_AT="$(date '+%Y-%m-%d')"
		else
			log_info "Start switching to default/preferred region $DEFAULT_REGION at $(date '+%Y-%m-%d_%H-%M') failed" 
			log_info "Preferred region is already active ($REGION) or current health score=$score not equals to zero"
			SWITCHED_AT="$(date '+%Y-%m-%d')"
		fi
	fi
done
