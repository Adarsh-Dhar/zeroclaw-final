// Cloudflare Worker for Solana RPC Proxy and Discord Message Proxy
// This worker accepts GET requests and forwards them as POST to Solana RPC and Discord API
// Deploy to Cloudflare Workers to get a public endpoint

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
    if (guildMemberRoleMatch) {
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
