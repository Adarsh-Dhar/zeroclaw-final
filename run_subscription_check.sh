#!/bin/bash
# ~/.zeroclaw/run_subscription_check.sh
# Wrapper script to inject wallet roster into ZeroClaw prompt at runtime
# This sidesteps ZeroClaw's broken file-reading layer by reading the roster
# at the shell level and injecting it directly into the model's prompt.

ROSTER=$(cat ~/.zeroclaw/wallet_mapping.json)

/opt/homebrew/bin/zeroclaw agent -a test_agent -m "Use the check-payment skill. Check payment status for every wallet in the following roster JSON. For each entry, use the exact wallet address and exact discord_user_id given — do not modify, guess, or invent any address or ID under any circumstances. If Discord returns an error for a user ID, report that explicitly rather than omitting it. Roster: $ROSTER"
