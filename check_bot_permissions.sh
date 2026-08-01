#!/bin/bash
# Check bot permissions and roles

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
else
    echo "Error: .env file not found"
    exit 1
fi

echo "Checking bot information..."
BOT_INFO=$(curl -s -X GET \
  "https://discord.com/api/v10/users/@me" \
  -H "Authorization: Bot $BOT_TOKEN")

echo "Bot Info: $BOT_INFO"
echo ""

echo "Checking bot's member in guild..."
BOT_MEMBER=$(curl -s -X GET \
  "https://discord.com/api/v10/guilds/$GUILD_ID/members/@me" \
  -H "Authorization: Bot $BOT_TOKEN")

echo "Bot Member Info: $BOT_MEMBER"
echo ""

echo "Checking guild roles..."
GUILD_ROLES=$(curl -s -X GET \
  "https://discord.com/api/v10/guilds/$GUILD_ID/roles" \
  -H "Authorization: Bot $BOT_TOKEN")

echo "Guild Roles: $GUILD_ROLES"
