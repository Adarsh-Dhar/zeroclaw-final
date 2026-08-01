#!/bin/bash
# Create a test role below the bot's role

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
else
    echo "Error: .env file not found"
    exit 1
fi

echo "Creating a test role at position 0 (below bot)..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  "https://discord.com/api/v10/guilds/$GUILD_ID/roles" \
  -H "Authorization: Bot $BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "test-role",
    "permissions": "0",
    "color": 0,
    "hoist": false,
    "mentionable": false
  }')

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Successfully created test role"
    echo "Response: $BODY"
    TEST_ROLE_ID=$(echo "$BODY" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4)
    echo "Test Role ID: $TEST_ROLE_ID"
    echo ""
    echo "Now updating test script to use this role..."
    sed -i '' "s/ROLE_ID=\"[^\"]*\"/ROLE_ID=\"$TEST_ROLE_ID\"/" test_discord_role.sh
    echo "✅ Updated test script with new role ID"
else
    echo "❌ Error creating role: HTTP $HTTP_CODE"
    echo "Response: $BODY"
    exit 1
fi
