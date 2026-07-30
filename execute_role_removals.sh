#!/bin/bash

# Role Removal Execution Script
# This script executes approved role removals for subscribers who have passed their grace period
# Usage: ./execute_role_removals.sh <discord_user_id> <guild_id> <role_id>

set -e

PROXY_URL="https://solana-rpc-proxy.dharadarsh0.workers.dev"

if [ $# -ne 3 ]; then
    echo "Usage: $0 <discord_user_id> <guild_id> <role_id>"
    echo "Example: $0 1531681016249319576 1531347878906302484 1531669950819733575"
    exit 1
fi

DISCORD_USER_ID="$1"
GUILD_ID="$2"
ROLE_ID="$3"

echo "Executing role removal for user $DISCORD_USER_ID..."
echo "Guild: $GUILD_ID"
echo "Role: $ROLE_ID"

# Call the proxy DELETE endpoint
RESPONSE=$(curl -s -X DELETE \
  "$PROXY_URL/discord/guilds/$GUILD_ID/members/$DISCORD_USER_ID/roles/$ROLE_ID" \
  -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [ "$HTTP_CODE" = "204" ]; then
    echo "✅ Successfully removed role from user $DISCORD_USER_ID"
    echo "HTTP Status: $HTTP_CODE"
else
    echo "❌ Failed to remove role"
    echo "HTTP Status: $HTTP_CODE"
    echo "Response: $BODY"
    exit 1
fi
