#!/bin/sh

. /usr/share/libubox/jshn.sh

HUBSFILE="/etc/hubs.json"       # Main configuration file

# Parse HUBS_JSON, validate IPs, and cache parameters using jshn

load_cache() {
        json_load "$HUBS_JSON"

	json_get_keys localities

        for locality in $localities; do
        json_select "$locality"
	json_get_keys keys
                for provider in $keys; do
                        json_select "$provider"
			if [ "$provider" != "data" ]; then
                        	json_get_var ipaddr ipaddr
                        	json_get_var proto_addr proto_addr
                        	json_get_var nbma_addr nbma_addr
		
				# Store into cache
                        	eval "CACHE_${locality}_${provider}_ipaddr=\"$ipaddr\""
				eval "echo \$CACHE_${locality}_${provider}_ipaddr"
                        	eval "CACHE_${locality}_${provider}_proto_addr=\"$proto_addr\""
				eval "echo \$CACHE_${locality}_${provider}_proto_addr"
                        	eval "CACHE_${locality}_${provider}_nbma_addr=\"$nbma_addr\""
				eval "echo \$CACHE_${locality}_${provider}_nbma_addr"
			else
				json_get_var server_addr server_addr
				json_get_var prefix prefix
				json_get_var tcp_port tcp_port
				
				# Store into cache
                                eval "CACHE_${locality}_server_addr=\"$server_addr\""
				eval "echo \$CACHE_${locality}_server_addr"
                                eval "CACHE_${locality}_prefix=\"$prefix\""
				eval "echo \$CACHE_${locality}_prefix"
                                eval "CACHE_${locality}_tcp_port=\"$tcp_port\""
				eval "echo \$CACHE_${locality}_tcp_port"
			fi

                	json_select ".."
                done

        json_select ".."
        done

}

if [ -f "$HUBSFILE" ] && [ -s "$HUBSFILE" ]; then
                HUBS_JSON=$(cat "$HUBSFILE")
fi

load_cache
