'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { planReview, runBatch, summarise } = require('../src/lib/review');

const CONFIG = {
  batchSize: 2,
  maxFindings: 100,
  parallelism: 50,
  apiKey: 'k',
  rules: {
    internal: { enabled: true, extraCidrs: [], extraPatterns: [] },
    malformed: { enabled: true },
    duplicate: { enabled: true },
    whitelistedIsp: {
      enabled: true,
      maxScore: 80,
      isps: ['akamai technologies', 'google', 'palo alto networks', 'the shadowserver foundation', 'censys', 'lufthansa', 'lido', 'sita aero'],
    },
  },
};

const ABUSE = {
  '23.55.1.1': { isp: 'Akamai Technologies, Inc.', domain: 'akamai.com', abuseConfidenceScore: 3, countryCode: 'US', totalReports: 0, usageType: 'Content Delivery Network' },
  '45.9.1.1': { isp: 'Censys, Inc.', abuseConfidenceScore: 95 },
  '185.220.101.1': { isp: 'Some Bulletproof Host', abuseConfidenceScore: 100 },
  '8.8.8.8': { isp: 'Google LLC', abuseConfidenceScore: 0 },
};

function stubFetch(seen) {
  return async (url) => {
    const ip = new URL(url).searchParams.get('ipAddress');
    if (seen) seen.push(ip);
    return { status: 200, headers: { get: () => null }, json: async () => ({ data: ABUSE[ip] || {} }) };
  };
}

async function review(blob, config = CONFIG, seen = []) {
  const plan = planReview(blob, config);
  const results = [];
  for (const batch of plan.batches) {
    results.push(await runBatch(batch, config, { fetchImpl: stubFetch(seen), sleep: async () => {} }));
  }
  return { plan, seen, output: summarise(plan, results, config) };
}

const BLOB = [
  '# Sentinel Threat Intelligence IPs',
  '10.34.2.7',        // 2  internal
  '999.1.1.1',        // 3  malformed
  '23.55.1.1',        // 4  Akamai, score 3   -> flagged
  '45.9.1.1',         // 5  Censys, score 95  -> not flagged
  '185.220.101.1',    // 6  genuinely bad     -> not flagged
  '8.8.8.8',          // 7  Google, score 0   -> flagged
  '192.168.0.0/16',   // 8  internal range
  '1.1.1.0/24',       // 9  public range, cannot be checked
].join('\n');

test('internal and malformed entries are never sent to AbuseIPDB', async () => {
  const { seen } = await review(BLOB);
  assert.ok(!seen.includes('10.34.2.7'), 'internal address must not leave the function');
  assert.ok(!seen.includes('999.1.1.1'), 'malformed entry must not be looked up');
  assert.ok(!seen.includes('192.168.0.0/16'));
  assert.deepEqual(seen.sort(), ['185.220.101.1', '23.55.1.1', '45.9.1.1', '8.8.8.8']);
});

test('the end-to-end verdict on a representative blocklist', async () => {
  const { output } = await review(BLOB);
  assert.deepEqual(output.findings.map((finding) => [finding.line, finding.ip]), [
    [2, '10.34.2.7'],
    [3, '999.1.1.1'],
    [4, '23.55.1.1'],
    [7, '8.8.8.8'],
    [8, '192.168.0.0/16'],
  ]);
  assert.equal(output.summary.flagged, 5);
  assert.equal(output.summary.checked, 4);
  assert.equal(output.summary.flaggedBeforeEnrichment, 3);
  assert.equal(output.summary.skippedCidrs, 1);
  assert.equal(output.summary.errors, 0);
});

test('findings carry the blob line number and the enrichment', async () => {
  const { output } = await review(BLOB);
  const akamai = output.findings.find((finding) => finding.ip === '23.55.1.1');
  assert.equal(akamai.line, 4);
  assert.equal(akamai.isp, 'Akamai Technologies, Inc.');
  assert.equal(akamai.countryCode, 'US');
  assert.equal(akamai.abuseConfidenceScore, 3);
  assert.match(akamai.reasons, /whitelisted ISP "akamai technologies".*3 < 80/);

  const internal = output.findings.find((finding) => finding.ip === '10.34.2.7');
  assert.equal(internal.checked, false);
  assert.equal(internal.abuseConfidenceScore, null, 'unchecked entries report n/a, not 0');
});

test('a public CIDR is reported as skipped rather than silently dropped', async () => {
  const { output } = await review(BLOB);
  assert.deepEqual(output.skipped, [{ line: 9, entry: '1.1.1.0/24', reason: 'public CIDR range, not checked' }]);
});

test('the CSV is present when there are findings and empty when there are none', async () => {
  const withFindings = await review(BLOB);
  assert.match(withFindings.output.csv, /^IP,Line,Blob entry,/);
  assert.equal(withFindings.output.csv.trimEnd().split('\r\n').length, 6);

  const clean = await review('185.220.101.1\n45.9.1.1\n');
  assert.equal(clean.output.summary.flagged, 0);
  assert.equal(clean.output.csv, '');
});

test('a lookup error is counted and never mistaken for clean', async () => {
  const dead = async () => ({ status: 500, headers: { get: () => null }, text: async () => 'down' });
  const plan = planReview('8.8.8.8\n23.55.1.1\n', CONFIG);
  const results = [];
  for (const batch of plan.batches) {
    results.push(await runBatch(batch, { ...CONFIG, maxAttempts: 2 }, { fetchImpl: dead, sleep: async () => {} }));
  }
  const output = summarise(plan, results, CONFIG);
  assert.equal(output.summary.errors, 2);
  assert.equal(output.summary.checked, 0);
  assert.equal(output.summary.flagged, 0);
  assert.equal(output.errorDetail.length, 2);
  assert.match(output.errorDetail[0].error, /HTTP 500/);
});

test('batching does not change the verdict', async () => {
  const single = await review(BLOB, { ...CONFIG, batchSize: 1000 });
  const many = await review(BLOB, { ...CONFIG, batchSize: 1 });
  assert.deepEqual(single.output.findings, many.output.findings);
  assert.equal(many.plan.batches.length, 4);
});

test('findings are capped but the count is not, so truncation is visible', async () => {
  const blob = Array.from({ length: 12 }, (_, index) => `10.0.0.${index + 1}`).join('\n');
  const { output } = await review(blob, { ...CONFIG, maxFindings: 5 });
  assert.equal(output.summary.flagged, 12, 'the true total is reported');
  assert.equal(output.findings.length, 5);
  assert.equal(output.summary.truncated, true);
});

test('the rules that ran are recorded for the ticket', async () => {
  const { output } = await review(BLOB);
  assert.equal(output.summary.rulesApplied.length, 4);
  assert.ok(output.summary.rulesApplied.some((line) => line.startsWith('whitelistedIsp: ')));
  assert.deepEqual(output.summary.unknownRuleKeys, []);
});

test('a repeated address is flagged once, on the later line, and looked up once', async () => {
  // 185.220.101.1 scores 100, so it contributes no finding of its own.
  const { output, seen } = await review('23.55.1.1\n185.220.101.1\n23.55.1.1\n');

  assert.deepEqual(
    seen.filter((ip) => ip === '23.55.1.1').length,
    1,
    'the repeat must not spend a second AbuseIPDB lookup',
  );

  const duplicate = output.findings.find((finding) => finding.rules.includes('duplicate'));
  assert.equal(duplicate.line, 3, 'the later copy is the one to remove');
  assert.match(duplicate.reasons, /already on line 1; remove this copy/);

  // Line 1 is still flagged on its own merit, by the ISP rule, and carries the
  // enrichment. Line 3 carries the removal instruction.
  const original = output.findings.find((finding) => finding.line === 1);
  assert.equal(original.rules, 'whitelistedIsp');
  assert.equal(original.isp, 'Akamai Technologies, Inc.');
  assert.equal(duplicate.isp, null);
  assert.equal(output.summary.flagged, 2);
});

test('a duplicate of an otherwise clean address is still flagged for removal', async () => {
  const { output } = await review('185.220.101.1\n185.220.101.1\n');
  assert.equal(output.summary.flagged, 1);
  assert.equal(output.findings[0].line, 2);
  assert.equal(output.findings[0].rules, 'duplicate');
});

test('a blob of nothing but comments plans no work', () => {
  const plan = planReview('# a\n// b\n\n', CONFIG);
  assert.equal(plan.counts.entries, 0);
  assert.deepEqual(plan.batches, []);
});
