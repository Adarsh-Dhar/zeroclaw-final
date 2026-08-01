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

[skill_bundles.default]
directory = "/Users/adarsh/Documents/zeroclaw/shared/skills/default"

[sop]
sops_dir = "/Users/adarsh/Documents/zeroclaw/sops"

[workspace]
path = "/Users/adarsh/Documents/zeroclaw"

[scheduler]
enabled = true
```

2. **Memory Store Configuration:**

The system uses ZeroClaw's built-in Memory_Store for persistent subscriber state. No manual configuration needed - it's configured as `backend = "sqlite.sqlite"` by default.

3. **One-time Migration (Optional):**

If you have existing subscribers in `wallet_mapping.json`, place it in your project directory. The `subscription_check` SOP will automatically migrate these to Memory_Store on first run. After successful migration, `wallet_mapping.json` can be safely deleted.

### 3. Skill Installation

The skills are located at:
```
/Users/adarsh/Documents/zeroclaw/shared/skills/default/check-payment/SKILL.md
/Users/adarsh/Documents/zeroclaw/shared/skills/default/onboarding/SKILL.md
```

**check-payment skill:**
- Queries Solana RPC for USDC transactions using per-user reference keys
- Checks payment status within subscription windows
- Enforces tier-specific amount verification
- Determines Discord role actions based on payment status

**onboarding skill:**
- Handles Discord "subscribe" commands
- Generates unique Solana Pay URLs with reference keys
- Persists subscriber records in Memory_Store
- Posts payment links and QR codes to Discord

### 4. SOP Configuration

The SOPs are located at:
```
/Users/adarsh/Documents/zeroclaw/sops/subscription_check/
/Users/adarsh/Documents/zeroclaw/sops/onboarding_check/
```

**subscription_check SOP:**
- `SOP.toml` - Trigger configuration (cron: hourly)
- `SOP.md` - Step-by-step process for payment checking, grace periods, and role management

**onboarding_check SOP:**
- `SOP.toml` - Trigger configuration (cron: every 5 minutes)
- `SOP.md` - Step-by-step process for handling subscribe commands

### 5. Cloudflare Worker Proxy Deployment

Deploy the Solana RPC proxy to work around the http_request POST body limitation:

```bash
cd /Users/adarsh/Documents/zeroclaw/solana-rpc-proxy
npm install -g wrangler
wrangler login
wrangler deploy
```

Copy the deployed URL (e.g., `https://solana-rpc-proxy.YOUR-ACCOUNT.workers.dev`) and update the skills with your actual proxy URL.

### 6. Running the System

1. **Start the ZeroClaw daemon:**
```bash
zeroclaw daemon
```

2. **Verify SOP discovery:**
```bash
zeroclaw sop list
```

3. **Verify skill bundles loaded:**
```bash
zeroclaw skills list --agent test_agent
```

4. **Test manual execution:**
```bash
# Test the SOP manually
zeroclaw sop run subscription_check
zeroclaw sop run onboarding_check
```

5. **Verify SOP scheduling:**
```bash
zeroclaw cron list
```

## Architecture

1. **ZeroClaw Daemon:** Runs persistently with internal scheduler that triggers SOPs based on cron expressions in SOP.toml files
2. **SOP Engine:** Executes standardized operating procedures with deterministic run, admission policy, and audit log
3. **Memory_Store:** Persistent subscriber state storage using SQLite backend, with `subscriber:<discord_user_id>` key scheme
4. **Skills:**
   - `check-payment`: Queries Solana RPC via Cloudflare Worker proxy for payment verification using per-user reference keys
   - `onboarding`: Handles Discord subscribe commands and generates Solana Pay URLs
5. **Role Management:** Based on payment status, the agent grants roles automatically (active) or proposes removal after grace period (lapsed)

### Payment Verification Process

1. **Onboarding:** User types "subscribe" or "subscribe premium" in Discord channel
2. **Reference Key Generation:** System generates unique reference key via `/keygen` endpoint
3. **Solana Pay URL:** Creates payment URL with tier-specific amount and reference key
4. **Payment Verification:** System queries Solana RPC for transactions to reference key
5. **Amount Validation:** Verifies payment amount meets tier requirements
6. **Subscription Window:** Checks payment within configured period (default 30 days)

### Instant payment via Self-Hosted Payment Page

Alongside the Solana Pay URL/QR, onboarding now also posts a link to a
self-hosted payment page (`/pay?tier=...&discord_user_id=...&reference=...`)
served directly by the Worker. This page:

- Renders a "Connect & Pay" button that works with Phantom wallet
- Calls the Worker's own `/actions/subscribe` endpoint to get an unsigned
  transaction (SOL transfer to the fixed merchant wallet + reference key + memo)
- Signs and broadcasts the transaction directly from the user's wallet
- The Worker never sees or requests a private key; the subscriber's wallet
  signs locally

After posting the payment message, the onboarding skill runs a bounded
poll (~15 rounds, 20s apart) against `getSignaturesForAddress` on the
reference key. A verified match grants the role and posts confirmation
within roughly 20–60 seconds of payment, instead of waiting for the hourly
`subscription_check` SOP, which remains as the fallback safety net.

Custody tier is unchanged: **T1**. The only new attacker-influenceable
input is the `account` field in the POST body, which can only make the
Action build a transaction where *that same account* pays the
hard-coded merchant wallet a hard-coded amount — it cannot redirect funds,
change the price, or authorize a transaction on anyone else's behalf.

### Subscription Tiers

**Standard Tier:**
- Amount: 0.001 SOL
- Period: 30 days

**Premium Tier:**
- Amount: 0.0025 SOL
- Period: 30 days

### Role Management Logic

**Auto-Grant (No Approval Required):**
- If payment status is `active` AND user lacks subscriber role
- System automatically grants subscriber role via Discord API

**Grace Period:**
- If payment status is `lapsed`, system starts 3-day grace period
- User retains role during grace period
- Renewal reminder sent 5 days before expiry

**Role Removal (Approval-Gated):**
- If grace period expires AND user has subscriber role
- System posts role removal proposal to Discord channel
- Requires admin approval to remove role
- After reacting ✅ to approve removal, execute via:
  ```bash
  ./execute_role_removals.sh <discord_user_id> <guild_id> <role_id>
  ```

**No Change:**
- If payment status matches current role status
- No action taken

### Security Features

**Custody Tier: T1**
- System holds no private keys and never signs transactions
- Builds unsigned Solana Pay transfer-request URLs (`solana:<merchant>?amount=...&reference=...`) for the subscriber to sign in their own wallet
- A human (the subscriber) always signs — the agent never touches a private key
- Cloudflare Worker proxy holds no keys (stateless, read-only RPC relay)
- Role management via Discord bot token (which itself holds no funds)

## Known Limitations

### HTTP Request POST Body Bug
ZeroClaw's built-in `http_request` tool does not transmit a POST request body (confirmed via httpbin.org testing — body arrives empty server-side regardless of argument name used). This breaks direct calls to Solana's JSON-RPC endpoint, which requires POST.

**Workaround:** Solana RPC calls are routed through a self-hosted Cloudflare Worker proxy. The proxy accepts GET requests and internally performs authenticated POST requests to Solana RPC endpoints. The proxy is stateless, holds no keys, and only relays read-only RPC calls.

### Prompt Injection Resistance
- Bot only trusts on-chain data for payment verification
- No user claims or fabricated transaction signatures are accepted
- Memory_Store provides persistent state without external file access

### Blink polling is best-effort, not sole source of truth
The fast-confirm loop in the onboarding skill is a UX latency optimization.
If the Worker is unreachable, the loop exhausts, or the user closes the app
before the loop's window ends, the hourly `subscription_check` SOP still
verifies the payment and grants the role — nothing is ever marked `active`
without on-chain verification either way.

## File Structure

```
~/.zeroclaw/
├── config.toml                          # Main ZeroClaw configuration
├── agents/test_agent/workspace/          # Agent workspace (managed by ZeroClaw)
├── sops/
│   ├── subscription_check/
│   │   ├── SOP.toml                     # SOP trigger configuration (cron: hourly)
│   │   └── SOP.md                       # Payment checking and role management steps
│   └── onboarding_check/
│       ├── SOP.toml                     # SOP trigger configuration (cron: every 5 min)
│       └── SOP.md                       # Subscribe command handling steps
├── shared/skills/default/
│   ├── check-payment/
│   │   └── SKILL.md                     # Payment verification skill
│   └── onboarding/
│       └── SKILL.md                     # Onboarding skill
├── solana-rpc-proxy/
│   ├── worker.js                        # Cloudflare Worker proxy code
│   ├── wrangler.toml                    # Worker deployment config
│   └── DEPLOYMENT_GUIDE.md              # Proxy deployment instructions
└── dev-tools/                           # Local test harness (not for production)
    ├── onboarding_check.sh              # Shadow implementation (moved here)
    └── subscription_check.sh            # Shadow implementation (moved here)
```

## Troubleshooting

### SOPs Not Discovered
- Verify `sops_dir` path in config.toml is correct
- Check that SOP.toml and SOP.md files exist in the directory
- Restart daemon after config changes: `pkill -f "zeroclaw daemon" && zeroclaw daemon`

### Skills Not Loading
- Verify `skill_bundles.default.directory` path in config.toml is correct
- Check that SKILL.md files exist in the skills directory
- Run `zeroclaw skills list --agent test_agent` to verify

### Bot Cannot Manage Roles
- Verify bot has "Manage Roles" permission
- Check role hierarchy: bot role must be above subscriber role
- Ensure subscriber_role_id is correctly set in config.toml

### RPC Calls Failing
- Verify RPC URL is accessible
- Check rate limits on public RPC endpoints
- Consider using private RPC for production
- Verify Cloudflare Worker proxy is deployed and accessible

### SOP Not Executing on Schedule
- Verify scheduler is enabled in config.toml
- Check cron syntax in SOP.toml files
- Ensure daemon is running: `zeroclaw daemon`
- Check `zeroclaw cron list` for scheduled jobs

## Security Considerations

**Data Privacy:**
- Subscriber records stored in ZeroClaw Memory_Store (SQLite backend)
- Discord user IDs are used for role management only
- No sensitive payment data is stored permanently

**Access Control:**
- Bot token should be kept secret
- Config file contains sensitive tokens - use environment variables in production
- Role hierarchy prevents privilege escalation
- Memory_Store operations require `memory_store` tool permission

**Audit Trail:**
- All role changes are posted to Discord channel
- Payment checks are logged by ZeroClaw
- SOP runs are tracked in daemon state

**Unattended Memory Operations:**
- `require_approval_for_medium_risk = false` in config allows memory_store to execute without operator approval
- This is necessary for cron-triggered SOP runs
- Memory_Store is a medium-risk write operation

## License

This project is part of the ZeroClaw ecosystem and follows the same licensing terms.

## Support

For issues related to:
- **ZeroClaw:** https://github.com/zeroclaw-labs/zeroclaw
- **Solana RPC:** https://docs.solana.com/
- **Discord API:** https://discord.com/developers/docs/intro
