#!/usr/bin/env python3
"""One-shot script: seed subscriber record for 1531681016249319576 into KV."""
import json
import urllib.request
from datetime import datetime, timezone

PROXY = "https://solana-rpc-proxy.dharadarsh0.workers.dev"

BLOCK_TIME  = 1785617148          # blockTime of tx 483mvGz...
PERIOD_DAYS = 30
EXPIRES_TS  = BLOCK_TIME + PERIOD_DAYS * 86400

def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")

record = {
    "discord_user_id":           "1531681016249319576",
    "discord_username":          "adrs0890",
    "wallet_address":            "EYSHit3n1e6qQWKG6L4g34SNoG6P7R9U7y6MGREBLebB",
    "tier":                      "standard",
    "expected_amount_sol":       0.001,
    "period_days":               PERIOD_DAYS,
    "subscribed_at":             iso(BLOCK_TIME),
    "expires_at":                iso(EXPIRES_TS),
    "grace_started_at":          None,
    "reference_key":             "4h1vEsc4isYbZHTMA9NwRcpaQynhxfcW1JAuBTHnsvTp",
    "status":                    "active",
    "last_known_status":         None,
    "renewal_dm_sent_for_expiry": None,
    "role_granted_at":           None,
    "pay_url":                   f"{PROXY}/pay?tier=standard&discord_user_id=1531681016249319576&reference=4h1vEsc4isYbZHTMA9NwRcpaQynhxfcW1JAuBTHnsvTp",
}

print("Writing record:")
print(f"  subscribed_at : {record['subscribed_at']}")
print(f"  expires_at    : {record['expires_at']}")
print(f"  status        : {record['status']}")

data = json.dumps(record).encode()
req = urllib.request.Request(
    f"{PROXY}/storage/subscriber/1531681016249319576",
    data=data,
    headers={"Content-Type": "application/json"},
    method="PUT",
)
with urllib.request.urlopen(req, timeout=15) as resp:
    print(f"HTTP {resp.status}: {resp.read().decode()}")

# Verify round-trip
req2 = urllib.request.Request(f"{PROXY}/storage/subscriber/1531681016249319576")
with urllib.request.urlopen(req2, timeout=15) as resp2:
    back = json.loads(resp2.read().decode())
    print("Round-trip check:")
    print(f"  status     : {back.get('status')}")
    print(f"  subscribed : {back.get('subscribed_at')}")
    print(f"  expires    : {back.get('expires_at')}")
    print(f"  wallet     : {back.get('wallet_address')}")
