# wd-hub-switcher

Watchdog script for **DMVPN/NHRP hub switching** with health scoring, FSM-based escalation, and automatic recovery for OpenWRT-based routers.

---

## Overview

`wd-hub-switcher.sh` continuously monitors:

- Mobile interface status (SIM1 / SIM2 via ubus)
- BGP neighbor state
- BGP prefix stability (flap detection)
- ICMP reachability (ping)
- TCP service availability

Based on a health score system, it performs:

- Soft / hard BGP resets
- Hub switching between regions
- Controlled escalation via finite state machine (FSM)
- Automatic recovery and fallback to default hub

---

## Features

### Event-driven health model
- Sliding window scoring (event log based)
- Weighted failure events

### FSM states

- OK — normal operation
- DEGRADED — soft BGP reset
- RECOVERY — hard BGP reset
- SWITCHING — hub switch
- FORCED_RESTART — reboot device

---

## Architecture

mobile (ubus)
   ↓
cache (hubs.json → jshn)
   ↓
checks:
   ├── BGP neighbor
   ├── BGP prefix flap
   ├── ICMP ping
   └── TCP check
   ↓
event log (weighted)
   ↓
health score
   ↓
FSM escalation
   ↓
actions:
   ├── soft reset BGP
   ├── hard reset BGP
   ├── switch hub
   └── reboot

---

## Configuration

/etc/hubs.json

Example:

{
  "Niznekamsk": {
    "Beeline": {
      "operator": "Beeline",
      "ipaddr": "10.10.10.1",
      "proto_addr": "10.10.10.2",
      "nbma_addr": "10.10.10.3",
      "tunlink": "mgre1"
    }
  }
}

---

## Provider normalization

"MTS RUS" → MTS_RUS

normalize():
tr -c 'a-zA-Z0-9' '_'

---

## UCI usage

Correct:
uci get network.mgre1.ipaddr

---

## Reset modes

Soft reset:
clear ip bgp <neighbor> soft

Hard reset:
neighbor shutdown / no shutdown

---

## Dependencies

- ubus
- jsonfilter
- jshn
- vtysh
- nc

---

## Installation

chmod +x wd-hub-switcher.sh
/etc/init.d/wd-hub-switcher start

