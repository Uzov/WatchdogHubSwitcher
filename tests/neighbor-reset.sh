#!/bin/sh
asn="65001"
neighbor="10.160.166.1"

vtysh <<EOF
configure terminal
router bgp $asn
neighbor $neighbor shutdown
exit
exit
EOF

sleep 5

vtysh <<EOF
configure terminal
router bgp $asn
no neighbor $neighbor shutdown
end
write memory
EOF
