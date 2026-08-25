'use strict';

const CHECK_URL = 'https://api.abuseipdb.com/api/v2/check';
const RETRYABLE_STATUS = new Set([429, 500, 502, 503, 504]);

const DEFAULTS = {
  parallelism: 50,
  maxAgeInDays: 90,
  timeoutMs: 30000,
  maxAttempts: 4,
};

/** Hard ceiling so a bad parameter cannot melt the gateway. */
const PARALLELISM_CEILING = 100;

function clampInt(value, fallback, low, high) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(low, Math.min(parsed, high));
}

function defaultSleep(ms) {
  return new Promise((resolve) => { setTimeout(resolve, ms); });
}

function backoffMs(attempt) {
  // Same shape as the Python runner: exponential to a 8s ceiling, plus jitter
  // so a burst of 429s does not resynchronise into another burst.
  return (Math.min(2 ** (attempt - 1), 8) + Math.random() * 0.5) * 1000;
}

function retryAfterMs(response) {
  const raw = response.headers && typeof response.headers.get === 'function'
    ? response.headers.get('Retry-After')
    : null;
  if (!raw) return null;
  const seconds = Number(raw);
  if (!Number.isFinite(seconds)) return null;
  return Math.max(0, Math.min(seconds, 30)) * 1000;
}

/**
 * One `/check` lookup. Resolves to `{data}` or `{error}` — never throws, and
 * never resolves to an empty "all clear" for a lookup that did not succeed.
 */
async function checkIp(ip, options) {
  const { apiKey, maxAgeInDays, timeoutMs, maxAttempts, fetchImpl, sleep } = options;
  const url = `${CHECK_URL}?ipAddress=${encodeURIComponent(ip)}&maxAgeInDays=${maxAgeInDays}`;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    let response;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      response = await fetchImpl(url, {
        method: 'GET',
        headers: { Key: apiKey, Accept: 'application/json' },
        signal: controller.signal,
      });
    } catch (error) {
      if (attempt === maxAttempts) return { error: `${error.name}: ${error.message}` };
      await sleep(backoffMs(attempt));
      continue;
    } finally {
      clearTimeout(timer);
    }

    if (response.status === 200) {
      let payload;
      try {
        payload = await response.json();
      } catch {
        return { error: 'HTTP 200 with a non-JSON body' };
      }
      const data = payload && typeof payload === 'object' ? payload.data : null;
      return { data: data && typeof data === 'object' ? data : {} };
    }

    if (RETRYABLE_STATUS.has(response.status) && attempt < maxAttempts) {
      await sleep(retryAfterMs(response) ?? backoffMs(attempt));
      continue;
    }

    let body = '';
    try {
      body = (await response.text()).slice(0, 200);
    } catch {
      body = '<unreadable body>';
    }
    return { error: `HTTP ${response.status}: ${body}` };
  }

  return { error: `gave up after ${maxAttempts} attempts` };
}

/**
 * Look up every address with at most `parallelism` requests in flight.
 *
 * A fixed pool of workers pulling from a shared cursor, rather than
 * `Promise.all` over chunks: a slow lookup then delays only itself instead of
 * holding a whole chunk's worth of slots idle.
 */
async function checkMany(ips, options = {}) {
  const settings = {
    apiKey: options.apiKey,
    maxAgeInDays: clampInt(options.maxAgeInDays, DEFAULTS.maxAgeInDays, 1, 365),
    timeoutMs: clampInt(options.timeoutMs, DEFAULTS.timeoutMs, 1000, 120000),
    maxAttempts: clampInt(options.maxAttempts, DEFAULTS.maxAttempts, 1, 10),
    fetchImpl: options.fetchImpl || globalThis.fetch,
    sleep: options.sleep || defaultSleep,
  };
  const parallelism = clampInt(options.parallelism, DEFAULTS.parallelism, 1, PARALLELISM_CEILING);

  const results = new Array(ips.length);
  let cursor = 0;
  let peakInFlight = 0;
  let inFlight = 0;

  async function worker() {
    for (;;) {
      const index = cursor;
      cursor += 1;
      if (index >= ips.length) return;
      inFlight += 1;
      peakInFlight = Math.max(peakInFlight, inFlight);
      try {
        results[index] = await checkIp(ips[index], settings);
      } finally {
        inFlight -= 1;
      }
    }
  }

  await Promise.all(
    Array.from({ length: Math.min(parallelism, ips.length) }, () => worker()),
  );

  return { results, peakInFlight };
}

module.exports = { CHECK_URL, DEFAULTS, PARALLELISM_CEILING, backoffMs, checkIp, checkMany, clampInt, retryAfterMs };
