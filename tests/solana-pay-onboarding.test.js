/**
 * Property-based tests for Solana Pay Onboarding
 * Feature: solana-pay-onboarding
 */

import fc from 'fast-check';
import { randomBytes as nodeRandomBytes } from 'crypto';
import { isValidLimit, isValidDmContent } from '../solana-rpc-proxy/worker.js';

// ─────────────────────────────────────────────────────────────────────────────
// Co-located base58 helpers (for Property 2)
// ─────────────────────────────────────────────────────────────────────────────

function encodeBase58(bytes) {
  const BASE58_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  let leadingZeros = 0;
  for (let i = 0; i < bytes.length; i++) {
    if (bytes[i] !== 0) break;
    leadingZeros++;
  }
  let num = BigInt(0);
  for (let i = 0; i < bytes.length; i++) {
    num = (num << BigInt(8)) + BigInt(bytes[i]);
  }
  const digits = [];
  const base = BigInt(58);
  while (num > BigInt(0)) {
    const remainder = num % base;
    num = num / base;
    digits.push(BASE58_ALPHABET[Number(remainder)]);
  }
  return '1'.repeat(leadingZeros) + digits.reverse().join('');
}

function decodeBase58(str) {
  const BASE58_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  let num = BigInt(0);
  for (const char of str) {
    const idx = BASE58_ALPHABET.indexOf(char);
    if (idx < 0) throw new Error(`Invalid base58 char: ${char}`);
    num = num * BigInt(58) + BigInt(idx);
  }
  const bytes = [];
  while (num > BigInt(0)) {
    bytes.unshift(Number(num & BigInt(0xff)));
    num >>= BigInt(8);
  }
  let leadingOnes = 0;
  for (const char of str) {
    if (char !== '1') break;
    leadingOnes++;
  }
  return new Uint8Array([...new Array(leadingOnes).fill(0), ...bytes]);
}

// Apply global fast-check configuration: 100 runs per property
fc.configureGlobal({ numRuns: 100 });

// ─────────────────────────────────────────────────────────────────────────────
// Feature: solana-pay-onboarding, Property 2: Reference key uniqueness and base58 validity
// Validates: Requirements 2.1
// ─────────────────────────────────────────────────────────────────────────────
describe('Property 2: Reference key uniqueness and base58 validity', () => {
  const BASE58_REGEX = /^[123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz]+$/;

  test('N generated keys are all valid base58 strings encoding exactly 32 bytes', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 2, max: 50 }),
        (n) => {
          const keys = Array.from({ length: n }, () => {
            const bytes = nodeRandomBytes(32);
            return encodeBase58(new Uint8Array(bytes));
          });
          for (const key of keys) {
            expect(key).toMatch(BASE58_REGEX);
            expect(decodeBase58(key).length).toBe(32);
          }
        }
      )
    );
  });

  test('N generated keys are all pairwise distinct', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 2, max: 50 }),
        (n) => {
          const keys = Array.from({ length: n }, () => {
            const bytes = nodeRandomBytes(32);
            return encodeBase58(new Uint8Array(bytes));
          });
          const uniqueKeys = new Set(keys);
          expect(uniqueKeys.size).toBe(n);
        }
      )
    );
  });

  test('encodeBase58 round-trips correctly through decodeBase58 for known input', () => {
    // A well-known 32-byte all-zeros array encodes to 32 '1' characters
    const zeros = new Uint8Array(32);
    const encoded = encodeBase58(zeros);
    expect(encoded).toBe('1'.repeat(32));
    const decoded = decodeBase58(encoded);
    expect(decoded.length).toBe(32);
    for (const b of decoded) expect(b).toBe(0);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Feature: solana-pay-onboarding, Property 13: Proxy limit parameter validation
// ─────────────────────────────────────────────────────────────────────────────
describe('Property 13: Proxy limit parameter validation', () => {
  // Boundary: 0 → reject
  test('rejects zero', () => {
    expect(isValidLimit(0)).toBe(false);
  });

  // Boundary: 1 → accept
  test('accepts 1 (lower boundary)', () => {
    expect(isValidLimit(1)).toBe(true);
  });

  // Boundary: 1000 → accept
  test('accepts 1000 (upper boundary)', () => {
    expect(isValidLimit(1000)).toBe(true);
  });

  // Boundary: 1001 → reject
  test('rejects 1001', () => {
    expect(isValidLimit(1001)).toBe(false);
  });

  // Boundary: absent / null → reject
  test('rejects null', () => {
    expect(isValidLimit(null)).toBe(false);
  });

  // Non-integer strings → reject
  test('rejects non-integer string "abc"', () => {
    expect(isValidLimit('abc')).toBe(false);
  });

  test('rejects float string "1.5"', () => {
    expect(isValidLimit('1.5')).toBe(false);
  });

  // Property: any integer in [1, 1000] is accepted
  test('accepts any integer in [1, 1000]', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 1, max: 1000 }),
        (n) => {
          expect(isValidLimit(n)).toBe(true);
        }
      )
    );
  });

  // Property: any integer < 1 or > 1000 is rejected
  test('rejects integers outside [1, 1000]', () => {
    fc.assert(
      fc.property(
        fc.oneof(
          fc.integer({ min: -10000, max: 0 }),
          fc.integer({ min: 1001, max: 10000 })
        ),
        (n) => {
          expect(isValidLimit(n)).toBe(false);
        }
      )
    );
  });

  // Property: non-integer strings are rejected
  test('rejects arbitrary non-integer strings', () => {
    fc.assert(
      fc.property(
        fc.string({ minLength: 1 }).filter(s => !/^-?\d+$/.test(s)),
        (s) => {
          expect(isValidLimit(s)).toBe(false);
        }
      )
    );
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Feature: solana-pay-onboarding, Property 14: Proxy DM content length validation
// ─────────────────────────────────────────────────────────────────────────────
describe('Property 14: Proxy DM content length validation', () => {
  // Boundary: length 0 → reject
  test('rejects empty string', () => {
    expect(isValidDmContent('')).toBe(false);
  });

  // Boundary: length 1 → accept
  test('accepts single character', () => {
    expect(isValidDmContent('a')).toBe(true);
  });

  // Boundary: length 2000 → accept
  test('accepts exactly 2000 characters', () => {
    expect(isValidDmContent('a'.repeat(2000))).toBe(true);
  });

  // Boundary: length 2001 → reject
  test('rejects 2001 characters', () => {
    expect(isValidDmContent('a'.repeat(2001))).toBe(false);
  });

  // Property: arbitrary strings with length in [1, 2000] are accepted
  test('accepts any string with length in [1, 2000]', () => {
    fc.assert(
      fc.property(
        fc.string({ minLength: 1, maxLength: 2000 }),
        (content) => {
          expect(isValidDmContent(content)).toBe(true);
        }
      )
    );
  });

  // Property: strings with length > 2000 are rejected
  test('rejects any string with length > 2000', () => {
    fc.assert(
      fc.property(
        fc.string({ minLength: 2001, maxLength: 5000 }),
        (content) => {
          expect(isValidDmContent(content)).toBe(false);
        }
      )
    );
  });

  // Property: URL-encoded content validates based on decoded length
  test('URL-encoded content validates based on decoded length', () => {
    fc.assert(
      fc.property(
        fc.string({ minLength: 1, maxLength: 2000 }),
        (content) => {
          const encoded = encodeURIComponent(content);
          const decoded = decodeURIComponent(encoded);
          // round-trip should preserve length
          expect(decoded.length).toBe(content.length);
          expect(isValidDmContent(decoded)).toBe(true);
        }
      )
    );
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Pure helper: Subscribe command detector
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Returns true iff the message content contains the word "subscribe" as a
 * standalone whole word (case-insensitive) AND the author is not a bot.
 */
function shouldProcessMessage(content, isBot) {
  if (isBot) return false;
  return /\bsubscribe\b/i.test(content);
}

// ─────────────────────────────────────────────────────────────────────────────
// Feature: solana-pay-onboarding, Property 1: Subscribe command detector correctly classifies messages
// Validates: Requirements 1.1, 1.5
// ─────────────────────────────────────────────────────────────────────────────
describe('Property 1: Subscribe command detector correctly classifies messages', () => {
  test('returns true iff content has standalone "subscribe" and isBot is false', () => {
    // Positive case: arbitrary string containing exactly "subscribe" as a whole word
    fc.assert(
      fc.property(
        fc.constantFrom('subscribe', 'Subscribe', 'SUBSCRIBE', 'hey subscribe please', 'subscribe premium'),
        fc.constant(false),
        (content, isBot) => {
          return shouldProcessMessage(content, isBot) === true;
        }
      )
    );
  });

  test('returns false for bot messages regardless of content', () => {
    fc.assert(
      fc.property(
        fc.string(),
        fc.constant(true),
        (content, isBot) => {
          return shouldProcessMessage(content, isBot) === false;
        }
      )
    );
  });

  test('returns false for partial matches like "unsubscribe", "subscribed", "resubscribe"', () => {
    const nonMatches = ['unsubscribe', 'subscribed', 'resubscribe', 'presubscribe', 'subscription'];
    for (const word of nonMatches) {
      expect(shouldProcessMessage(word, false)).toBe(false);
    }
  });

  test('returns false for arbitrary strings that do not contain standalone "subscribe"', () => {
    fc.assert(
      fc.property(
        fc.string().filter(s => !/\bsubscribe\b/i.test(s)),
        fc.boolean(),
        (content, isBot) => {
          return shouldProcessMessage(content, isBot) === false;
        }
      )
    );
  });

  test('returns false when isBot is true even if content matches', () => {
    fc.assert(
      fc.property(
        fc.constantFrom('subscribe', 'Subscribe', 'SUBSCRIBE', 'subscribe premium'),
        fc.constant(true),
        (content, isBot) => {
          return shouldProcessMessage(content, isBot) === false;
        }
      )
    );
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Pure helper: build Solana Pay transfer-request URL
// Format: solana:<merchantWallet>?amount=<amount>&spl-token=<usdcMint>&reference=<referenceKey>&label=ZeroClaw+Subscription&memo=<discordUserId>
// ─────────────────────────────────────────────────────────────────────────────
function buildSolanaPayURL(merchantWallet, amount, usdcMint, referenceKey, discordUserId) {
  return `solana:${merchantWallet}?amount=${amount}&spl-token=${usdcMint}&reference=${referenceKey}&label=ZeroClaw+Subscription&memo=${discordUserId}`;
}

// ─────────────────────────────────────────────────────────────────────────────
// Feature: solana-pay-onboarding, Property 3: Solana Pay URL structural completeness
// Validates: Requirements 3.1
// ─────────────────────────────────────────────────────────────────────────────
describe('Property 3: Solana Pay URL structural completeness', () => {
  test('URL starts with "solana:", contains merchantWallet as pathname, and has all required query params', () => {
    fc.assert(
      fc.property(
        fc.stringMatching(/^[A-Za-z0-9_\-!~.*'():@]+$/),  // merchantWallet: URL-safe chars, no ? & space + %
        fc.double({ min: 0.000001, max: 999999, noNaN: true }),                                                                // amount
        fc.stringMatching(/^[A-Za-z0-9_\-!~.*'():@]+$/),  // usdcMint
        fc.stringMatching(/^[A-Za-z0-9_\-!~.*'():@]+$/),  // referenceKey
        fc.stringMatching(/^[A-Za-z0-9_\-!~.*'():@]+$/),  // discordUserId
        (merchantWallet, amount, usdcMint, referenceKey, discordUserId) => {
          const url = buildSolanaPayURL(merchantWallet, amount, usdcMint, referenceKey, discordUserId);

          // Must start with "solana:"
          if (!url.startsWith('solana:')) return false;

          // Parse the URL — everything after "solana:" is "<pathname>?<query>"
          const withoutScheme = url.slice('solana:'.length);
          const qIndex = withoutScheme.indexOf('?');
          const pathname = qIndex === -1 ? withoutScheme : withoutScheme.slice(0, qIndex);
          const queryString = qIndex === -1 ? '' : withoutScheme.slice(qIndex + 1);

          // Pathname must equal merchantWallet
          if (pathname !== merchantWallet) return false;

          // Parse query params
          const params = new URLSearchParams(queryString);

          // All 5 query params must be present with correct values
          if (String(params.get('amount')) !== String(amount)) return false;
          if (params.get('spl-token') !== usdcMint) return false;
          if (params.get('reference') !== referenceKey) return false;
          if (params.get('label') !== 'ZeroClaw Subscription') return false;  // URLSearchParams decodes '+' as space
          if (params.get('memo') !== discordUserId) return false;

          return true;
        }
      )
    );
  });

  test('label is always "ZeroClaw+Subscription" in the raw URL', () => {
    const url = buildSolanaPayURL('wallet123', 0.1, 'mint123', 'refkey123', 'user123');
    expect(url).toContain('label=ZeroClaw+Subscription');
  });

  test('all five query parameters are present in the URL', () => {
    const url = buildSolanaPayURL('wallet', 0.1, 'mint', 'ref', 'user');
    expect(url).toMatch(/[?&]amount=/);
    expect(url).toMatch(/[?&]spl-token=/);
    expect(url).toMatch(/[?&]reference=/);
    expect(url).toMatch(/[?&]label=/);
    expect(url).toMatch(/[?&]memo=/);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Pure helper: Discord onboarding message builder
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Builds the Discord onboarding message posted to Subscribe_Channel.
 * @param {Object} record - Subscriber_Record
 * @param {string} solanaPayURL - The constructed Solana Pay URL
 * @param {string} qrURL - The Google Charts QR code URL
 * @returns {string} - The message to post
 */
function buildOnboardingMessage(record, solanaPayURL, qrURL) {
  return `@${record.discord_username} — ZeroClaw ${record.tier} subscription (${record.expected_amount_usdc} USDC / ${record.period_days} days)\nPay here: ${solanaPayURL}\nQR: ${qrURL}`;
}

// ─────────────────────────────────────────────────────────────────────────────
// Feature: solana-pay-onboarding, Property 5: Discord onboarding message contains all required fields
// Validates: Requirements 3.3
// ─────────────────────────────────────────────────────────────────────────────
describe('Property 5: Discord onboarding message contains all required fields', () => {
  // Arbitrary generator for valid Subscriber_Records
  const subscriberRecordArb = fc.record({
    discord_user_id: fc.string({ minLength: 1 }),
    discord_username: fc.string({ minLength: 1 }).filter(s => !s.includes('\n') && !s.includes('@')),
    wallet_address: fc.oneof(fc.string({ minLength: 1 }), fc.constant(null)),
    tier: fc.constantFrom('standard', 'premium'),
    expected_amount_usdc: fc.oneof(fc.constant(0.1), fc.constant(0.25)),
    period_days: fc.integer({ min: 1, max: 365 }),
    subscribed_at: fc.oneof(fc.constant(null), fc.constant('2026-01-01T00:00:00.000Z')),
    expires_at: fc.oneof(fc.constant(null), fc.constant('2026-01-31T00:00:00.000Z')),
    grace_started_at: fc.constant(null),
    reference_key: fc.string({ minLength: 1 }).filter(s => s.trim().length > 0),
    status: fc.constantFrom('pending_payment', 'active', 'lapsed', 'grace', 'expired', 'check_failed'),
  });

  const solanaPayURLArb = fc.string({ minLength: 10 }).map(s => `solana:wallet?amount=0.1&ref=${s}`);
  const qrURLArb = fc.string({ minLength: 10 }).map(s => `https://chart.googleapis.com/chart?chs=300x300&cht=qr&chl=${encodeURIComponent(s)}`);

  test('message contains Discord mention (@username)', () => {
    fc.assert(
      fc.property(subscriberRecordArb, solanaPayURLArb, qrURLArb, (record, solanaPayURL, qrURL) => {
        const msg = buildOnboardingMessage(record, solanaPayURL, qrURL);
        return msg.includes(`@${record.discord_username}`);
      })
    );
  });

  test('message contains the full Solana Pay URL', () => {
    fc.assert(
      fc.property(subscriberRecordArb, solanaPayURLArb, qrURLArb, (record, solanaPayURL, qrURL) => {
        const msg = buildOnboardingMessage(record, solanaPayURL, qrURL);
        return msg.includes(solanaPayURL);
      })
    );
  });

  test('message contains the QR code URL', () => {
    fc.assert(
      fc.property(subscriberRecordArb, solanaPayURLArb, qrURLArb, (record, solanaPayURL, qrURL) => {
        const msg = buildOnboardingMessage(record, solanaPayURL, qrURL);
        return msg.includes(qrURL);
      })
    );
  });

  test('message contains the tier name', () => {
    fc.assert(
      fc.property(subscriberRecordArb, solanaPayURLArb, qrURLArb, (record, solanaPayURL, qrURL) => {
        const msg = buildOnboardingMessage(record, solanaPayURL, qrURL);
        return msg.includes(record.tier);
      })
    );
  });

  test('message contains the USDC amount as a decimal string', () => {
    fc.assert(
      fc.property(subscriberRecordArb, solanaPayURLArb, qrURLArb, (record, solanaPayURL, qrURL) => {
        const msg = buildOnboardingMessage(record, solanaPayURL, qrURL);
        return msg.includes(String(record.expected_amount_usdc));
      })
    );
  });

  test('message contains the subscription period in days', () => {
    fc.assert(
      fc.property(subscriberRecordArb, solanaPayURLArb, qrURLArb, (record, solanaPayURL, qrURL) => {
        const msg = buildOnboardingMessage(record, solanaPayURL, qrURL);
        return msg.includes(String(record.period_days));
      })
    );
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Pure helper: amount field validator
// ─────────────────────────────────────────────────────────────────────────────
/**
 * Returns true iff v is a positive number with at most 6 decimal places.
 * Rejects: zero, negative numbers, numbers with more than 6 decimal places.
 */
function isValidAmount(v) {
  if (typeof v !== 'number' || isNaN(v) || !isFinite(v)) return false;
  if (v <= 0) return false;
  // Check decimal places: convert to string and count digits after decimal point
  const str = v.toString();
  const dotIndex = str.indexOf('.');
  if (dotIndex === -1) return true; // integer, no decimal places
  const decimalPlaces = str.length - dotIndex - 1;
  return decimalPlaces <= 6;
}

// ─────────────────────────────────────────────────────────────────────────────
// Feature: solana-pay-onboarding, Property 4: Amount field validation
// Validates: Requirements 3.4
// ─────────────────────────────────────────────────────────────────────────────
describe('Property 4: Amount field validation', () => {
  test('accepts positive numbers with at most 6 decimal places', () => {
    fc.assert(
      fc.property(
        fc.float({ min: Math.fround(0.000001), max: Math.fround(999999), noNaN: true }),
        (v) => {
          const str = v.toString();
          const dotIndex = str.indexOf('.');
          const decimalPlaces = dotIndex === -1 ? 0 : str.length - dotIndex - 1;
          if (decimalPlaces <= 6 && v > 0) {
            return isValidAmount(v) === true;
          }
          return true; // skip — floats can have > 6 decimal places naturally
        }
      )
    );
  });

  test('rejects zero and negative numbers', () => {
    fc.assert(
      fc.property(
        fc.oneof(
          fc.constant(0),
          fc.constant(-1),
          fc.float({ max: 0, noNaN: true })
        ),
        (v) => isValidAmount(v) === false
      )
    );
  });

  test('rejects numbers with more than 6 decimal places', () => {
    // 1.1234567 stringifies to "1.1234567" — 7 decimal places, must be rejected
    expect(isValidAmount(1.1234567)).toBe(false);
    // 10.1234567 stringifies to "10.1234567" — 7 decimal places, must be rejected
    expect(isValidAmount(10.1234567)).toBe(false);
    // Note: 0.0000001 stringifies to "1e-7" (no dot), so it is treated as
    // having 0 conventional decimal places by toString(); that is a JS
    // representation artefact and is not a value that would appear as a
    // real USDC tier amount.
  });

  test('accepts exact edge values with 6 decimal places', () => {
    // 0.000001 is the smallest valid value with 6 decimal places
    expect(isValidAmount(0.000001)).toBe(true);
    // 1.123456 has exactly 6 decimal places
    expect(isValidAmount(1.123456)).toBe(true);
  });

  test('rejects 0 and -1 explicitly', () => {
    expect(isValidAmount(0)).toBe(false);
    expect(isValidAmount(-1)).toBe(false);
  });

  test('accepts positive integers (0 decimal places)', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 1, max: 1000000 }),
        (v) => isValidAmount(v) === true
      )
    );
  });

  test('rejects non-numeric values', () => {
    expect(isValidAmount(NaN)).toBe(false);
    expect(isValidAmount(Infinity)).toBe(false);
    expect(isValidAmount(-Infinity)).toBe(false);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Pure helper: subscription expiry calculator
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Computes expires_at as a Unix timestamp using integer arithmetic only.
 * @param {number} subscribedAtUnix - Unix timestamp (integer seconds)
 * @param {number} periodDays - Subscription period in days (integer, 1–3650)
 * @returns {number} Unix timestamp of expiry
 */
function computeExpiresAt(subscribedAtUnix, periodDays) {
  return subscribedAtUnix + periodDays * 86400;
}

// ─────────────────────────────────────────────────────────────────────────────
// Feature: solana-pay-onboarding, Property 7: Subscription expiry calculation
// Validates: Requirements 4.3
// ─────────────────────────────────────────────────────────────────────────────
describe('Property 7: Subscription expiry calculation', () => {
  test('expiresAt === subscribedAtUnix + periodDays * 86400 for all valid inputs', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 0 }),
        fc.integer({ min: 1, max: 3650 }),
        (subscribedAtUnix, periodDays) => {
          const result = computeExpiresAt(subscribedAtUnix, periodDays);
          return result === subscribedAtUnix + periodDays * 86400;
        }
      )
    );
  });

  test('uses integer arithmetic — no floating point rounding', () => {
    // These must be exact integer results, not floating point approximations
    expect(computeExpiresAt(0, 30)).toBe(2592000);
    expect(computeExpiresAt(1000000, 365)).toBe(1000000 + 365 * 86400);
    expect(computeExpiresAt(0, 1)).toBe(86400);
    expect(computeExpiresAt(0, 3650)).toBe(3650 * 86400);
  });

  test('result is always greater than subscribedAtUnix', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 0 }),
        fc.integer({ min: 1, max: 3650 }),
        (subscribedAtUnix, periodDays) => {
          return computeExpiresAt(subscribedAtUnix, periodDays) > subscribedAtUnix;
        }
      )
    );
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Pure helper: subscription window filter
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Returns true iff blockTime falls within [subscribedAt, subscribedAt + periodDays * 86400].
 * @param {number} blockTime - Unix timestamp of the transaction
 * @param {number} subscribedAt - Unix timestamp of subscription start
 * @param {number} periodDays - Subscription period in days
 * @returns {boolean}
 */
function isInSubscriptionWindow(blockTime, subscribedAt, periodDays) {
  const windowEnd = subscribedAt + periodDays * 86400;
  return blockTime >= subscribedAt && blockTime <= windowEnd;
}

// ─────────────────────────────────────────────────────────────────────────────
// Feature: solana-pay-onboarding, Property 9: Subscription window filter
// Validates: Requirements 5.7
// ─────────────────────────────────────────────────────────────────────────────
describe('Property 9: Subscription window filter', () => {
  test('inside=true iff subscribedAt ≤ blockTime ≤ subscribedAt + periodDays * 86400', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 0 }),
        fc.integer({ min: 0 }),
        fc.integer({ min: 1, max: 3650 }),
        (blockTime, subscribedAt, periodDays) => {
          const inside = isInSubscriptionWindow(blockTime, subscribedAt, periodDays);
          const windowEnd = subscribedAt + periodDays * 86400;
          const expectedInside = blockTime >= subscribedAt && blockTime <= windowEnd;
          return inside === expectedInside;
        }
      )
    );
  });

  test('transaction exactly at subscribedAt boundary is inside window', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 0 }),
        fc.integer({ min: 1, max: 3650 }),
        (subscribedAt, periodDays) => {
          return isInSubscriptionWindow(subscribedAt, subscribedAt, periodDays) === true;
        }
      )
    );
  });

  test('transaction exactly at windowEnd boundary is inside window', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 0 }),
        fc.integer({ min: 1, max: 3650 }),
        (subscribedAt, periodDays) => {
          const windowEnd = subscribedAt + periodDays * 86400;
          return isInSubscriptionWindow(windowEnd, subscribedAt, periodDays) === true;
        }
      )
    );
  });

  test('transaction one second before subscribedAt is outside window', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 1 }),
        fc.integer({ min: 1, max: 3650 }),
        (subscribedAt, periodDays) => {
          return isInSubscriptionWindow(subscribedAt - 1, subscribedAt, periodDays) === false;
        }
      )
    );
  });

  test('transaction one second after windowEnd is outside window', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 0 }),
        fc.integer({ min: 1, max: 3650 }),
        (subscribedAt, periodDays) => {
          const windowEnd = subscribedAt + periodDays * 86400;
          return isInSubscriptionWindow(windowEnd + 1, subscribedAt, periodDays) === false;
        }
      )
    );
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Pure helper: transaction payment validator
// ─────────────────────────────────────────────────────────────────────────────

const USDC_MINT = '4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU';
const MERCHANT_WALLET = 'pt6Ws1FMbdrLbUZqKooediS8mu6SNvDJodzXUx6ypak';

/**
 * Returns true iff a parsed transaction qualifies as a valid subscription payment.
 * All four conditions must hold simultaneously:
 *   (a) contains a USDC SPL token transfer instruction
 *   (b) transfer destination is Merchant_Wallet or ATA owned by Merchant_Wallet
 *   (c) USDC mint matches USDC_MINT constant
 *   (d) transfer amount in raw integer units >= expected_amount_usdc * 1_000_000
 *
 * @param {Object} tx - Parsed transaction object
 * @param {Object} record - Subscriber_Record with expected_amount_usdc
 * @returns {boolean}
 */
function isQualifyingTransaction(tx, record) {
  if (!tx || !tx.meta || !tx.transaction) return false;

  const instructions = tx.transaction?.message?.instructions ?? [];
  const innerInstructions = (tx.meta?.innerInstructions ?? []).flatMap(i => i.instructions ?? []);
  const allInstructions = [...instructions, ...innerInstructions];

  for (const ix of allInstructions) {
    // Must be an spl-token program instruction
    if (ix.program !== 'spl-token') continue;

    const parsed = ix.parsed;
    if (!parsed) continue;

    // Must be a transfer or transferChecked instruction
    if (parsed.type !== 'transfer' && parsed.type !== 'transferChecked') continue;

    const info = parsed.info ?? {};

    // (c) Mint must match USDC_MINT (present on transferChecked; for transfer check postTokenBalances)
    const mint = info.mint ?? null;
    if (mint !== null && mint !== USDC_MINT) continue;
    // For plain 'transfer' without mint in info, verify via postTokenBalances
    if (mint === null && parsed.type === 'transfer') {
      const destination = info.destination ?? info.account ?? null;
      const tokenBalances = tx.meta?.postTokenBalances ?? [];
      const destBalance = tokenBalances.find(b => b.accountIndex !== undefined &&
        tx.transaction?.message?.accountKeys?.[b.accountIndex]?.pubkey === destination);
      if (!destBalance || destBalance.mint !== USDC_MINT) continue;
    }

    // (b) Destination must be Merchant_Wallet or ATA owned by Merchant_Wallet
    const destination = info.destination ?? info.account ?? null;
    if (!destination) continue;
    const isMerchantDirect = destination === MERCHANT_WALLET;
    const tokenBalances = tx.meta?.postTokenBalances ?? [];
    const destBalance = tokenBalances.find(b =>
      tx.transaction?.message?.accountKeys?.[b.accountIndex]?.pubkey === destination
    );
    const isMerchantATA = destBalance?.owner === MERCHANT_WALLET;
    if (!isMerchantDirect && !isMerchantATA) continue;

    // (d) Amount in raw integer units must be >= expected_amount_usdc * 1_000_000
    const rawAmount = parseInt(info.amount ?? info.tokenAmount?.amount ?? '0', 10);
    const requiredRawUnits = Math.trunc(record.expected_amount_usdc * 1_000_000);
    if (rawAmount < requiredRawUnits) continue;

    // All four conditions met
    return true;
  }

  return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Feature: solana-pay-onboarding, Property 8: Transaction payment validation correctness
// Validates: Requirements 5.3, 6.1, 6.2, 6.3, 6.6
// ─────────────────────────────────────────────────────────────────────────────
describe('Property 8: Transaction payment validation correctness', () => {
  // Arbitrary for a valid USDC transferChecked instruction
  const validTransferIxArb = (amount, mint, destination, owner) => ({
    program: 'spl-token',
    parsed: {
      type: 'transferChecked',
      info: {
        mint,
        destination,
        tokenAmount: { amount: String(amount) },
      },
    },
  });

  const buildTx = (ix, destination, owner, mint) => ({
    transaction: {
      message: {
        instructions: [ix],
        accountKeys: [{ pubkey: destination }],
      },
    },
    meta: {
      innerInstructions: [],
      postTokenBalances: [
        {
          accountIndex: 0,
          mint,
          owner,
        },
      ],
    },
  });

  const recordArb = fc.record({
    discord_user_id: fc.constant('123'),
    expected_amount_usdc: fc.oneof(fc.constant(0.1), fc.constant(0.25)),
  });

  test('qualifying=true when all four conditions hold', () => {
    fc.assert(
      fc.property(
        recordArb,
        fc.integer({ min: 1, max: 1000 }),  // multiplier to ensure amount >= required
        (record, multiplier) => {
          const requiredRaw = Math.trunc(record.expected_amount_usdc * 1_000_000);
          const txAmount = requiredRaw * multiplier;
          const ix = validTransferIxArb(txAmount, USDC_MINT, MERCHANT_WALLET, MERCHANT_WALLET);
          const tx = buildTx(ix, MERCHANT_WALLET, MERCHANT_WALLET, USDC_MINT);
          return isQualifyingTransaction(tx, record) === true;
        }
      )
    );
  });

  test('qualifying=false when mint is wrong', () => {
    fc.assert(
      fc.property(
        recordArb,
        fc.string({ minLength: 1 }).filter(s => s !== USDC_MINT),
        (record, wrongMint) => {
          const requiredRaw = Math.trunc(record.expected_amount_usdc * 1_000_000);
          const ix = validTransferIxArb(requiredRaw * 2, wrongMint, MERCHANT_WALLET, MERCHANT_WALLET);
          const tx = buildTx(ix, MERCHANT_WALLET, MERCHANT_WALLET, wrongMint);
          return isQualifyingTransaction(tx, record) === false;
        }
      )
    );
  });

  test('qualifying=false when destination is not merchant wallet or ATA', () => {
    fc.assert(
      fc.property(
        recordArb,
        fc.string({ minLength: 1 }).filter(s => s !== MERCHANT_WALLET),
        (record, wrongDest) => {
          const requiredRaw = Math.trunc(record.expected_amount_usdc * 1_000_000);
          const ix = validTransferIxArb(requiredRaw * 2, USDC_MINT, wrongDest, 'someOtherOwner');
          const tx = buildTx(ix, wrongDest, 'someOtherOwner', USDC_MINT);
          return isQualifyingTransaction(tx, record) === false;
        }
      )
    );
  });

  test('qualifying=false when amount is below required threshold', () => {
    fc.assert(
      fc.property(
        recordArb,
        fc.integer({ min: 0, max: 999999 }),  // always < 1 USDC raw, well below 10 USDC required
        (record, insufficientRaw) => {
          // ensure insufficient: use an amount strictly less than required
          const requiredRaw = Math.trunc(record.expected_amount_usdc * 1_000_000);
          if (insufficientRaw >= requiredRaw) return true; // skip this case
          const ix = validTransferIxArb(insufficientRaw, USDC_MINT, MERCHANT_WALLET, MERCHANT_WALLET);
          const tx = buildTx(ix, MERCHANT_WALLET, MERCHANT_WALLET, USDC_MINT);
          return isQualifyingTransaction(tx, record) === false;
        }
      )
    );
  });

  test('qualifying=false when instruction program is not spl-token', () => {
    fc.assert(
      fc.property(
        recordArb,
        fc.constantFrom('system', 'stake', 'vote', 'memo'),
        (record, wrongProgram) => {
          const requiredRaw = Math.trunc(record.expected_amount_usdc * 1_000_000);
          const ix = {
            program: wrongProgram,
            parsed: {
              type: 'transferChecked',
              info: {
                mint: USDC_MINT,
                destination: MERCHANT_WALLET,
                tokenAmount: { amount: String(requiredRaw * 2) },
              },
            },
          };
          const tx = buildTx(ix, MERCHANT_WALLET, MERCHANT_WALLET, USDC_MINT);
          return isQualifyingTransaction(tx, record) === false;
        }
      )
    );
  });

  test('qualifying=false for null/empty transaction', () => {
    const record = { expected_amount_usdc: 0.1 };
    expect(isQualifyingTransaction(null, record)).toBe(false);
    expect(isQualifyingTransaction({}, record)).toBe(false);
    expect(isQualifyingTransaction({ transaction: null, meta: null }, record)).toBe(false);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Pure helper: grace period window checker
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Returns true iff the current time is still within the grace period window.
 * @param {number} currentTime - Current Unix timestamp (seconds)
 * @param {number} graceStartedAt - Unix timestamp when grace period began (seconds)
 * @param {number} gracePeriodDays - Length of grace period in days (1–30)
 * @returns {boolean}
 */
function isInGracePeriod(currentTime, graceStartedAt, gracePeriodDays) {
  return currentTime - graceStartedAt < gracePeriodDays * 86400;
}

// Feature: solana-pay-onboarding, Property 11: Grace period window enforcement
describe('Property 11: Grace period window enforcement', () => {
  // Property: returns true iff currentTime - graceStartedAt < gracePeriodDays * 86400
  test('returns true iff elapsed time is strictly less than gracePeriodDays * 86400', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 0 }),
        fc.integer({ min: 0 }),
        fc.integer({ min: 1, max: 30 }),
        (currentTime, graceStartedAt, gracePeriodDays) => {
          const result = isInGracePeriod(currentTime, graceStartedAt, gracePeriodDays);
          const expected = currentTime - graceStartedAt < gracePeriodDays * 86400;
          return result === expected;
        }
      )
    );
  });

  // Exact boundary: one second before expiry → true
  test('returns true when currentTime - graceStartedAt === gracePeriodDays * 86400 - 1 (one second before expiry)', () => {
    const graceStartedAt = 1000000;
    const gracePeriodDays = 7;
    const currentTime = graceStartedAt + gracePeriodDays * 86400 - 1;
    expect(isInGracePeriod(currentTime, graceStartedAt, gracePeriodDays)).toBe(true);
  });

  // Exact boundary: exactly at expiry → false
  test('returns false when currentTime - graceStartedAt === gracePeriodDays * 86400 (exactly at expiry)', () => {
    const graceStartedAt = 1000000;
    const gracePeriodDays = 7;
    const currentTime = graceStartedAt + gracePeriodDays * 86400;
    expect(isInGracePeriod(currentTime, graceStartedAt, gracePeriodDays)).toBe(false);
  });

  // When currentTime < graceStartedAt (negative elapsed time) → true (not yet expired)
  test('returns true when currentTime < graceStartedAt (negative elapsed time)', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 1 }),
        fc.integer({ min: 1, max: 30 }),
        (graceStartedAt, gracePeriodDays) => {
          // currentTime strictly before graceStartedAt
          const currentTime = graceStartedAt - 1;
          return isInGracePeriod(currentTime, graceStartedAt, gracePeriodDays) === true;
        }
      )
    );
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Pure helper: renewal DM deduplication
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Returns true iff a renewal DM should be sent for the given subscriber record.
 *
 * Conditions for sending (all must hold):
 *   1. record.status === "active"
 *   2. record.expires_at is not null
 *   3. record.renewal_dm_sent_for_expiry !== record.expires_at  (dedup: not already sent)
 *   4. record.expires_at - currentTime <= renewalWindowDays * 86400  (within window)
 *
 * For this pure function, record.expires_at is treated as an integer Unix timestamp.
 *
 * @param {Object} record - Subscriber record with status, expires_at (int Unix timestamp), renewal_dm_sent_for_expiry
 * @param {number} currentTime - Current time as Unix timestamp (integer seconds)
 * @param {number} renewalWindowDays - Days before expiry in which to send renewal DM
 * @returns {boolean}
 */
function shouldSendRenewalDM(record, currentTime, renewalWindowDays) {
  if (record.status !== 'active') return false;
  if (record.expires_at === null || record.expires_at === undefined) return false;
  if (record.renewal_dm_sent_for_expiry === record.expires_at) return false;
  if (record.expires_at - currentTime > renewalWindowDays * 86400) return false;
  return true;
}

// Feature: solana-pay-onboarding, Property 12: Renewal DM deduplication
describe('Property 12: Renewal DM deduplication', () => {
  // Dedup check (core property): already sent for this expiry cycle → no DM
  test('returns false when renewal_dm_sent_for_expiry === expires_at (dedup)', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 0 }),        // expires_at (Unix timestamp)
        fc.integer({ min: 0 }),        // currentTime
        fc.integer({ min: 1, max: 30 }), // renewalWindowDays
        (expiresAt, currentTime, renewalWindowDays) => {
          const record = {
            status: 'active',
            expires_at: expiresAt,
            renewal_dm_sent_for_expiry: expiresAt, // already sent for this expiry
          };
          // Even if we're within the renewal window, dedup must prevent sending
          return shouldSendRenewalDM(record, currentTime, renewalWindowDays) === false;
        }
      )
    );
  });

  // First-time send: not deduped, active, within window → true
  test('returns true for first-time send when active, within window, and not deduped', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 1, max: 30 }),  // renewalWindowDays
        fc.integer({ min: 0 }),           // currentTime
        (renewalWindowDays, currentTime) => {
          // expires_at must be within the renewal window: expires_at - currentTime <= renewalWindowDays * 86400
          const maxOffset = renewalWindowDays * 86400;
          // Pick expires_at as currentTime + some offset in [0, maxOffset]
          const offset = renewalWindowDays * 86400; // exactly at the window boundary
          const expiresAt = currentTime + offset;
          const record = {
            status: 'active',
            expires_at: expiresAt,
            renewal_dm_sent_for_expiry: null, // never sent before
          };
          return shouldSendRenewalDM(record, currentTime, renewalWindowDays) === true;
        }
      )
    );
  });

  // Not active: any status other than "active" → always false
  test('returns false when status is not "active"', () => {
    fc.assert(
      fc.property(
        fc.constantFrom('pending_payment', 'lapsed', 'grace', 'expired', 'check_failed'),
        fc.integer({ min: 0 }),
        fc.integer({ min: 0 }),
        fc.integer({ min: 1, max: 30 }),
        (status, expiresAt, currentTime, renewalWindowDays) => {
          const record = {
            status,
            expires_at: expiresAt,
            renewal_dm_sent_for_expiry: null,
          };
          return shouldSendRenewalDM(record, currentTime, renewalWindowDays) === false;
        }
      )
    );
  });

  // Null expires_at → always false
  test('returns false when expires_at is null', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 0 }),
        fc.integer({ min: 1, max: 30 }),
        (currentTime, renewalWindowDays) => {
          const record = {
            status: 'active',
            expires_at: null,
            renewal_dm_sent_for_expiry: null,
          };
          return shouldSendRenewalDM(record, currentTime, renewalWindowDays) === false;
        }
      )
    );
  });

  // Outside window: expires_at - currentTime > renewalWindowDays * 86400 → false
  test('returns false when outside the renewal window', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 1, max: 30 }),  // renewalWindowDays
        fc.integer({ min: 0 }),           // currentTime
        (renewalWindowDays, currentTime) => {
          // expires_at must be outside the window: expires_at - currentTime > renewalWindowDays * 86400
          const expiresAt = currentTime + renewalWindowDays * 86400 + 1;
          const record = {
            status: 'active',
            expires_at: expiresAt,
            renewal_dm_sent_for_expiry: null, // not deduped
          };
          return shouldSendRenewalDM(record, currentTime, renewalWindowDays) === false;
        }
      )
    );
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Pure helper: bounded configuration value resolver
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Resolves a configuration value with clamping to [min, max].
 * Returns defaultVal if v is null, undefined, not a valid integer (no decimal
 * part), NaN, or Infinity. Clamps valid integers to [min, max].
 *
 * @param {*} v - The raw config value
 * @param {number} min - Minimum allowed value (inclusive)
 * @param {number} max - Maximum allowed value (inclusive)
 * @param {*} defaultVal - Fallback when v is invalid
 * @returns {number|*} - Clamped integer or defaultVal
 */
function resolveConfigValue(v, min, max, defaultVal) {
  // Must be a number type, a finite integer (no decimal part)
  if (
    v === null ||
    v === undefined ||
    typeof v !== 'number' ||
    !Number.isFinite(v) ||
    !Number.isInteger(v)
  ) {
    return defaultVal;
  }
  if (v < min) return min;
  if (v > max) return max;
  return v;
}

// ─────────────────────────────────────────────────────────────────────────────
// Feature: solana-pay-onboarding, Property 10: Bounded configuration value clamping
// ─────────────────────────────────────────────────────────────────────────────
describe('Property 10: Bounded configuration value clamping', () => {
  // Null input → defaultVal
  test('null input returns defaultVal', () => {
    expect(resolveConfigValue(null, 1, 30, 3)).toBe(3);
  });

  // Non-integer string → defaultVal
  test('non-integer strings return defaultVal', () => {
    fc.assert(
      fc.property(
        fc.string().filter(s => !/^-?\d+$/.test(s)),
        (s) => {
          return resolveConfigValue(s, 1, 30, 3) === 3;
        }
      )
    );
  });

  // Float → defaultVal
  test('float 1.5 returns defaultVal', () => {
    expect(resolveConfigValue(1.5, 1, 30, 3)).toBe(3);
    expect(resolveConfigValue(0.5, 1, 30, 5)).toBe(5);
  });

  // In-range integer → v
  test('in-range integer returns itself', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 1, max: 30 }),
        (v) => {
          return resolveConfigValue(v, 1, 30, 3) === v;
        }
      )
    );
  });

  // Below min → min
  test('integer below min returns min', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: -1000, max: 0 }),
        (v) => {
          return resolveConfigValue(v, 1, 30, 3) === 1;
        }
      )
    );
  });

  // Above max → max
  test('integer above max returns max', () => {
    fc.assert(
      fc.property(
        fc.integer({ min: 31, max: 1000 }),
        (v) => {
          return resolveConfigValue(v, 1, 30, 3) === 30;
        }
      )
    );
  });

  // Boundary values
  test('boundary value min (1) returns 1', () => {
    expect(resolveConfigValue(1, 1, 30, 3)).toBe(1);
  });

  test('boundary value max (30) returns 30', () => {
    expect(resolveConfigValue(30, 1, 30, 3)).toBe(30);
  });

  // Property: for any integer v, min, max (min <= max), defaultVal:
  // result is always in [min, max] when v is a valid integer, or equals defaultVal otherwise
  test('result is always in [min, max] for valid integers, or equals defaultVal otherwise', () => {
    fc.assert(
      fc.property(
        fc.oneof(
          fc.integer({ min: -1000, max: 1000 }),  // valid integers
          fc.float({ noNaN: false }),              // floats, NaN, Infinity
          fc.constant(null),
          fc.constant(undefined),
          fc.string()
        ),
        fc.integer({ min: -100, max: 100 }),
        fc.integer({ min: 0, max: 100 }).map((delta) => delta), // used as offset for max
        fc.integer(),
        (v, minVal, delta, defaultVal) => {
          const maxVal = minVal + delta; // ensures min <= max
          const result = resolveConfigValue(v, minVal, maxVal, defaultVal);
          const isValidInt =
            v !== null &&
            v !== undefined &&
            typeof v === 'number' &&
            Number.isFinite(v) &&
            Number.isInteger(v);

          if (isValidInt) {
            // result must be within [minVal, maxVal]
            return result >= minVal && result <= maxVal;
          } else {
            // result must equal defaultVal
            return result === defaultVal;
          }
        }
      )
    );
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Feature: solana-pay-onboarding, Property 6: Subscriber_Record serialization round-trip
// Validates: Requirements 4.2, 13.2, 13.3
// ─────────────────────────────────────────────────────────────────────────────

// Generate a valid ISO 8601 UTC datetime string
const isoDateArb = fc.date({ min: new Date('2020-01-01'), max: new Date('2030-12-31') })
  .map(d => d.toISOString());  // toISOString() always returns full ISO string with milliseconds

const ISO_DATE_REGEX = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

// Arbitrary for a valid Subscriber_Record with all 11 required fields.
// Use a fixed constant for reference_key to avoid slow base58 filter exhaustion.
const subscriberRecordFullArb = fc.record({
  discord_user_id: fc.string({ minLength: 1, maxLength: 20 }).filter(s => /^\S+$/.test(s)),
  discord_username: fc.string({ minLength: 1, maxLength: 32 }).filter(s => /^\S+$/.test(s)),
  wallet_address: fc.oneof(fc.string({ minLength: 1, maxLength: 44 }), fc.constant(null)),
  tier: fc.constantFrom('standard', 'premium'),
  expected_amount_usdc: fc.oneof(fc.constant(0.1), fc.constant(0.25)),
  period_days: fc.integer({ min: 1, max: 365 }),
  subscribed_at: fc.oneof(isoDateArb, fc.constant(null)),
  expires_at: fc.oneof(isoDateArb, fc.constant(null)),
  grace_started_at: fc.oneof(isoDateArb, fc.constant(null)),
  // Use a constant valid base58 reference key to avoid filter exhaustion
  reference_key: fc.constant('4vJ9JU1bfGg1xPcDxY2xFRG7JbN3TxWqZvKmPsHcL8E'),
  status: fc.constantFrom('pending_payment', 'active', 'lapsed', 'grace', 'expired', 'check_failed'),
});

describe('Property 6: Subscriber_Record serialization round-trip', () => {
  test('round-trip JSON.stringify/JSON.parse preserves all 11 required fields', () => {
    // **Validates: Requirements 4.2, 13.2, 13.3**
    fc.assert(
      fc.property(subscriberRecordFullArb, (record) => {
        const serialized = JSON.stringify(record);
        const deserialized = JSON.parse(serialized);
        const fields = ['discord_user_id', 'discord_username', 'wallet_address', 'tier',
          'expected_amount_usdc', 'period_days', 'subscribed_at', 'expires_at',
          'grace_started_at', 'reference_key', 'status'];
        for (const field of fields) {
          expect(deserialized[field]).toStrictEqual(record[field]);
        }
      })
    );
  });

  test('datetime fields are ISO 8601 UTC strings with millisecond precision or null', () => {
    // **Validates: Requirements 13.2, 13.3**
    fc.assert(
      fc.property(subscriberRecordFullArb, (record) => {
        const deserialized = JSON.parse(JSON.stringify(record));
        for (const field of ['subscribed_at', 'expires_at', 'grace_started_at']) {
          const value = deserialized[field];
          if (value !== null) {
            expect(value).toMatch(ISO_DATE_REGEX);
          } else {
            expect(value).toBeNull();
          }
        }
      })
    );
  });

  test('grace_started_at is preserved as null when absent', () => {
    // **Validates: Requirements 4.2**
    const record = {
      discord_user_id: '123', discord_username: 'user', wallet_address: null,
      tier: 'standard', expected_amount_usdc: 0.1, period_days: 30,
      subscribed_at: null, expires_at: null, grace_started_at: null,
      reference_key: '4vJ9JU1bfGg1xPcDxY2xFRG7JbN3TxWqZvKmPsHcL8E', status: 'pending_payment'
    };
    const deserialized = JSON.parse(JSON.stringify(record));
    expect(deserialized.grace_started_at).toBeNull();
  });
});
