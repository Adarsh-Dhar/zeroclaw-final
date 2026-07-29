// Cloudflare Worker for Solana RPC Proxy and Discord Message Proxy
// This worker accepts GET requests and forwards them as POST to Solana RPC and Discord API
// Deploy to Cloudflare Workers to get a public endpoint

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

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
    const limit = url.searchParams.get('limit') || '50';
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
      rpcBody = {
        jsonrpc: "2.0",
        id: requestId,
        method: "getSignaturesForAddress",
        params: [wallet, { limit: parseInt(limit) }]
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
      'https://devnet.helius-rpc.com/?api-key=REDACTED_API_KEY',
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
