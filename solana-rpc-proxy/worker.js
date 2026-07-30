// Cloudflare Worker for Solana RPC Proxy and Discord Message Proxy
// This worker accepts GET requests and forwards them as POST to Solana RPC and Discord API
// Deploy to Cloudflare Workers to get a public endpoint

import nacl from 'tweetnacl';

// Base58 encoding using the Bitcoin alphabet
// Encodes a Uint8Array to a base58 string using big-integer division
const BASE58_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

// Pure helper: validates limit parameter for getSignaturesForAddress
// Returns true iff limit is an integer in [1, 1000]
export function isValidLimit(value) {
  if (value === null || value === undefined) return false;
  const str = String(value);
  if (!/^-?\d+$/.test(str)) return false;
  const n = Number(str);
  if (!Number.isInteger(n)) return false;
  return n >= 1 && n <= 1000;
}

// Pure helper: validates decoded DM content length
// Returns true iff decoded string has length in [1, 2000]
export function isValidDmContent(decoded) {
  return decoded.length >= 1 && decoded.length <= 2000;
}

// Pure helper: HTML-escapes a string to prevent XSS
// Escapes <, >, &, ", and ' characters
function escapeHtml(unsafe) {
  return unsafe
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
}

function encodeBase58(bytes) {
  // Count leading zero bytes — each becomes a '1' character
  let leadingZeros = 0;
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i] !== 0) break;
    leadingZeros++;
  }

  // Convert byte array to a single BigInt
  let num = BigInt(0);
  for (let i = 0; i < bytes.length; i++) {
    num = (num << BigInt(8)) + BigInt(bytes[i]);
  }

  // Repeated mod-58 to extract base58 digits (least significant first)
  const digits = [];
  const base = BigInt(58);
  while (num > BigInt(0)) {
    const remainder = num % base;
    num = num / base;
    digits.push(BASE58_ALPHABET[Number(remainder)]);
  }

  // Prepend '1' characters for each leading zero byte
  const leading = '1'.repeat(leadingZeros);

  // Reverse digits (we collected them LSB-first)
  return leading + digits.reverse().join('');
}

function decodeBase58(str) {
  const bytes = [0];
  for (const char of str) {
    const value = BASE58_ALPHABET.indexOf(char);
    if (value === -1) throw new Error('Invalid base58 character');
    let carry = value;
    for (let i = 0; i < bytes.length; i++) {
      carry += bytes[i] * 58;
      bytes[i] = carry & 0xff;
      carry >>= 8;
    }
    while (carry > 0) {
      bytes.push(carry & 0xff);
      carry >>= 8;
    }
  }
  for (const char of str) {
    if (char !== '1') break;
    bytes.push(0);
  }
  return new Uint8Array(bytes.reverse());
}

// In-memory nonce store per Worker instance is not durable across requests
// in Cloudflare Workers — nonces must be signed+verified statelessly instead.
// We embed discord_id + issued_at + a short random token in the nonce itself,
// then just check issued_at is recent (replay window) rather than needing storage.
function buildNonce(discordId) {
  const token = crypto.randomUUID();
  const issuedAt = Date.now();
  return `ZeroClaw-Registration|discord:${discordId}|issued:${issuedAt}|nonce:${token}`;
}

function nonceIsFresh(nonce, maxAgeMs = 5 * 60 * 1000) {
  const match = nonce.match(/\|issued:(\d+)\|/);
  if (!match) return false;
  const issuedAt = Number(match[1]);
  return Date.now() - issuedAt <= maxAgeMs;
}

function validateNonceDiscordId(nonce, expectedDiscordId) {
  const match = nonce.match(/\|discord:(\d+)\|/);
  if (!match) return false;
  return match[1] === expectedDiscordId;
}

function buildRegisterPage(discordId, discordUsername, nonce, proxyBaseUrl) {
  const safeUsername = escapeHtml(discordUsername || discordId);
  return `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>ZeroClaw — Verify Wallet</title>
<style>body{font-family:system-ui;max-width:480px;margin:60px auto;padding:0 20px;text-align:center}
button{padding:12px 24px;font-size:16px;border-radius:8px;border:none;background:#512da8;color:#fff;cursor:pointer;margin-top:20px}
#status{margin-top:20px;color:#555}</style></head>
<body>
<h2>Verify your wallet</h2>
<p>Registering for Discord user <b>${safeUsername}</b></p>
<p>This proves you control the wallet — it does not send any transaction or reveal your private key.</p>
<button id="connect">Connect &amp; Sign</button>
<div id="status"></div>
<script>
const nonce = ${JSON.stringify(nonce)};
const discordId = ${JSON.stringify(discordId)};
document.getElementById('connect').onclick = async () => {
  const statusEl = document.getElementById('status');
  try {
    if (!window.solana || !window.solana.isPhantom) {
      statusEl.textContent = 'Phantom wallet not found. Install it and reload this page.';
      return;
    }
    statusEl.textContent = 'Connecting...';
    const resp = await window.solana.connect();
    const wallet = resp.publicKey.toString();
    statusEl.textContent = 'Please sign the message in your wallet...';
    const encodedMessage = new TextEncoder().encode(nonce);
    const signed = await window.solana.signMessage(encodedMessage, 'utf8');
    const signatureB64 = btoa(String.fromCharCode(...signed.signature));
    statusEl.textContent = 'Verifying...';
    const verifyResp = await fetch(${JSON.stringify(proxyBaseUrl)} + '/verify-registration', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({ discord_id: discordId, wallet, signature: signatureB64, nonce })
    });
    const result = await verifyResp.json();
    if (result.ok) {
      statusEl.textContent = '✅ Verified! Return to Discord — #subscription is now unlocked.';
    } else {
      statusEl.textContent = '❌ Verification failed: ' + (result.error || 'unknown error');
    }
  } catch (e) {
    statusEl.textContent = 'Error: ' + e.message;
  }
};
</script>
</body></html>`;
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // Handle reference key generation
    if (url.pathname === '/keygen') {
      const randomBytes = new Uint8Array(32);
      crypto.getRandomValues(randomBytes);
      const referenceKey = encodeBase58(randomBytes);
      return new Response(JSON.stringify({ reference_key: referenceKey }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' }
      });
    }

    // GET /register?discord_id=...&discord_username=...
    // Serves the wallet-connect-and-sign HTML page
    if (url.pathname === '/register' && request.method === 'GET') {
      const discordId = url.searchParams.get('discord_id');
      const discordUsername = url.searchParams.get('discord_username') || '';
      if (!discordId) {
        return new Response('Missing discord_id parameter', { status: 400 });
      }
      const nonce = buildNonce(discordId);
      const html = buildRegisterPage(discordId, discordUsername, nonce, env.PROXY_BASE_URL);
      return new Response(html, { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
    }

    // POST /verify-registration
    // Body: { discord_id, wallet, signature, nonce }
    if (url.pathname === '/verify-registration' && request.method === 'POST') {
      let body;
      try {
        body = await request.json();
      } catch {
        return new Response(JSON.stringify({ error: 'invalid_json' }), { status: 400 });
      }

      const { discord_id, wallet, signature, nonce } = body;
      if (!discord_id || !wallet || !signature || !nonce) {
        return new Response(JSON.stringify({ error: 'missing_fields' }), { status: 400 });
      }

      // Nonce must reference this exact discord_id (prevents replaying someone
      // else's page load against a different wallet) and be recent.
      if (!validateNonceDiscordId(nonce, discord_id)) {
        return new Response(JSON.stringify({ error: 'nonce_discord_mismatch' }), { status: 400 });
      }
      if (!nonceIsFresh(nonce)) {
        return new Response(JSON.stringify({ error: 'nonce_expired' }), { status: 400 });
      }

      // Verify the ed25519 signature over the nonce message
      let verified = false;
      try {
        const pubkeyBytes = decodeBase58(wallet);
        const sigBytes = Uint8Array.from(atob(signature), c => c.charCodeAt(0));
        const messageBytes = new TextEncoder().encode(nonce);
        verified = nacl.sign.detached.verify(messageBytes, sigBytes, pubkeyBytes);
      } catch (e) {
        return new Response(JSON.stringify({ error: 'verification_error', detail: String(e) }), { status: 400 });
      }

      if (!verified) {
        return new Response(JSON.stringify({ error: 'signature_invalid' }), { status: 401 });
      }

      // Signature is valid — this Discord user genuinely controls this wallet.
      // Grant the Registered role directly (this is the one place a role grant
      // happens without going through the SOP, since it's a direct consequence
      // of a verified cryptographic proof, not a chat claim).
      
      // Validate required environment variables
      if (!env.DISCORD_GUILD_ID || !env.REGISTERED_ROLE_ID || !env.DISCORD_BOT_TOKEN) {
        return new Response(JSON.stringify({ error: 'server_configuration_error' }), { status: 500 });
      }
      
      const roleResp = await fetch(
        `https://discord.com/api/v10/guilds/${env.DISCORD_GUILD_ID}/members/${discord_id}/roles/${env.REGISTERED_ROLE_ID}`,
        { method: 'PUT', headers: { Authorization: `Bot ${env.DISCORD_BOT_TOKEN}` } }
      );
      if (!roleResp.ok) {
        return new Response(JSON.stringify({ error: 'role_grant_failed', status: roleResp.status }), { status: 502 });
      }

      // Notify #signup and post the verified mapping into #signup so the
      // onboarding_check SOP can pick it up and persist it into Memory_Store —
      // the Worker itself never touches Memory_Store directly.
      
      // Validate required environment variables for notification
      if (!env.SIGNUP_CHANNEL_ID || !env.DISCORD_BOT_TOKEN) {
        return new Response(JSON.stringify({ error: 'server_configuration_error' }), { status: 500 });
      }
      
      await fetch(
        `https://discord.com/api/v10/channels/${env.SIGNUP_CHANNEL_ID}/messages`,
        {
          method: 'POST',
          headers: { Authorization: `Bot ${env.DISCORD_BOT_TOKEN}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ content: `✅ <@${discord_id}> wallet verified. You can now subscribe in this channel.` }),
        }
      );
      await fetch(
        `https://discord.com/api/v10/channels/${env.SIGNUP_CHANNEL_ID}/messages`,
        {
          method: 'POST',
          headers: { Authorization: `Bot ${env.DISCORD_BOT_TOKEN}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            content: `WALLET_VERIFIED discord_user_id=${discord_id} wallet_address=${wallet} verified_at=${new Date().toISOString()}`,
          }),
        }
      );

      return new Response(JSON.stringify({ ok: true, wallet }), { headers: { 'Content-Type': 'application/json' } });
    }

    // Handle Discord DM sending
    if (url.pathname === '/discord/dm') {
      const userId = url.searchParams.get('user_id');
      const rawContent = url.searchParams.get('content');

      if (!userId) {
        return new Response(JSON.stringify({ error: 'missing required parameter: user_id' }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' }
        });
      }
      if (rawContent === null) {
        return new Response(JSON.stringify({ error: 'missing required parameter: content' }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' }
        });
      }

      // URL-decode the content
      const content = decodeURIComponent(rawContent);

      if (content.length === 0 || content.length > 2000) {
        return new Response(JSON.stringify({ error: 'content must be between 1 and 2000 characters after URL-decoding' }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' }
        });
      }

      // Step 1: Open a DM channel with the user
      const dmChannelRes = await fetch(
        `https://discord.com/api/v10/users/${userId}/channels`,
        {
          method: 'POST',
          headers: {
            'Authorization': `Bot ${env.DISCORD_BOT_TOKEN}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({}),
        }
      );

      if (!dmChannelRes.ok) {
        const errorBody = await dmChannelRes.text();
        return new Response(errorBody, {
          status: dmChannelRes.status,
          headers: { 'Content-Type': 'application/json' }
        });
      }

      const dmChannel = await dmChannelRes.json();
      const dmChannelId = dmChannel.id;

      // Step 2: Send the message to the DM channel
      const msgRes = await fetch(
        `https://discord.com/api/v10/channels/${dmChannelId}/messages`,
        {
          method: 'POST',
          headers: {
            'Authorization': `Bot ${env.DISCORD_BOT_TOKEN}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ content }),
        }
      );

      const msg = await msgRes.json();
      return new Response(JSON.stringify({
        dm_channel_id: dmChannelId,
        message_id: msg.id,
        status: 200
      }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' }
      });
    }

    // Handle Discord channel messages passthrough
    // Matches /discord/channels/<channel_id>/messages
    const channelMessagesMatch = url.pathname.match(/^\/discord\/channels\/([^/]+)\/messages$/);
    if (channelMessagesMatch) {
      const channelId = channelMessagesMatch[1];
      const limit = url.searchParams.get('limit');

      // Build Discord API URL, only include limit if it was provided
      const discordUrl = new URL(`https://discord.com/api/v10/channels/${channelId}/messages`);
      if (limit !== null) {
        discordUrl.searchParams.set('limit', limit);
      }

      const discordRes = await fetch(discordUrl.toString(), {
        method: 'GET',
        headers: {
          'Authorization': `Bot ${env.DISCORD_BOT_TOKEN}`,
        },
      });

      const body = await discordRes.text();
      return new Response(body, { status: discordRes.status });
    }

    // Handle Discord guild member lookup
    // Matches /discord/guilds/<guild_id>/members/<user_id>
    const guildMemberMatch = url.pathname.match(/^\/discord\/guilds\/([^/]+)\/members\/([^/]+)$/);
    if (guildMemberMatch) {
      const guildId = guildMemberMatch[1];
      const userId = guildMemberMatch[2];

      const discordRes = await fetch(
        `https://discord.com/api/v10/guilds/${guildId}/members/${userId}`,
        {
          method: 'GET',
          headers: {
            'Authorization': `Bot ${env.DISCORD_BOT_TOKEN}`,
          },
        }
      );

      const body = await discordRes.text();
      return new Response(body, { status: discordRes.status });
    }

    // Handle Discord guild member role grant
    // Matches /discord/guilds/<guild_id>/members/<user_id>/roles/<role_id>
    // Accepts GET from the proxy client but translates to PUT for the Discord API
    const guildMemberRoleMatch = url.pathname.match(/^\/discord\/guilds\/([^/]+)\/members\/([^/]+)\/roles\/([^/]+)$/);
    if (guildMemberRoleMatch && request.method === 'GET') {
      const guildId = guildMemberRoleMatch[1];
      const userId = guildMemberRoleMatch[2];
      const roleId = guildMemberRoleMatch[3];

      const discordRes = await fetch(
        `https://discord.com/api/v10/guilds/${guildId}/members/${userId}/roles/${roleId}`,
        {
          method: 'PUT',
          headers: {
            'Authorization': `Bot ${env.DISCORD_BOT_TOKEN}`,
          },
        }
      );

      const body = await discordRes.text();
      return new Response(body, { status: discordRes.status });
    }

    // Handle Discord guild member role removal
    // Matches /discord/guilds/<guild_id>/members/<user_id>/roles/<role_id>
    // Accepts GET from the proxy client but translates to DELETE for the Discord API
    if (guildMemberRoleMatch && request.method === 'DELETE') {
      const guildId = guildMemberRoleMatch[1];
      const userId = guildMemberRoleMatch[2];
      const roleId = guildMemberRoleMatch[3];

      const discordRes = await fetch(
        `https://discord.com/api/v10/guilds/${guildId}/members/${userId}/roles/${roleId}`,
        {
          method: 'DELETE',
          headers: {
            'Authorization': `Bot ${env.DISCORD_BOT_TOKEN}`,
          },
        }
      );

      return new Response(null, { status: discordRes.status });
    }

    // Handle Discord message posting
    if (url.pathname === "/discord/message") {
      const channelId = url.searchParams.get("channel_id");
      const content = url.searchParams.get("content");

      if (!channelId || !content) {
        return new Response("Missing channel_id or content", { status: 400 });
      }

      const discordRes = await fetch(
        `https://discord.com/api/v10/channels/${channelId}/messages`,
        {
          method: "POST",
          headers: {
            "Authorization": `Bot ${env.DISCORD_BOT_TOKEN}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ content }),
        }
      );

      const body = await discordRes.text();
      return new Response(body, { status: discordRes.status });
    }

    // Only allow GET requests for Solana RPC
    if (request.method !== 'GET') {
      return new Response('Method not allowed', { status: 405 });
    }
    
    // Extract RPC parameters from query string
    const method = url.searchParams.get('method');
    const wallet = url.searchParams.get('wallet');
    const signature = url.searchParams.get('signature');
    const encoding = url.searchParams.get('encoding') || 'jsonParsed';

    if (!method) {
      return new Response('Missing method parameter', { status: 400 });
    }

    // Build Solana RPC request body
    let rpcBody;
    const requestId = Math.floor(Math.random() * 1000000);

    if (method === 'getSignaturesForAddress') {
      if (!wallet) {
        return new Response('Missing wallet parameter for getSignaturesForAddress', { status: 400 });
      }

      // Validate limit parameter for getSignaturesForAddress
      const rawLimit = url.searchParams.get('limit');
      if (rawLimit === null) {
        return new Response(JSON.stringify({ error: 'missing required parameter: limit' }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' }
        });
      }
      if (!/^\d+$/.test(rawLimit) || !Number.isInteger(Number(rawLimit))) {
        return new Response(JSON.stringify({ error: 'limit must be a positive integer between 1 and 1000' }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' }
        });
      }
      const limitInt = parseInt(rawLimit, 10);
      if (limitInt < 1 || limitInt > 1000) {
        return new Response(JSON.stringify({ error: 'limit must be a positive integer between 1 and 1000' }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' }
        });
      }

      rpcBody = {
        jsonrpc: "2.0",
        id: requestId,
        method: "getSignaturesForAddress",
        params: [wallet, { limit: limitInt }]
      };
    } else if (method === 'getTransaction') {
      if (!signature) {
        return new Response('Missing signature parameter for getTransaction', { status: 400 });
      }
      rpcBody = {
        jsonrpc: "2.0",
        id: requestId,
        method: "getTransaction",
        params: [signature, { encoding: encoding }]
      };
    } else if (method === 'getHealth') {
      rpcBody = {
        jsonrpc: "2.0",
        id: requestId,
        method: "getHealth"
      };
    } else {
      return new Response('Unsupported method', { status: 400 });
    }

    // Forward request to Solana RPC (using devnet for testing)
    const rpcEndpoints = [
      `https://devnet.helius-rpc.com/?api-key=${env.HELIUS_API_KEY}`,
      'https://api.devnet.solana.com'
    ];
    
    let lastError = null;
    
    // Try each endpoint until one works
    for (const endpoint of rpcEndpoints) {
      try {
        const response = await fetch(endpoint, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
          },
          body: JSON.stringify(rpcBody)
        });

        const data = await response.text();
        
        // Check if response is successful and not blocked
        if (response.ok && !data.includes('"code": 403')) {
          // Return Solana RPC response
          return new Response(data, {
            status: response.status,
            headers: {
              'Content-Type': 'application/json',
              'Access-Control-Allow-Origin': '*'
            }
          });
        }
        
        // Store error and try next endpoint
        lastError = `Endpoint ${endpoint} returned: ${data}`;
      } catch (error) {
        lastError = `Endpoint ${endpoint} failed: ${error.message}`;
      }
    }
    
    // All endpoints failed
    return new Response(JSON.stringify({ 
      error: 'All RPC endpoints failed',
      details: lastError 
    }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' }
    });
  }
};
