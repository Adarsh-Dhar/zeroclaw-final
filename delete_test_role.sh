#!/bin/bash
# Delete the test role

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
else
    echo "Error: .env file not found"
    exit 1
fi

TEST_ROLE_ID="1533041808383279235"

echo "Deleting test role..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE \
  "https://discord.com/api/v10/guilds/$GUILD_ID/roles/$TEST_ROLE_ID" \
  -H "Authorization: Bot $BOT_TOKEN")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)

if [ "$HTTP_CODE" = "204" ]; then
    echo "✅ Successfully deleted test role"
else
    echo "❌ Error deleting role: HTTP $HTTP_CODE"
    echo "Response: $RESPONSE"
fi
