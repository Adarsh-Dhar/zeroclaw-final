#!/bin/bash
# Test script to add and remove Discord roles using proxy endpoint

PROXY_URL="https://solana-rpc-proxy.dharadarsh0.workers.dev"
GUILD_ID="1531347878906302484"
# Using "subscriber" role as per the skills
ROLE_ID="1531669950819733575"

if [ -z "$1" ]; then
    echo "Usage: ./test_discord_role.sh <discord_user_id>"
    echo "Example: ./test_discord_role.sh 123456789012345678"
    exit 1
fi

USER_ID="$1"

echo "============================================================"
echo "Testing role management for user: $USER_ID"
echo "Guild ID: $GUILD_ID"
echo "Role ID: $ROLE_ID"
echo "============================================================"
echo ""

# Step 1: Check current roles
echo "Step 1: Checking current roles..."
CURRENT_ROLES=$(curl -s -X GET \
  "$PROXY_URL/discord/guilds/$GUILD_ID/members/$USER_ID")

if echo "$CURRENT_ROLES" | grep -q "code"; then
    echo "❌ Error fetching member: $CURRENT_ROLES"
    exit 1
fi

echo "Current member data: $CURRENT_ROLES"
HAS_ROLE=$(echo "$CURRENT_ROLES" | grep -o "\"roles\":\[" | wc -l)
echo "User data retrieved successfully"
echo ""

# Check if user already has the role
if echo "$CURRENT_ROLES" | grep -q "$ROLE_ID"; then
    echo "User already has the role. Testing removal first, then addition."
    
    # Step 2: Remove role first
    echo "Step 2: Removing role..."
    REMOVE_RESPONSE=$(curl -s -w "\n%{http_code}" -X GET \
      "$PROXY_URL/discord/guilds/$GUILD_ID/members/$USER_ID/roles/$ROLE_ID?method=DELETE")

    HTTP_CODE=$(echo "$REMOVE_RESPONSE" | tail -n1)
    if [ "$HTTP_CODE" = "204" ]; then
        echo "✅ Successfully removed role $ROLE_ID from user $USER_ID"
    else
        echo "❌ Error removing role: HTTP $HTTP_CODE"
        echo "Response: $REMOVE_RESPONSE"
        exit 1
    fi
    echo ""

    # Step 3: Verify role was removed
    echo "Step 3: Verifying role was removed..."
    VERIFY_REMOVE=$(curl -s -X GET \
      "$PROXY_URL/discord/guilds/$GUILD_ID/members/$USER_ID")

    if echo "$VERIFY_REMOVE" | grep -q "$ROLE_ID"; then
        echo "❌ Role removal failed verification"
        echo "Member data: $VERIFY_REMOVE"
        exit 1
    else
        echo "✅ Role successfully removed and verified"
    fi
    echo ""

    # Step 4: Add role back
    echo "Step 4: Adding role back..."
    ADD_RESPONSE=$(curl -s -w "\n%{http_code}" -X GET \
      "$PROXY_URL/discord/guilds/$GUILD_ID/members/$USER_ID/roles/$ROLE_ID?method=PUT")

    HTTP_CODE=$(echo "$ADD_RESPONSE" | tail -n1)
    if [ "$HTTP_CODE" = "204" ]; then
        echo "✅ Successfully added role $ROLE_ID to user $USER_ID"
    else
        echo "❌ Error adding role: HTTP $HTTP_CODE"
        echo "Response: $ADD_RESPONSE"
        exit 1
    fi
    echo ""

    # Step 5: Verify role was added back
    echo "Step 5: Verifying role was added back..."
    VERIFY_ADD=$(curl -s -X GET \
      "$PROXY_URL/discord/guilds/$GUILD_ID/members/$USER_ID")

    if echo "$VERIFY_ADD" | grep -q "$ROLE_ID"; then
        echo "✅ Role successfully added and verified"
    else
        echo "❌ Role addition failed verification"
        echo "Member data: $VERIFY_ADD"
        exit 1
    fi
    echo ""
else
    echo "User does not have the role. Testing addition first, then removal."
    
    # Step 2: Add role
    echo "Step 2: Adding role..."
    ADD_RESPONSE=$(curl -s -w "\n%{http_code}" -X GET \
      "$PROXY_URL/discord/guilds/$GUILD_ID/members/$USER_ID/roles/$ROLE_ID?method=PUT")

    HTTP_CODE=$(echo "$ADD_RESPONSE" | tail -n1)
    if [ "$HTTP_CODE" = "204" ]; then
        echo "✅ Successfully added role $ROLE_ID to user $USER_ID"
    else
        echo "❌ Error adding role: HTTP $HTTP_CODE"
        echo "Response: $ADD_RESPONSE"
        exit 1
    fi
    echo ""

    # Step 3: Verify role was added
    echo "Step 3: Verifying role was added..."
    VERIFY_ADD=$(curl -s -X GET \
      "$PROXY_URL/discord/guilds/$GUILD_ID/members/$USER_ID")

    if echo "$VERIFY_ADD" | grep -q "$ROLE_ID"; then
        echo "✅ Role successfully added and verified"
    else
        echo "❌ Role addition failed verification"
        echo "Member data: $VERIFY_ADD"
        exit 1
    fi
    echo ""

    # Step 4: Remove role
    echo "Step 4: Removing role..."
    REMOVE_RESPONSE=$(curl -s -w "\n%{http_code}" -X GET \
      "$PROXY_URL/discord/guilds/$GUILD_ID/members/$USER_ID/roles/$ROLE_ID?method=DELETE")

    HTTP_CODE=$(echo "$REMOVE_RESPONSE" | tail -n1)
    if [ "$HTTP_CODE" = "204" ]; then
        echo "✅ Successfully removed role $ROLE_ID from user $USER_ID"
    else
        echo "❌ Error removing role: HTTP $HTTP_CODE"
        echo "Response: $REMOVE_RESPONSE"
        exit 1
    fi
    echo ""

    # Step 5: Verify role was removed
    echo "Step 5: Verifying role was removed..."
    VERIFY_REMOVE=$(curl -s -X GET \
      "$PROXY_URL/discord/guilds/$GUILD_ID/members/$USER_ID")

    if echo "$VERIFY_REMOVE" | grep -q "$ROLE_ID"; then
        echo "❌ Role removal failed verification"
        echo "Member data: $VERIFY_REMOVE"
        exit 1
    else
        echo "✅ Role successfully removed and verified"
    fi
    echo ""
fi

echo "============================================================"
echo "✅ All tests passed successfully!"
echo "============================================================"
