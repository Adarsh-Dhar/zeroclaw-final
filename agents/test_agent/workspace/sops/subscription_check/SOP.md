# Subscription Payment Check and Role Management

## Wallet Mapping (STATIC - update this file when roster changes)

The following wallets are configured for subscription checking:
- EYSHit3n1e6qQWKG6L4g34SNoG6P7R9U7y6MGREBLebB → Discord user ID: 1531681016249319576
- pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak → Discord user ID: 800361404196454431

## Steps

1. **Check wallet 1** — Verify payment status for EYSHit3n1e6qQWKG6L4g34SNoG6P7R9U7y6MGREBLebB
   - tools: http_request
   - Call the Solana RPC endpoint at https://api.mainnet-beta.solana.com with getSignaturesForAddress for merchant pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak, limit 50
   - For each signature, call getTransaction with encoding jsonParsed
   - Check if any transaction is a USDC transfer from EYSHit3n1e6qQWKG6L4g34SNoG6P7R9U7y6MGREBLebB to pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak within last 30 days
   - Check Discord role status for Discord user ID 1531681016249319576
   - Determine role action: grant_role (if active without role), remove_role (if lapsed with role), no_change
   - Return result in format: EYSHit3n1e6qQWKG6L4g34SNoG6P7R9U7y6MGREBLebB: ✅ active (last paid: {date}) | role_action: {grant_role/remove_role/no_change} | current_role: {has_role/no_role}
   - output: {"type":"object","required":["result"],"properties":{"result":{"type":"string"}}}

2. **Check wallet 2** — Verify payment status for pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak
   - tools: http_request
   - Call the Solana RPC endpoint at https://api.mainnet-beta.solana.com with getSignaturesForAddress for merchant EYSHit3n1e6qQWKG6L4g34SNoG6P7R9U7y6MGREBLebB, limit 50
   - For each signature, call getTransaction with encoding jsonParsed
   - Check if any transaction is a USDC transfer from pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak to EYSHit3n1e6qQWKG6L4g34SNoG6P7R9U7y6MGREBLebB within last 30 days
   - Check Discord role status for Discord user ID 800361404196454431
   - Determine role action: grant_role (if active without role), remove_role (if lapsed with role), no_change
   - Return result in format: pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak: ✅ active (last paid: {date}) | role_action: {grant_role/remove_role/no_change} | current_role: {has_role/no_role}
   - output: {"type":"object","required":["result"],"properties":{"result":{"type":"string"}}}

3. **Grant subscriber roles** — Automatically grant roles for active users
   - tools: http_request
   - For each wallet with role_action: grant_role
     - Use the Discord user ID from the wallet mapping file
     - Automatically grant subscriber role to Discord user (no approval required - verified payment)
     - Post notification: "✅ Automatically granted subscriber role to @user (payment verified)"
   - For each wallet with role_action: no_change
     - No action needed

4. **Revoke subscriber roles** — Remove roles for lapsed users (requires approval)
   - tools: http_request
   - requires_confirmation: true
   - For each wallet with role_action: remove_role
     - Use the Discord user ID from the wallet mapping file
     - **SAFETY CHECK:** Only proceed if status == "lapsed" (never on "check_failed")
     - If status == "check_failed": Skip this wallet and log "RPC check failed, cannot safely revoke"
     - If status == "lapsed":
       - Post proposal for role removal: "⚠️ Payment lapsed for @user. Propose removal of subscriber role. Admin approval required."
       - Wait for admin approval before proceeding
       - If approved: Remove subscriber role from Discord user
       - If declined: Skip role removal and log decision

5. **Post results** — Send payment status summary to Discord channel
   - tools: http_request
   - Combine results from step 2 into a single message
   - Post to Discord channel using the configured Discord bot
