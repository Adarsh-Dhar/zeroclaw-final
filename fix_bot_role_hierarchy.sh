#!/bin/bash
# Fix bot role hierarchy - move bot role above subscriber role

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
else
    echo "Error: .env file not found"
    exit 1
fi

BOT_ROLE_ID="1533036520716369963"
SUBSCRIBER_ROLE_ID="1531669950819733575"

echo "Current role hierarchy:"
echo "- @everyone: position 0"
echo "- registered: position 1"
echo "- zeroclaw-bot (bot): position 1"
echo "- subscriber: position 2"
echo "- subscription-watcher: position 3"
echo ""

echo "Moving bot role to position 3 (above subscriber)..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X PATCH \
  "https://discord.com/api/v10/guilds/$GUILD_ID/roles" \
  -H "Authorization: Bot $BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "[
    {
      \"id\": \"$BOT_ROLE_ID\",
      \"position\": 3
    }
  ]")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Successfully moved bot role to position 3"
    echo "Response: $BODY"
else
    echo "❌ Error moving role: HTTP $HTTP_CODE"
    echo "Response: $BODY"
    exit 1
fi

echo ""
echo "Verifying new role hierarchy..."
GUILD_ROLES=$(curl -s -X GET \
  "https://discord.com/api/v10/guilds/$GUILD_ID/roles" \
  -H "Authorization: Bot $BOT_TOKEN")

echo "$GUILD_ROLES" | python3 -m json.tool 2>/dev/null || echo "$GUILD_ROLES"
