#!/bin/bash

# Subscription Check Script
# Checks payment status for subscribers using reference keys and manages grace periods

set -e

PROXY_URL="https://solana-rpc-proxy.dharadarsh0.workers.dev"
MERCHANT_WALLET="pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak"
USDC_MINT="4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"
SUBSCRIBERS_FILE="/Users/adarsh/.zeroclaw/subscribers.json"
CHANNEL_ID="1531347878906302487"
GUILD_ID="1531347878906302484"
SUBSCRIBER_ROLE_ID="1531669950819733575"
GRACE_PERIOD_DAYS=3
RENEWAL_REMINDER_DAYS=5

# Create subscribers file if it doesn't exist
touch "$SUBSCRIBERS_FILE"

echo "Starting subscription check..."

python3 - << 'PYTHON_SCRIPT'
import json
import sys
import urllib.parse
import subprocess
import os
from datetime import datetime, timezone, timedelta

PROXY_URL = "https://solana-rpc-proxy.dharadarsh0.workers.dev"
MERCHANT_WALLET = "pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak"
USDC_MINT = "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU"
SUBSCRIBERS_FILE = "/Users/adarsh/.zeroclaw/subscribers.json"
CHANNEL_ID = "1531347878906302487"
GUILD_ID = "1531347878906302484"
SUBSCRIBER_ROLE_ID = "1531669950819733575"
GRACE_PERIOD_DAYS = 3

def load_subscribers():
    try:
        with open(SUBSCRIBERS_FILE, 'r') as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def save_subscribers(subscribers):
    with open(SUBSCRIBERS_FILE, 'w') as f:
        json.dump(subscribers, f, indent=2)

def post_discord_message(content):
    encoded = urllib.parse.quote(content)
    url = f"{PROXY_URL}/discord/message?channel_id={CHANNEL_ID}&content={encoded}"
    subprocess.run(['curl', '-s', url], capture_output=True)

def check_discord_role(user_id):
    url = f"{PROXY_URL}/discord/guilds/{GUILD_ID}/members/{user_id}"
    result = subprocess.run(['curl', '-s', url], capture_output=True, text=True)
    if result.returncode != 0:
        return None
    try:
        member_data = json.loads(result.stdout)
        return SUBSCRIBER_ROLE_ID in member_data.get('roles', [])
    except:
        return None

def send_discord_dm(user_id, content):
    encoded = urllib.parse.quote(content)
    url = f"{PROXY_URL}/discord/dm?user_id={user_id}&content={encoded}"
    subprocess.run(['curl', '-s', url], capture_output=True)

def generate_reference_key():
    url = f"{PROXY_URL}/keygen"
    result = subprocess.run(['curl', '-s', url], capture_output=True, text=True)
    if result.returncode == 0:
        try:
            data = json.loads(result.stdout)
            return data.get('reference_key')
        except:
            return None
    return None

def get_signatures_for_reference(reference_key):
    url = f"{PROXY_URL}/?method=getSignaturesForAddress&wallet={reference_key}&limit=100"
    result = subprocess.run(['curl', '-s', url], capture_output=True, text=True)
    if result.returncode != 0:
        return None
    try:
        data = json.loads(result.stdout)
        return data.get('result', [])
    except:
        return None

def get_transaction(signature):
    url = f"{PROXY_URL}/?method=getTransaction&signature={signature}&encoding=jsonParsed"
    result = subprocess.run(['curl', '-s', url], capture_output=True, text=True)
    if result.returncode != 0:
        return None
    try:
        data = json.loads(result.stdout)
        return data.get('result')
    except:
        return None

def check_payment(record):
    reference_key = record.get('reference_key')
    if not reference_key:
        return {'status': 'check_failed', 'expires_at': None, 'highest_amount': None}

    signatures = get_signatures_for_reference(reference_key)
    if not signatures:
        return {'status': 'lapsed', 'expires_at': None, 'highest_amount': None}

    expected_amount_usdc = record.get('expected_amount_usdc', 0.1)
    expected_amount_raw = int(expected_amount_usdc * 1_000_000)
    period_days = record.get('period_days', 30)
    subscribed_at = record.get('subscribed_at')

    if subscribed_at:
        try:
            subscribed_at_unix = int(datetime.fromisoformat(subscribed_at.replace('Z', '+00:00')).timestamp())
        except:
            subscribed_at_unix = 0
    else:
        subscribed_at_unix = 0

    current_time = int(datetime.now(timezone.utc).timestamp())
    window_end = subscribed_at_unix + (period_days * 86400) if subscribed_at_unix > 0 else current_time + (period_days * 86400)

    highest_amount = 0
    qualifying_tx = None

    for sig_info in signatures:
        signature = sig_info.get('signature')
        if not signature:
            continue

        tx = get_transaction(signature)
        if not tx:
            continue

        block_time = tx.get('blockTime')
        if block_time is None:
            continue

        # Check subscription window
        if subscribed_at_unix > 0 and (block_time < subscribed_at_unix or block_time > window_end):
            continue

        # Check for USDC transfer to merchant
        meta = tx.get('meta', {})
        message = tx.get('transaction', {}).get('message', {})
        instructions = message.get('instructions', [])

        for instruction in instructions:
            parsed = instruction.get('parsed', {})
            if parsed.get('type') not in ['transfer', 'transferChecked']:
                continue

            info = parsed.get('info', {})
            destination = info.get('destination') or info.get('account')
            if not destination:
                continue

            # Check if destination is merchant wallet or ATA owned by merchant
            if destination != MERCHANT_WALLET:
                # Check post token balances for ATA
                post_balances = meta.get('postTokenBalances', [])
                found_merchant = False
                for balance in post_balances:
                    if balance.get('owner') == MERCHANT_WALLET:
                        found_merchant = True
                        break
                if not found_merchant:
                    continue

            # Check USDC mint
            if parsed.get('type') == 'transferChecked':
                mint = info.get('mint')
                if mint != USDC_MINT:
                    continue
            else:
                # For plain transfer, check mint from postTokenBalances
                post_balances = meta.get('postTokenBalances', [])
                found_usdc = False
                for balance in post_balances:
                    if balance.get('mint') == USDC_MINT:
                        found_usdc = True
                        break
                if not found_usdc:
                    continue

            # Check amount
            amount_str = info.get('tokenAmount', {}).get('amount') or info.get('amount')
            if amount_str:
                try:
                    amount = int(amount_str)
                    if amount > highest_amount:
                        highest_amount = amount
                except:
                    pass

            # Check if this transaction qualifies
            if highest_amount >= expected_amount_raw:
                if qualifying_tx is None or block_time > qualifying_tx.get('blockTime', 0):
                    qualifying_tx = {'blockTime': block_time, 'signature': signature}

    if qualifying_tx:
        expires_at = datetime.fromtimestamp(qualifying_tx['blockTime'] + (period_days * 86400), timezone.utc).isoformat()
        return {'status': 'active', 'expires_at': expires_at, 'highest_amount': highest_amount / 1_000_000}
    elif highest_amount > 0:
        return {'status': 'lapsed', 'expires_at': None, 'highest_amount': highest_amount / 1_000_000}
    else:
        return {'status': 'lapsed', 'expires_at': None, 'highest_amount': None}

def main():
    subscribers = load_subscribers()
    current_time = datetime.now(timezone.utc)
    current_time_iso = current_time.isoformat()
    summary = []

    for user_id, record in subscribers.items():
        if not record.get('reference_key'):
            continue

        username = record.get('discord_username', user_id)
        print(f"Checking payment for {username}...")

        # Check for renewal window first (before payment check)
        expires_at = record.get('expires_at')
        if expires_at and record.get('status') == 'active':
            try:
                expiry = datetime.fromisoformat(expires_at.replace('Z', '+00:00'))
                time_until_expiry = (expiry - current_time).total_seconds()
                renewal_window = RENEWAL_REMINDER_DAYS * 86400

                # Check if within renewal window and haven't sent reminder for this expiry
                if 0 < time_until_expiry <= renewal_window:
                    last_reminder_expiry = record.get('renewal_dm_sent_for_expiry')
                    if last_reminder_expiry != expires_at:
                        # Generate new reference key for renewal
                        new_ref_key = generate_reference_key()
                        if new_ref_key:
                            record['reference_key'] = new_ref_key
                            record['renewal_dm_sent_for_expiry'] = expires_at

                            # Build renewal Solana Pay URL
                            amount = record.get('expected_amount_usdc', 0.1)
                            renewal_url = f"solana:{MERCHANT_WALLET}?amount={amount}&spl-token={USDC_MINT}&reference={new_ref_key}&label=ZeroClaw+Subscription&memo={user_id}"

                            # Send renewal DM
                            renewal_message = f"🔔 ZeroClaw Subscription Renewal\n\nYour {record.get('tier', 'standard')} subscription expires on {expires_at}.\n\nRenew now:\n{renewal_url}\n\nAmount: {amount} USDC / {record.get('period_days', 30)} days"
                            send_discord_dm(user_id, renewal_message)
                            summary.append(f"@{username} - Renewal reminder sent")
                            print(f"Sent renewal reminder to {username}")
                        else:
                            summary.append(f"@{username} - Failed to generate renewal key")
            except Exception as e:
                print(f"Error checking renewal window for {username}: {e}")

        payment_result = check_payment(record)
        old_status = record.get('status')
        record['status'] = payment_result['status']

        if payment_result['status'] == 'active':
            record['subscribed_at'] = current_time_iso
            record['expires_at'] = payment_result['expires_at']
            record['grace_started_at'] = None

            # Check if user has role
            has_role = check_discord_role(user_id)
            if has_role is False:
                # Grant role
                url = f"{PROXY_URL}/discord/guilds/{GUILD_ID}/members/{user_id}/roles/{SUBSCRIBER_ROLE_ID}"
                subprocess.run(['curl', '-s', url], capture_output=True)
                summary.append(f"@{username} - Active - Role granted")
            elif has_role is True:
                if f"@{username} - Renewal reminder sent" not in summary:
                    summary.append(f"@{username} - Active - Role unchanged")
            else:
                summary.append(f"@{username} - Active - Role check failed")

        elif payment_result['status'] == 'lapsed':
            if record.get('grace_started_at') is None:
                # Start grace period
                record['grace_started_at'] = current_time_iso
                summary.append(f"@{username} - Lapsed - Grace period started")
            else:
                # Check if grace period has expired
                try:
                    grace_start = datetime.fromisoformat(record['grace_started_at'].replace('Z', '+00:00'))
                    grace_expiry = grace_start + timedelta(days=GRACE_PERIOD_DAYS)
                    if current_time > grace_expiry:
                        # Grace period expired
                        summary.append(f"@{username} - Expired - Grace period ended")
                        post_discord_message(f"⚠️ ROLE REMOVAL PROPOSAL: @{username}'s grace period has ended. Admin approval required to remove Subscriber_Role.")
                    else:
                        # Still in grace period
                        summary.append(f"@{username} - Grace - Retaining role")
                except:
                    summary.append(f"@{username} - Lapsed - Grace check failed")

        elif payment_result['status'] == 'check_failed':
            summary.append(f"@{username} - Check failed")

        # Save updated record
        subscribers[user_id] = record

    save_subscribers(subscribers)

    # Post summary
    if summary:
        summary_text = "📊 Subscription Check Summary\n" + "\n".join(summary)
        post_discord_message(summary_text)
        print("Summary posted to Discord")

if __name__ == "__main__":
    main()
PYTHON_SCRIPT

echo "Subscription check completed."
