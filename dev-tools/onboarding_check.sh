#!/bin/bash

# Onboarding Check Script
# Polls Discord channel for subscribe commands and generates Solana Pay URLs

set -e

CONFIG_DIR="/Users/adarsh/.zeroclaw"
PROXY_URL="https://solana-rpc-proxy.dharadarsh0.workers.dev"
CHANNEL_ID="1531347878906302487"
MERCHANT_WALLET="pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak"
USDC_MINT="4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"
PROCESSED_FILE="/tmp/processed_messages.txt"

# Get recent messages from Discord
echo "Fetching recent messages from Discord..."
curl -s "${PROXY_URL}/discord/channels/${CHANNEL_ID}/messages?limit=20" > /tmp/discord_messages.json

# Check if we got valid JSON
if ! python3 -c "import json; json.load(open('/tmp/discord_messages.json'))" 2>/dev/null; then
    echo "Error: Failed to fetch valid JSON from Discord API"
    cat /tmp/discord_messages.json
    exit 1
fi

# Create processed file if it doesn't exist
touch "$PROCESSED_FILE"

# Extract subscribe commands (non-bot messages)
python3 - << 'PYTHON_SCRIPT'
import json
import sys
import urllib.parse
import subprocess
import os

MERCHANT_WALLET = "pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak"
USDC_MINT = "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"
PROCESSED_FILE = "/tmp/processed_messages.txt"
SUBSCRIBERS_FILE = "/Users/adarsh/.zeroclaw/subscribers.json"
CONFIG_DIR = "/Users/adarsh/.zeroclaw"

# Tier configurations
TIERS = {
    "standard": {"amount_usdc": 10.0, "period_days": 30},
    "premium": {"amount_usdc": 25.0, "period_days": 30}
}

def load_processed_messages():
    try:
        with open(PROCESSED_FILE, 'r') as f:
            return set(line.strip() for line in f if line.strip())
    except FileNotFoundError:
        return set()

def save_processed_message(message_id):
    with open(PROCESSED_FILE, 'a') as f:
        f.write(f"{message_id}\n")

def load_subscribers():
    try:
        with open(SUBSCRIBERS_FILE, 'r') as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def save_subscribers(subscribers):
    with open(SUBSCRIBERS_FILE, 'w') as f:
        json.dump(subscribers, f, indent=2)

def get_subscriber_record(user_id, username, tier):
    subscribers = load_subscribers()
    if user_id in subscribers:
        return subscribers[user_id]

    # Create new subscriber record
    tier_config = TIERS.get(tier, TIERS["standard"])
    record = {
        "discord_user_id": user_id,
        "discord_username": username,
        "tier": tier,
        "expected_amount_usdc": tier_config["amount_usdc"],
        "period_days": tier_config["period_days"],
        "subscribed_at": None,
        "expires_at": None,
        "grace_started_at": None,
        "reference_key": None,
        "status": "pending_payment",
        "last_known_status": None,
        "renewal_dm_sent_for_expiry": None
    }
    subscribers[user_id] = record
    save_subscribers(subscribers)
    return record

def generate_reference_key():
    result = subprocess.run(['curl', '-s', 'https://solana-rpc-proxy.dharadarsh0.workers.dev/keygen'],
                          capture_output=True, text=True)
    if result.returncode == 0:
        data = json.loads(result.stdout)
        return data.get('reference_key')
    return None

def post_discord_message(content):
    encoded = urllib.parse.quote(content)
    url = f"https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/message?channel_id=1531347878906302487&content={encoded}"
    subprocess.run(['curl', '-s', url], capture_output=True)

def process_subscribe(user_id, username, tier):
    # Get or create subscriber record with tier configuration
    record = get_subscriber_record(user_id, username, tier)
    tier_config = TIERS.get(tier, TIERS["standard"])

    # Generate new reference key for this payment request
    ref_key = generate_reference_key()
    if not ref_key:
        print("Failed to generate reference key")
        return

    # Update record with new reference key
    record["reference_key"] = ref_key
    subscribers = load_subscribers()
    subscribers[user_id] = record
    save_subscribers(subscribers)

    # Build Solana Pay URL with tier-specific amount
    amount = tier_config["amount_usdc"]
    solana_url = f"solana:{MERCHANT_WALLET}?amount={amount}&spl-token={USDC_MINT}&reference={ref_key}&label=ZeroClaw+Subscription&memo={user_id}"

    # Build QR URL using QR Server API
    qr_url = f"https://api.qrserver.com/v1/create-qr-code/?size=300x300&data={urllib.parse.quote(solana_url)}"

    # Post message with proper Discord mention format and tier info
    message = f"<@{user_id}> — ZeroClaw {tier} subscription ({amount} USDC / {tier_config['period_days']} days)\nPay here: {solana_url}\nQR: {qr_url}"
    post_discord_message(message)
    print(f"Posted onboarding message for {username} (tier: {tier})")

try:
    with open('/tmp/discord_messages.json', 'r') as f:
        messages = json.load(f)

    processed = load_processed_messages()

    for msg in messages:
        # Skip bot messages
        if msg.get('author', {}).get('bot', False):
            continue

        # Skip already processed messages
        message_id = msg.get('id')
        if message_id in processed:
            continue

        content = msg.get('content', '').lower().strip()

        # Check for subscribe command
        if content == 'subscribe' or content.startswith('subscribe '):
            user_id = msg['author']['id']
            username = msg['author']['username']

            # Parse tier
            parts = content.split()
            tier = parts[1] if len(parts) > 1 else 'standard'

            # Only process standard or premium
            if tier in ['standard', 'premium']:
                print(f"Processing subscribe command from {username} (tier: {tier})")
                process_subscribe(user_id, username, tier)
                save_processed_message(message_id)
            else:
                print(f"Invalid tier '{tier}' from {username}, defaulting to standard")
                process_subscribe(user_id, username, 'standard')
                save_processed_message(message_id)
                
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON_SCRIPT
