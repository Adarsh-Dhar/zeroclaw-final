// Cloudflare Worker for Solana RPC Proxy and Discord Message Proxy
// This worker accepts GET requests and forwards them as POST to Solana RPC and Discord API
// Deploy to Cloudflare Workers to get a public endpoint

import nacl from 'tweetnacl';
import {
  Connection,
  PublicKey,
  SystemProgram,
  Transaction,
  TransactionInstruction,
} from '@solana/web3.js';

const MEMO_PROGRAM_ID = 'MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr';

// Tier config must match shared/skills/default/negotiate-subscription/SKILL.md exactly.
const TIER_CONFIG = {
  standard: { amountSol: 0.001, periodDays: 30 },
  premium: { amountSol: 0.0025, periodDays: 30 },
};

// Headers required on every Solana Actions response (spec v2.4).
const ACTIONS_CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET,POST,PUT,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, Content-Encoding, Accept-Encoding',
  'Access-Control-Expose-Headers': 'X-Action-Version, X-Blockchain-Ids',
  'X-Action-Version': '2.4',
  'X-Blockchain-Ids': 'solana:devnet',
};

function actionsJson(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...ACTIONS_CORS_HEADERS },
  });
}

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

// Builds an unsigned SOL transfer + memo transaction for a subscription
// payment. `payerPubkey` comes from the wallet's POST body — it is the
// ONLY attacker-influenceable input here. Recipient (Merchant_Wallet),
// amount (from TIER_CONFIG, server-side), and reference key are all fixed
// by the Worker itself, so a malicious `account` value can only make the
// wallet ask *that same account* to pay the fixed merchant the fixed
// amount — it cannot redirect funds or change the price.
async function buildSubscribeTransaction({
  payerPubkey,
  merchantWallet,
  amountSol,
  referenceKey,
  discordUserId,
  rpcEndpoint,
}) {
  const connection = new Connection(rpcEndpoint, 'confirmed');
  const payer = new PublicKey(payerPubkey);
  const merchant = new PublicKey(merchantWallet);
  const reference = new PublicKey(referenceKey);

  const transferIx = SystemProgram.transfer({
    fromPubkey: payer,
    toPubkey: merchant,
    lamports: Math.round(amountSol * 1_000_000_000),
  });
  // Solana Pay convention: append the reference key as a read-only,
  // non-signer account so getSignaturesForAddress(reference) finds it.
  transferIx.keys.push({ pubkey: reference, isSigner: false, isWritable: false });

  const memoIx = new TransactionInstruction({
    keys: [],
    programId: new PublicKey(MEMO_PROGRAM_ID),
    data: new TextEncoder().encode(`zeroclaw-sub:${discordUserId}`),
  });

  const { blockhash, lastValidBlockHeight } = await connection.getLatestBlockhash('finalized');
  const tx = new Transaction({ feePayer: payer, blockhash, lastValidBlockHeight })
    .add(transferIx, memoIx);

  const serialized = tx.serialize({ requireAllSignatures: false, verifySignatures: false });
  return serialized.toString('base64');
}

function buildPayPage({ tier, discordUserId, reference, proxyBaseUrl, cfg }) {
  const actionGetUrl = `${proxyBaseUrl}/actions/subscribe?tier=${encodeURIComponent(tier)}&discord_user_id=${encodeURIComponent(discordUserId)}&reference=${encodeURIComponent(reference)}`;
  return `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>ZeroClaw — Pay ${cfg.amountSol} SOL</title>
<script src="https://unpkg.com/@solana/web3.js@1.98.0/lib/index.iife.min.js"></script>
<style>body{font-family:system-ui;max-width:480px;margin:60px auto;padding:0 20px;text-align:center}
button{padding:12px 24px;font-size:16px;border-radius:8px;border:none;background:#512da8;color:#fff;cursor:pointer;margin-top:20px}
button:disabled{background:#999;cursor:default}
#status{margin-top:20px;color:#555;word-break:break-all}
.price{font-size:28px;font-weight:600;margin:12px 0}</style></head>
<body>
<h2>ZeroClaw ${tier} subscription</h2>
<div class="price">${cfg.amountSol} SOL / ${cfg.periodDays} days</div>
<p>Signing pays the merchant wallet directly from your own wallet. ZeroClaw never holds your keys or your funds.</p>
<button id="connect">Connect &amp; Pay</button>
<div id="status"></div>
<script>
const actionGetUrl = ${JSON.stringify(actionGetUrl)};
document.getElementById('connect').onclick = async () => {
  const btn = document.getElementById('connect');
  const statusEl = document.getElementById('status');
  btn.disabled = true;
  try {
    if (!window.solana || !window.solana.isPhantom) {
      statusEl.textContent = 'Phantom wallet not found. Install it and reload this page.';
      btn.disabled = false;
      return;
    }
    statusEl.textContent = 'Connecting wallet...';
    const resp = await window.solana.connect();
    const account = resp.publicKey.toString();

    statusEl.textContent = 'Requesting transaction...';
    const postResp = await fetch(actionGetUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ account }),
    });
    const postResult = await postResp.json();
    if (!postResp.ok || !postResult.transaction) {
      statusEl.textContent = 'Error building transaction: ' + (postResult.error || postResult.detail || 'unknown error');
      btn.disabled = false;
      return;
    }

    const txBytes = Uint8Array.from(atob(postResult.transaction), c => c.charCodeAt(0));
    const transaction = solanaWeb3.Transaction.from(txBytes);

    statusEl.textContent = 'Please approve in your wallet...';
    let signature;
    if (window.solana.signAndSendTransaction) {
      const sendResult = await window.solana.signAndSendTransaction(transaction);
      signature = sendResult.signature;
    } else {
      const signed = await window.solana.signTransaction(transaction);
      const connection = new solanaWeb3.Connection('https://api.devnet.solana.com', 'confirmed');
      signature = await connection.sendRawTransaction(signed.serialize());
    }

    statusEl.innerHTML = '✅ Payment sent! Tx: <a href="https://explorer.solana.com/tx/' + signature + '?cluster=devnet" target="_blank">' + signature + '</a><br>Return to Discord — your subscription will confirm shortly.';
  } catch (e) {
    console.error('Payment error:', e);
    statusEl.textContent = 'Error: ' + (e.message || 'Unexpected error');
    btn.disabled = false;
  }
};
</script>
</body></html>`;
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    // Declared once, up top — reused by multiple route handlers below
    // and the Solana RPC dispatch at the bottom of this function.
    const method = url.searchParams.get('method');

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

    // Self-hosted payment page — serves a connect-and-pay UI directly.
    // GET /pay?tier=...&discord_user_id=...&reference=...
    // Renders a connect-and-pay button that calls our own /actions/subscribe
    // GET+POST routes directly. No third-party service in this path at all.
    if (url.pathname === '/pay' && request.method === 'GET') {
      const tier = (url.searchParams.get('tier') || 'standard').toLowerCase();
      const discordUserId = url.searchParams.get('discord_user_id');
      const reference = url.searchParams.get('reference');
      const cfg = TIER_CONFIG[tier];

      if (!cfg) {
        return new Response(`Unknown tier "${tier}"`, { status: 400 });
      }
      if (!discordUserId || !reference) {
        return new Response('Missing discord_user_id or reference', { status: 400 });
      }

      const html = buildPayPage({
        tier,
        discordUserId,
        reference,
        proxyBaseUrl: env.PROXY_BASE_URL,
        cfg,
      });
      return new Response(html, { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
    }

    // Actions/Blinks: preflight
    if (url.pathname.startsWith('/actions') && request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: ACTIONS_CORS_HEADERS });
    }

    // actions.json — required so Actions-aware clients (wallets)
    // trust this origin as a registered Action provider.
    if (url.pathname === '/actions.json') {
      return actionsJson({
        rules: [
          { pathPattern: '/actions/**', apiPath: '/actions/**' },
          { pathPattern: '/actions.json', apiPath: '/actions.json' },
        ],
      });
    }

    // GET /actions/subscribe?tier=standard&discord_user_id=...&reference=...
    // Returns the Action preview metadata (what the wallet shows before signing).
    if (url.pathname === '/actions/subscribe' && request.method === 'GET') {
      const tier = (url.searchParams.get('tier') || 'standard').toLowerCase();
      const discordUserId = url.searchParams.get('discord_user_id');
      const reference = url.searchParams.get('reference');
      const cfg = TIER_CONFIG[tier];

      if (!cfg) {
        return actionsJson({ error: `unknown tier "${tier}"` }, 400);
      }
      if (!discordUserId || !reference) {
        return actionsJson({ error: 'missing discord_user_id or reference' }, 400);
      }

      const qs = `tier=${encodeURIComponent(tier)}&discord_user_id=${encodeURIComponent(discordUserId)}&reference=${encodeURIComponent(reference)}`;
      return actionsJson({
        type: 'action',
        title: `ZeroClaw ${tier} subscription`,
        description: `${cfg.amountSol} SOL / ${cfg.periodDays} days. Signing pays the merchant wallet directly — ZeroClaw never holds your keys.`,
        label: `Pay ${cfg.amountSol} SOL`,
        links: {
          actions: [
            { type: 'transaction', href: `/actions/subscribe?${qs}`, label: `Pay ${cfg.amountSol} SOL` },
          ],
        },
      });
    }

    // POST /actions/subscribe?tier=...&discord_user_id=...&reference=...
    // Body: { "account": "<payer base58 pubkey>" }  (this is the ONLY
    // attacker-influenceable field; see buildSubscribeTransaction comment.)
    if (url.pathname === '/actions/subscribe' && request.method === 'POST') {
      const tier = (url.searchParams.get('tier') || 'standard').toLowerCase();
      const discordUserId = url.searchParams.get('discord_user_id');
      const reference = url.searchParams.get('reference');
      const cfg = TIER_CONFIG[tier];

      if (!cfg) return actionsJson({ error: `unknown tier "${tier}"` }, 400);
      if (!discordUserId || !reference) {
        return actionsJson({ error: 'missing discord_user_id or reference' }, 400);
      }

      let body;
      try {
        body = await request.json();
      } catch {
        return actionsJson({ error: 'invalid_json' }, 400);
      }
      if (!body || !body.account) {
        return actionsJson({ error: 'missing account in request body' }, 400);
      }

      try {
        const transaction = await buildSubscribeTransaction({
          payerPubkey: body.account,
          merchantWallet: env.MERCHANT_WALLET,
          amountSol: cfg.amountSol,
          referenceKey: reference,
          discordUserId,
          rpcEndpoint: `https://devnet.helius-rpc.com/?api-key=${env.HELIUS_API_KEY}`,
        });
        return actionsJson({
          transaction,
          message: `ZeroClaw ${tier} subscription — ${cfg.amountSol} SOL for ${cfg.periodDays} days`,
        });
      } catch (e) {
        return actionsJson({ error: 'tx_build_failed', detail: String(e) }, 500);
      }
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
        `https://discord.com/api/v10/users/@me/channels`,
        {
          method: 'POST',
          headers: {
            'Authorization': `Bot ${env.DISCORD_BOT_TOKEN}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ recipient_id: userId }),
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
    if (channelMessagesMatch && request.method !== 'POST') {
      const channelId = channelMessagesMatch[1];
      const limit = url.searchParams.get('limit');
      const before = url.searchParams.get('before');
      const after = url.searchParams.get('after');

      // Build Discord API URL, only include limit/before/after if provided
      // (before/after enables paging; after is used for incremental polling)
      const discordUrl = new URL(`https://discord.com/api/v10/channels/${channelId}/messages`);
      if (limit !== null) {
        discordUrl.searchParams.set('limit', limit);
      }
      if (before !== null) {
        discordUrl.searchParams.set('before', before);
      }
      if (after !== null) {
        discordUrl.searchParams.set('after', after);
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

    // Bulk-delete messages in a channel (Discord requires 2-100 IDs per call,
    // and every message must be under 14 days old).
    // POST /discord/channels/<channel_id>/messages/bulk-delete
    // Body: { "messages": ["id1", "id2", ...] }
    const bulkDeleteMatch = url.pathname.match(/^\/discord\/channels\/([^/]+)\/messages\/bulk-delete$/);
    if (bulkDeleteMatch && request.method === 'POST') {
      const channelId = bulkDeleteMatch[1];
      let body;
      try {
        body = await request.json();
      } catch {
        return new Response(JSON.stringify({ error: 'invalid_json' }), { status: 400 });
      }
      if (!body || !Array.isArray(body.messages) || body.messages.length < 2 || body.messages.length > 100) {
        return new Response(JSON.stringify({ error: 'messages must be an array of 2-100 IDs' }), { status: 400 });
      }

      const discordRes = await fetch(
        `https://discord.com/api/v10/channels/${channelId}/messages/bulk-delete`,
        {
          method: 'POST',
          headers: {
            'Authorization': `Bot ${env.DISCORD_BOT_TOKEN}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({ messages: body.messages }),
        }
      );

      const responseBody = discordRes.status === 204 ? '{"success":true}' : await discordRes.text();
      return new Response(responseBody, {
        status: discordRes.status === 204 ? 200 : discordRes.status,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // Delete a single message (for anything older than 14 days, which
    // bulk-delete refuses to touch).
    // DELETE /discord/channels/<channel_id>/messages/<message_id>
    // (also accepts GET with ?method=DELETE, same override pattern used elsewhere)
    const singleDeleteMatch = url.pathname.match(/^\/discord\/channels\/([^/]+)\/messages\/([^/]+)$/);
    if (singleDeleteMatch) {
      const channelId = singleDeleteMatch[1];
      const messageId = singleDeleteMatch[2];
      const isDelete = request.method === 'DELETE' ||
        (request.method === 'GET' && url.searchParams.get('method') === 'DELETE');

      if (isDelete) {
        const discordRes = await fetch(
          `https://discord.com/api/v10/channels/${channelId}/messages/${messageId}`,
          { method: 'DELETE', headers: { 'Authorization': `Bot ${env.DISCORD_BOT_TOKEN}` } }
        );
        const responseBody = discordRes.status === 204 ? '{"success":true}' : await discordRes.text();
        return new Response(responseBody, {
          status: discordRes.status === 204 ? 200 : discordRes.status,
          headers: { 'Content-Type': 'application/json' },
        });
      }
    }

    // GET /discord/guilds/<guild_id>/members/list?limit=1000
    // Returns a shaped-down array of {id, username} for non-bot members.
    // Distinct from /members (which pages raw member objects) — this route
    // is purpose-built for the welcome_outreach SOP so it doesn't have to
    // parse full member objects or handle pagination itself.
    const guildMembersListMatch = url.pathname.match(/^\/discord\/guilds\/([^/]+)\/members\/list$/);
    if (guildMembersListMatch && request.method === 'GET') {
      const guildId = guildMembersListMatch[1];
      const limit = url.searchParams.get('limit') || '1000';
      const resp = await fetch(
        `https://discord.com/api/v10/guilds/${guildId}/members?limit=${limit}`,
        { headers: { Authorization: `Bot ${env.DISCORD_BOT_TOKEN}` } }
      );
      if (!resp.ok) {
        const errBody = await resp.text();
        return new Response(errBody, { status: resp.status, headers: { 'Content-Type': 'application/json' } });
      }
      const members = await resp.json();
      const shaped = Array.isArray(members)
        ? members
            .filter(m => m.user && !m.user.bot)
            .map(m => ({ id: m.user.id, username: m.user.username }))
        : [];
      return new Response(JSON.stringify(shaped), {
        headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }
      });
    }

    // Handle Discord guild members list
    // Matches /discord/guilds/<guild_id>/members
    const guildMembersMatch = url.pathname.match(/^\/discord\/guilds\/([^/]+)\/members$/);
    if (guildMembersMatch && request.method === 'GET') {
      const guildId = guildMembersMatch[1];
      const after = url.searchParams.get('after');
      const limit = url.searchParams.get('limit') || '100';
      
      let discordUrl = `https://discord.com/api/v10/guilds/${guildId}/members?limit=${limit}`;
      if (after) {
        discordUrl += `&after=${after}`;
      }
      
      const discordRes = await fetch(
        discordUrl,
        {
          method: 'GET',
          headers: { 'Authorization': `Bot ${env.DISCORD_BOT_TOKEN}` },
        }
      );
      
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

    // Handle Discord guild member role operations (grant and remove)
    // Matches /discord/guilds/<guild_id>/members/<user_id>/roles/<role_id>
    // Accepts GET with ?method=PUT or ?method=DELETE query parameter, or actual PUT/DELETE method
    // Translates to PUT or DELETE for the Discord API
    const guildMemberRoleMatch = url.pathname.match(/^\/discord\/guilds\/([^/]+)\/members\/([^/]+)\/roles\/([^/]+)$/);
    const methodOverride = url.searchParams.get('method');
    if (guildMemberRoleMatch) {
      const guildId = guildMemberRoleMatch[1];
      const userId = guildMemberRoleMatch[2];
      const roleId = guildMemberRoleMatch[3];

      // Determine the actual HTTP method to use
      let discordMethod = null;
      if (request.method === 'PUT' || (request.method === 'GET' && methodOverride === 'PUT')) {
        discordMethod = 'PUT';
      } else if (request.method === 'DELETE' || (request.method === 'GET' && methodOverride === 'DELETE')) {
        discordMethod = 'DELETE';
      }

      if (discordMethod) {
        const discordRes = await fetch(
          `https://discord.com/api/v10/guilds/${guildId}/members/${userId}/roles/${roleId}`,
          {
            method: discordMethod,
            headers: {
              'Authorization': `Bot ${env.DISCORD_BOT_TOKEN}`,
            },
          }
        );

        const body = await discordRes.text();
        return new Response(body, { status: discordRes.status });
      }
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
    
    // Extract RPC parameters from query string (`method` is declared once
    // at the top of fetch() and reused here)
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

    // DEBUG: Network fault injection for testing (simulate network interruption)
    // Commented out for production - uncomment for testing network interruption scenarios
    // if (url.searchParams.get('simulate_fail') === '1') {
    //   await new Promise(r => setTimeout(r, 8000)); // hang like a real stalled connection
    //   return new Response('Simulated network failure', { status: 599 });
    // }

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
          // Log fallback if this is not the first endpoint
          if (endpoint !== rpcEndpoints[0]) {
            console.log(JSON.stringify({ event: 'rpc_fallback_used', from: rpcEndpoints[0], to: endpoint }));
          }
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
        console.log(JSON.stringify({ event: 'rpc_endpoint_failed', endpoint, error: data }));
      } catch (error) {
        lastError = `Endpoint ${endpoint} failed: ${error.message}`;
        console.log(JSON.stringify({ event: 'rpc_endpoint_failed', endpoint, error: error.message }));
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
