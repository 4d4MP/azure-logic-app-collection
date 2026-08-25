'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { checkIp, checkMany, retryAfterMs } = require('../src/lib/abuseipdb');

const noSleep = async () => {};
const headers = (map = {}) => ({ get: (name) => map[name] ?? null });
const ok = (data) => ({ status: 200, headers: headers(), json: async () => ({ data }) });
const fail = (status, map = {}) => ({ status, headers: headers(map), text: async () => 'boom' });

test('never exceeds the requested parallelism', async () => {
  let inFlight = 0;
  let peak = 0;
  const fetchImpl = async () => {
    inFlight += 1;
    peak = Math.max(peak, inFlight);
    await new Promise((resolve) => { setTimeout(resolve, 2); });
    inFlight -= 1;
    return ok({ abuseConfidenceScore: 0 });
  };
  const ips = Array.from({ length: 400 }, (_, index) => `1.2.3.${index % 256}`);
  const { results, peakInFlight } = await checkMany(ips, { apiKey: 'k', parallelism: 50, fetchImpl, sleep: noSleep });
  assert.equal(results.length, 400);
  assert.equal(peak, 50);
  assert.equal(peakInFlight, 50);
});

test('parallelism is clamped, so a bad parameter cannot melt the gateway', async () => {
  let peak = 0;
  let inFlight = 0;
  const fetchImpl = async () => {
    inFlight += 1;
    peak = Math.max(peak, inFlight);
    await new Promise((resolve) => { setTimeout(resolve, 1); });
    inFlight -= 1;
    return ok({});
  };
  const ips = Array.from({ length: 300 }, (_, index) => `1.2.3.${index % 256}`);
  await checkMany(ips, { apiKey: 'k', parallelism: 100000, fetchImpl, sleep: noSleep });
  assert.ok(peak <= 100, `peak ${peak} must respect the ceiling`);
});

test('results stay aligned with their inputs', async () => {
  const fetchImpl = async (url) => {
    const ip = new URL(url).searchParams.get('ipAddress');
    // Answer out of order-ish: the last address is the slowest.
    if (ip === '1.1.1.3') await new Promise((resolve) => { setTimeout(resolve, 5); });
    return ok({ ipAddress: ip });
  };
  const ips = ['1.1.1.3', '1.1.1.1', '1.1.1.2'];
  const { results } = await checkMany(ips, { apiKey: 'k', parallelism: 3, fetchImpl, sleep: noSleep });
  assert.deepEqual(results.map((result) => result.data.ipAddress), ips);
});

test('a 429 is retried and Retry-After is honoured', async () => {
  const waits = [];
  let calls = 0;
  const fetchImpl = async () => {
    calls += 1;
    return calls < 3 ? fail(429, { 'Retry-After': '2' }) : ok({ abuseConfidenceScore: 7 });
  };
  const result = await checkIp('1.2.3.4', {
    apiKey: 'k', maxAgeInDays: 90, timeoutMs: 1000, maxAttempts: 4, fetchImpl, sleep: async (ms) => { waits.push(ms); },
  });
  assert.equal(result.data.abuseConfidenceScore, 7);
  assert.deepEqual(waits, [2000, 2000]);
});

test('a 5xx is retried, a 4xx is not', async () => {
  let calls = 0;
  const flaky = async () => { calls += 1; return calls < 2 ? fail(503) : ok({ abuseConfidenceScore: 1 }); };
  const settings = { apiKey: 'k', maxAgeInDays: 90, timeoutMs: 1000, maxAttempts: 4, sleep: noSleep };
  assert.equal((await checkIp('1.2.3.4', { ...settings, fetchImpl: flaky })).data.abuseConfidenceScore, 1);

  let hits = 0;
  const forbidden = async () => { hits += 1; return fail(422); };
  const result = await checkIp('1.2.3.4', { ...settings, fetchImpl: forbidden });
  assert.equal(hits, 1, '422 must not be retried');
  assert.match(result.error, /^HTTP 422/);
});

test('an unresolved lookup is an error, never a silent all-clear', async () => {
  const settings = { apiKey: 'k', maxAgeInDays: 90, timeoutMs: 1000, maxAttempts: 2, sleep: noSleep };
  const dead = async () => { throw Object.assign(new Error('socket hang up'), { name: 'TypeError' }); };
  const result = await checkIp('1.2.3.4', { ...settings, fetchImpl: dead });
  assert.equal(result.data, undefined);
  assert.match(result.error, /socket hang up/);

  const garbage = async () => ({ status: 200, headers: headers(), json: async () => { throw new Error('bad json'); } });
  assert.match((await checkIp('1.2.3.4', { ...settings, fetchImpl: garbage })).error, /non-JSON/);
});

test('the key rides in the Key header and the age window is passed through', async () => {
  let seen;
  const fetchImpl = async (url, init) => { seen = { url, init }; return ok({}); };
  await checkIp('8.8.8.8', { apiKey: 'secret', maxAgeInDays: 30, timeoutMs: 1000, maxAttempts: 1, fetchImpl, sleep: noSleep });
  assert.equal(new URL(seen.url).searchParams.get('ipAddress'), '8.8.8.8');
  assert.equal(new URL(seen.url).searchParams.get('maxAgeInDays'), '30');
  assert.equal(seen.init.headers.Key, 'secret');
});

test('a nonsense Retry-After falls back to backoff', () => {
  assert.equal(retryAfterMs({ headers: headers({ 'Retry-After': 'soon' }) }), null);
  assert.equal(retryAfterMs({ headers: headers({ 'Retry-After': '5' }) }), 5000);
  // Capped, so a hostile header cannot park the activity for an hour.
  assert.equal(retryAfterMs({ headers: headers({ 'Retry-After': '9000' }) }), 30000);
});
