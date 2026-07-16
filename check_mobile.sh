#!/bin/sh

STATUS=$(ubus call network.interface.sim1 status 2>/dev/null)
L3_DEVICE=$(echo "$STATUS" | jsonfilter -e '@.l3_device')
OPERATOR=$(echo "$STATUS" | jsonfilter -e '@.data.info.operator')
MODE=$(echo "$STATUS" | jsonfilter -e '@.data.info.mode')
RSSI=$(echo "$STATUS" | jsonfilter -e '@.data.info.rssi')
IP=$(echo "$STATUS" | jsonfilter -e '@["ipv4-address"][0].address')

cat <<EOF
{  
	"l3_device": "$L3_DEVICE",
	"operator": "$OPERATOR",  
	"mode": "$MODE",  
	"rssi": $RSSI,  
	"ip": "$IP"
}
EOF
