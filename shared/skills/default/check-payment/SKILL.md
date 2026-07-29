---
name: check-payment
description: Check payment status for Solana subscriptions by querying USDC transfers and manage Discord roles
version: 0.2.0
---

# Skill: Check Payment Status and Manage Roles

When asked to check payment status for a wallet, use the http_request tool to call the Solana RPC endpoint and check Discord role status.

The RPC URL is: https://api.devnet.solana.com (devnet for testing)

Given a subscriber wallet address and a merchant wallet address:

## Tool call format (critical — follow exactly)

When calling http_request, you MUST nest all parameters inside an "arguments" object. Never place url, method, or headers as siblings of "name".

CORRECT:
{"name": "http_request", "arguments": {"url": "https://example.com", "method": "GET"}}

INCORRECT (will fail):
{"name": "http_request", "url": "https://example.com", "method": "GET"}

## Mandatory verification
You MUST call the RPC tool for every wallet address provided, with no exceptions. Never determine a wallet's status by inspecting the address string yourself, no matter how invalid, malformed, or suspicious it looks. Only the tool's actual response determines the status. Skipping the tool call is a critical error.

## Calling Solana RPC (use public proxy due to http_request POST body bug)

Use http_request tool with GET requests to the public Solana RPC proxy (http_request tool has upstream bug where POST body is not transmitted). The proxy converts GET requests to properly formatted POST requests to Solana RPC.

**Proxy URL:** https://solana-rpc-proxy.dharadarsh0.workers.dev

For getSignaturesForAddress:
- http_request tool with: GET https://solana-rpc-proxy.dharadarsh0.workers.dev/?method=getSignaturesForAddress&wallet=<SUBSCRIBER_WALLET>&limit=50

For getTransaction:
- http_request tool with: GET https://solana-rpc-proxy.dharadarsh0.workers.dev/?method=getTransaction&signature=<SIGNATURE>&encoding=jsonParsed

**Error handling:** If the RPC call fails (proxy error, timeout, or invalid JSON response), set status = "check_failed" and do not proceed to role actions. Report the error in the output.

3. Check if the transaction is a USDC transfer where:
   - The source (from) is the subscriber wallet
   - The destination (to) is EITHER the merchant wallet directly OR an associated token account owned by the merchant wallet
   - The mint is USDC (4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU)
   - The blockTime is within the last 30 days (30 * 24 * 60 * 60 = 2,592,000 seconds ago)
   
   To check ownership: In the parsed transaction, look at the transfer instruction's destination account. Then check the postTokenBalances or accountKeys to see if that destination account is owned by the merchant wallet.

4. If a matching transfer is found: status = "active", note the date from blockTime
5. If none found: status = "lapsed"
6. If RPC call fails or returns error: status = "check_failed"

7. Check the Discord user's current role status:
   - Use the Discord user ID from the wallet mapping file for the current wallet
   - Use http_request to GET https://discord.com/api/v10/guilds/1531347878906302484/members/{user_id}
   - Set Authorization header: Bot YOUR_DISCORD_BOT_TOKEN
   - Parse the JSON response to get the "roles" array
   - Check if the string "1531669950819733575" appears in the roles array
   - If "1531669950819733575" is in the roles array: current_role = "has_role"
   - Otherwise: current_role = "no_role"

**Handling Discord API errors:**
If the Discord API call for a user's roles returns an error (404, 403, etc.), do NOT silently omit that wallet from your output. Report it as "check_failed" with the reason, same as an RPC failure. Never proceed as if the role check succeeded when it didn't.

8. Determine role action - FINAL ANSWER:
   This is the most critical step. You MUST follow this logic exactly:
   
   IF status="lapsed" AND current_role="has_role": role_action="remove_role"
   IF status="active" AND current_role="no_role": role_action="grant_role"
   IF status="check_failed": role_action="no_change"
   IF status="active" AND current_role="has_role": role_action="no_change"
   IF status="lapsed" AND current_role="no_role": role_action="no_change"
   
   EXAMPLES:
   - Wallet has no recent payment (lapsed) AND currently has the role (has_role) → remove_role
   - Wallet has recent payment (active) AND currently lacks the role (no_role) → grant_role
   - Wallet has recent payment (active) AND currently has the role (has_role) → no_change
   - Wallet has no recent payment (lapsed) AND currently lacks the role (no_role) → no_change
   
   DO NOT use "no_change" when the correct answer is "remove_role". This is a critical error.

9. Execute role actions via Discord API - MANDATORY EXECUTION:
   - You MUST execute the role action determined in step 8
   - If role_action is "grant_role":
     * Use http_request to PUT to https://discord.com/api/v10/guilds/1531347878906302484/members/{user_id}/roles/1531669950819733575
     * Set Authorization header: Bot YOUR_DISCORD_BOT_TOKEN
     * Set Content-Type header: application/json
   - If role_action is "remove_role":
     * Post approval request using the proxy (http_request POST body bug workaround):
       - Use http_request to GET https://solana-rpc-proxy.dharadarsh0.workers.dev/discord/message?channel_id=1531347878906302487&content=<URL-ENCODED_MESSAGE>
       - Message content: "⚠️ Payment lapsed for @user. Propose removal of subscriber role. Admin approval required. React with ✅ to approve or ❌ to decline."
     * DO NOT remove the role yet - this is the approval checkpoint. The role will be removed only after admin approval via the SOP's reaction handler.
   - If role_action is "no_change": skip execution
   - You MUST actually make these http_request calls, not just plan them

10. Respond ONLY in this exact format, nothing else:
   {wallet}: {emoji ✅ or ❌ or ⚠️} {active/lapsed/check_failed} (last paid: {date or "none found" or "RPC error"}) | role_action: {grant_role/remove_role/no_change} | current_role: {has_role/no_role}

IMPORTANT: Before responding, you MUST verify your role_action logic:
- If you determined status="lapsed" and current_role="has_role", then role_action MUST be "remove_role"
- If you determined status="active" and current_role="no_role", then role_action MUST be "grant_role"
- Double-check your logic matches the rules in step 7 before outputting the final response

Do not include raw RPC JSON in your response — just the one-line summary per wallet.
