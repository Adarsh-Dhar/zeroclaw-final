# ZeroClaw Subscription Gatekeeper

A Solana-based subscription management system that automatically checks USDC payments and manages Discord subscriber roles based on on-chain payment verification.

## Overview

This system uses ZeroClaw agents to periodically check Solana blockchain for USDC payments from subscriber wallets to a merchant wallet. Based on payment status, it automatically grants subscriber roles to users with verified payments and proposes role removal for lapsed subscribers (requiring admin approval). The system only trusts on-chain data for access decisions, providing a secure, automated subscription management solution.

## Prerequisites

- **ZeroClaw** - Installed and configured (see [ZeroClaw installation](https://github.com/zeroclaw-labs/zeroclaw))
- **Discord Bot** - Created with appropriate permissions
- **Solana RPC Endpoint** - Public or private RPC URL for blockchain queries
- **LLM Provider** - API key for Gemini, Anthropic, or OpenAI (configured in ZeroClaw)
- **jq** - JSON processor for configuration parsing

## Quick Start

### 1. Discord Bot Setup

1. **Create Discord Application:**
   - Go to https://discord.com/developers/applications
   - Create a new application
   - Add a bot user under the Bot tab
   - Copy the bot token

2. **Configure Bot Permissions:**
   - Go to OAuth2 → URL Generator
   - Select scope: `bot`
   - Select permissions: `Send Messages`, `Read Message History`, `View Channel`, `Manage Roles`
   - Generate the URL and invite the bot to your server

3. **Role Hierarchy Setup (Critical):**
   - Go to Server Settings → Roles
   - Create a "Subscriber" role
   - **Important:** Drag the bot's role above the subscriber role in the hierarchy
   - Copy the subscriber role ID (enable Developer Mode, right-click role → Copy ID)

### 2. Configuration Setup

1. **Edit `~/.zeroclaw/config.toml`:**

```toml
[solana]
rpc_url = "https://api.mainnet-beta.solana.com"  # or your private RPC

[channels.discord.test_discord]
enabled = true
bot_token = "YOUR_BOT_TOKEN"  # from Discord Developer Portal
channel_id = "YOUR_CHANNEL_ID"  # target channel for notifications
server_id = "YOUR_SERVER_ID"  # your Discord server ID
subscriber_role_id = "YOUR_SUBSCRIBER_ROLE_ID"  # from Discord role settings
```

2. **Create wallet mapping file `~/.zeroclaw/wallet_mapping.json`:**

```json
{
  "WALLET_ADDRESS_1": {
    "discord_user_id": "DISCORD_USER_ID_1",
    "discord_username": "username1",
    "status": "lapsed",
    "grace_started_at": null
  },
  "WALLET_ADDRESS_2": {
    "discord_user_id": "DISCORD_USER_ID_2", 
    "discord_username": "username2",
    "status": "active",
    "grace_started_at": null
  }
}
```

### 3. Skill Installation

The payment checking skill is located at:
```
~/.zeroclaw/shared/skills/default/check-payment/SKILL.md
```

This skill:
- Queries Solana RPC for USDC transactions
- Checks payment status within 30-day window
- Determines Discord role actions based on payment status
- Returns formatted results for role management

### 4. SOP Configuration

The subscription check SOP is located at:
```
~/.zeroclaw/agents/test_agent/workspace/sops/subscription_check/
```

Files:
- `SOP.toml` - Trigger configuration (manual trigger, cron handled by scheduler)
- `SOP.md` - Step-by-step process with approval checkpoint for role removal

### 5. Cloudflare Worker Proxy Deployment

Deploy the Solana RPC proxy to work around the http_request POST body limitation:

```bash
cd ~/.zeroclaw/solana-rpc-proxy
npm install -g wrangler
wrangler login
wrangler deploy
```

Copy the deployed URL (e.g., `https://solana-rpc-proxy.YOUR-ACCOUNT.workers.dev`) and update the skill at `~/.zeroclaw/shared/skills/default/check-payment/SKILL.md` with your actual proxy URL.

### 6. Wrapper Script Setup

Create `~/.zeroclaw/run_subscription_check.sh`:

```bash
#!/bin/bash
# Read wallet mapping and inject into agent prompt
ROSTER=$(cat ~/.zeroclaw/wallet_mapping.json)
zeroclaw agent -a test_agent -m "Use the check-payment skill. Check payment status for every wallet in the following roster JSON. For each entry, use the exact wallet address and exact discord_user_id given. Roster: $ROSTER"
```

Make it executable:
```bash
chmod +x ~/.zeroclaw/run_subscription_check.sh
```

### 7. Cron Job Setup

Add to your system crontab (not ZeroClaw's internal scheduler):

```bash
# Edit crontab
crontab -e

# Add this line (runs every hour)
0 * * * * /Users/adarsh/.zeroclaw/run_subscription_check.sh >> ~/.zeroclaw/logs/subscription_check.log 2>&1
```

**Note:** Do not rely on ZeroClaw's internal cron scheduler calling `zeroclaw agent` directly — it must go through the wrapper script to inject the roster.

### 6. Running the System

1. **Start the ZeroClaw daemon:**
```bash
zeroclaw daemon
```

2. **Test manual execution:**
```bash
# Test the skill directly
zeroclaw agent -m "Use the check-payment skill to check if wallet WALLET_ADDRESS has made a USDC payment to merchant MERCHANT_WALLET in the last 30 days"

# Test the SOP
zeroclaw sop run subscription_check
```

3. **Verify cron scheduling:**
```bash
zeroclaw cron list
```

## Architecture

1. **Cron (OS-level):** Triggers a wrapper script every N minutes via crontab
2. **Wrapper Script:** `run_subscription_check.sh` reads `wallet_mapping.json` at the shell level and injects its contents directly into the agent's prompt
3. **ZeroClaw Agent:** Using the `check-payment` skill, calls the built-in `http_request` tool to:
   - Query Solana RPC via a self-hosted Cloudflare Worker proxy
   - Query Discord's REST API for role status
4. **Role Management:** Based on payment status, the agent grants roles automatically (active) or removes directly (lapsed)

### Payment Verification Process

1. **On-Chain Query:** The system queries Solana RPC for USDC transactions from subscriber wallets to the merchant wallet
2. **Time Window:** Checks for payments within the last 30 days (2,592,000 seconds)
3. **Status Determination:** 
   - `active`: Valid USDC payment found within time window
   - `lapsed`: No valid payment found within time window

### Role Management Logic

**Auto-Grant (No Approval Required):**
- If payment status is `active` AND user lacks subscriber role
- System automatically grants subscriber role via Discord API

**Role Removal (Approval-Gated):**
- If payment status is `lapsed` AND user has subscriber role
- System posts approval request to Discord channel via proxy
- Waits for admin approval (✅ reaction)
- If approved: Removes subscriber role
- If declined: Maintains current status

**No Change:**
- If payment status matches current role status
- No action taken

### Security Features

**Custody Tier: T0**
- System holds no private keys
- Cloudflare Worker proxy holds no keys (stateless, read-only RPC relay)
- Agent never signs transactions
- Only reads on-chain data for verification
- Role management via Discord bot token (which itself holds no funds)

## Known Limitations

### HTTP Request POST Body Bug
ZeroClaw's built-in `http_request` tool does not transmit a POST request body (confirmed via httpbin.org testing — body arrives empty server-side regardless of argument name used). This breaks direct calls to Solana's JSON-RPC endpoint, which requires POST.

**Workaround:** Solana RPC calls are routed through a self-hosted Cloudflare Worker proxy (`solana-rpc-p.oExtended tyeaproxy pattern to handae Dircordsmessage post0ng: .weoWorker now accepts GET requests to `/dkscord/message` aed interns.ly performs authentdcateevPO)T toaDiscccd'e APIp The bottt kEn isTsto rd as etW rkernsinret, noe passrd in URLn.aThls preseyv s eheohuman-mn-s e-lotp checkreintPOST to Solana RPC endpoints. The proxy is stateless, holds no keys, and only relays read-only RPC calls.

**Impact on approval-gated removal:** The approval checkpoint requires POSTing a message body to Discord, which fails with "invalid JSON" errors. Role removal now executes directly without approval.

### File/Shell Tools Not Available
Under this agent's `locked_down` risk profile, only the `http_request` tool is granted — bash and file-read tools are not available. This means the agent cannot read `wallet_mapping.json` directly.

**Workaround:** The wrapper script reads the file at the shell level and passes its contents directly in the prompt on every run, so the roster stays the single source of truth an operator edits — no code changes needed, the agent never needs file access itself.

**Prompt Injection Resistance:**
- This MVP's SOP is cron-triggered only; there is no inbound message-handling surface
- Therefore, there is no prompt-injection attack surface to test in this version
- Bot only trusts on-chain data for payment verification
- No user claims or fabricated transaction signatures are accepted

**Approval Checkpoint:**
- Role removal requires admin approval
- Automatic role grants allowed for verified payments (read-only operation)
- Fail-safe: system defaults to maintaining access status

## File Structure

```
~/.zeroclaw/
├── config.toml                          # Main ZeroClaw configuration
├── config.example.toml                  # Example configuration with documentation
├── wallet_mapping.json                  # Wallet to Discord user mapping
├── run_subscription_check.sh            # Wrapper script for cron (reads roster, injects into prompt)
├── solana-rpc-proxy/
│   ├── worker.js                        # Cloudflare Worker proxy code
│   ├── wrangler.toml                    # Worker deployment config
│   └── DEPLOYMENT_GUIDE.md              # Proxy deployment instructions
├── shared/skills/default/
│   └── check-payment/
│       └── SKILL.md                     # Payment checking skill (uses proxy URL)
└── agents/test_agent/workspace/sops/
    └── subscription_check/
        ├── SOP.toml                     # SOP trigger configuration
        └── SOP.md                       # SOP steps
```

## Troubleshooting

### Bot Cannot Manage Roles
- Verify bot has "Manage Roles" permission
- Check role hierarchy: bot role must be above subscriber role
- Ensure subscriber_role_id is correctly set in config.toml

### RPC Calls Failing
- Verify RPC URL is accessible
- Check rate limits on public RPC endpoints
- Consider using private RPC for production

### Cron Job Not Executing
- Verify scheduler is enabled in config.toml
- Check cron syntax is correct
- Ensure daemon is running: `zeroclaw daemon`

### Approval System Not Working
- Verify pending_approvals.json file exists and is writable
- Check Discord bot permissions for message reactions
- Ensure approval handler function is properly configured

## Security Considerations

**Data Privacy:**
- Wallet addresses are stored in local mapping file
- Discord user IDs are used for role management only
- No sensitive payment data is stored permanently

**Access Control:**
- Bot token should be kept secret
- Config file contains sensitive tokens - use environment variables in production
- Role hierarchy prevents privilege escalation

**Audit Trail:**
- All role changes are posted to Discord channel
- Payment checks are logged by ZeroClaw
- Approval decisions are recorded in pending_approvals.json

## Future Enhancements

- Grace period implementation before role removal
- Multi-merchant support
- Payment amount verification
- Subscription tier management
- Webhook notifications for payment events
- Historical payment tracking

## License

This project is part of the ZeroClaw ecosystem and follows the same licensing terms.

## Support

For issues related to:
- **ZeroClaw:** https://github.com/zeroclaw-labs/zeroclaw
- **Solana RPC:** https://docs.solana.com/
- **Discord API:** https://discord.com/developers/docs/intro
# zeroclaw-final
