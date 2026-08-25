'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { applyPost, applyPre, buildCorpus, buildRuleSet, RULES } = require('../src/lib/rules');
const { parseBlocklist } = require('../src/lib/parse');

const ISPS = [
  'akamai technologies', 'google', 'palo alto networks',
  'the shadowserver foundation', 'censys', 'lufthansa', 'lido', 'sita aero',
];
const DEFAULTS = {
  internal: { enabled: true, extraCidrs: [], extraPatterns: [] },
  malformed: { enabled: true },
  duplicate: { enabled: true },
  whitelistedIsp: { enabled: true, maxScore: 80, isps: ISPS },
};

function pre(config, blob) {
  const ruleSet = buildRuleSet(config);
  const { entries } = parseBlocklist(blob);
  const corpus = buildCorpus(entries);
  return entries.map((entry) => ({ entry, verdict: applyPre(ruleSet, entry, corpus) }));
}

test('all four rules are on by default', () => {
  const ruleSet = buildRuleSet({});
  assert.deepEqual(ruleSet.pre.map((rule) => rule.id), ['malformed', 'internal', 'duplicate']);
  assert.deepEqual(ruleSet.post.map((rule) => rule.id), ['whitelistedIsp']);
  assert.ok(RULES.every((rule) => rule.defaultEnabled));
});

test('internal and malformed are terminal, so they never reach AbuseIPDB', () => {
  const results = pre(DEFAULTS, '10.34.2.7\n999.1.1.1\n8.8.8.8\n');
  assert.equal(results[0].verdict.terminal, true);
  assert.equal(results[0].verdict.reasons[0].ruleId, 'internal');
  assert.equal(results[1].verdict.terminal, true);
  assert.equal(results[1].verdict.reasons[0].ruleId, 'malformed');
  assert.equal(results[2].verdict.terminal, false);
  assert.deepEqual(results[2].verdict.reasons, []);
});

test('disabling a rule actually suppresses it', () => {
  const results = pre({ ...DEFAULTS, internal: { enabled: false } }, '10.34.2.7\n999.1.1.1\n');
  assert.equal(results[0].verdict.terminal, false, '10.34.2.7 is no longer flagged');
  assert.deepEqual(results[0].verdict.reasons, []);
  assert.equal(results[1].verdict.terminal, true, 'malformed is unaffected');
});

test('extraCidrs widen internal without touching code', () => {
  const config = { ...DEFAULTS, internal: { enabled: true, extraCidrs: ['193.168.0.0/16'] } };
  const results = pre(config, '193.168.4.5\n194.168.4.5\n');
  assert.equal(results[0].verdict.terminal, true);
  assert.match(results[0].verdict.reasons[0].reason, /extraCidrs/);
  assert.equal(results[1].verdict.terminal, false);
});

test('extraPatterns provide the regex escape hatch', () => {
  // 147.161/16 is public space, so only the pattern can flag it.
  const config = { ...DEFAULTS, internal: { enabled: true, extraPatterns: ['^147\\.161\\.'] } };
  const results = pre(config, '147.161.1.1\n147.162.1.1\n');
  assert.equal(results[0].verdict.terminal, true);
  assert.match(results[0].verdict.reasons[0].reason, /matched \/\^147/);
  assert.equal(results[1].verdict.terminal, false);
});

test('an unparseable extraPattern is dropped, not fatal', () => {
  const config = { ...DEFAULTS, internal: { enabled: true, extraPatterns: ['([unclosed'] } };
  assert.doesNotThrow(() => pre(config, '8.8.8.8\n'));
});

test('a duplicate flags the later copy and leaves the first alone', () => {
  const results = pre(DEFAULTS, '8.8.8.8\n1.2.3.4\n8.8.8.8\n');
  assert.deepEqual(results[0].verdict.reasons, [], 'the first occurrence is the keeper');
  assert.equal(results[0].verdict.terminal, false, 'and still goes to AbuseIPDB');
  assert.deepEqual(results[1].verdict.reasons, []);
  assert.equal(results[2].verdict.reasons[0].ruleId, 'duplicate');
  assert.match(results[2].verdict.reasons[0].reason, /already on line 1; remove this copy/);
  // Terminal: the first copy is being enriched, so the repeat need not be.
  assert.equal(results[2].verdict.terminal, true);
});

test('a third copy points at the first, not at the one before it', () => {
  const results = pre(DEFAULTS, '8.8.8.8\n8.8.8.8\n8.8.8.8\n');
  assert.deepEqual(results[0].verdict.reasons, []);
  assert.match(results[1].verdict.reasons[0].reason, /already on line 1/);
  assert.match(results[2].verdict.reasons[0].reason, /already on line 1/);
});

test('duplicates are matched on the canonical address, not the raw text', () => {
  const results = pre(DEFAULTS, '1.2.3.4\n1.2.3.4/32\n');
  assert.deepEqual(results[0].verdict.reasons, []);
  assert.match(results[1].verdict.reasons[0].reason, /already on line 1/);

  // Public IPv6 on purpose: 2001:db8::/32 is documentation space, so the
  // internal rule would fire first and this would stop testing canonicalisation.
  const v6 = pre(DEFAULTS, '2606:4700:4700::1111\n2606:4700:4700:0000:0000:0000:0000:1111\n');
  assert.deepEqual(v6[0].verdict.reasons, []);
  assert.match(v6[1].verdict.reasons[0].reason, /already on line 1/);
});

test('a repeated typo is reported as malformed on each line, not as a duplicate', () => {
  const results = pre(DEFAULTS, '999.1.1.1\n999.1.1.1\n');
  for (const result of results) {
    assert.deepEqual(result.verdict.reasons.map((item) => item.ruleId), ['malformed']);
  }
});

test('an internal address that repeats carries both reasons', () => {
  const results = pre(DEFAULTS, '10.34.2.7\n10.34.2.7\n');
  assert.deepEqual(results[0].verdict.reasons.map((item) => item.ruleId), ['internal']);
  assert.deepEqual(results[1].verdict.reasons.map((item) => item.ruleId), ['internal', 'duplicate']);
});

test('disabling the duplicate rule sends the repeat back to AbuseIPDB', () => {
  const results = pre({ ...DEFAULTS, duplicate: { enabled: false } }, '8.8.8.8\n8.8.8.8\n');
  assert.deepEqual(results[1].verdict.reasons, []);
  assert.equal(results[1].verdict.terminal, false);
});

test('the score gate is exclusive at the threshold', () => {
  const ruleSet = buildRuleSet(DEFAULTS);
  const akamai = (score) => applyPost(ruleSet, {}, { isp: 'Akamai Technologies, Inc.', abuseConfidenceScore: score });
  assert.equal(akamai(79).length, 1, '79 is below the threshold and is flagged');
  assert.equal(akamai(80).length, 0, '80 has earned its place on the blocklist');
  assert.equal(akamai(100).length, 0);
  assert.equal(akamai(0).length, 1);
});

test('a missing score counts as zero, not as clean', () => {
  const ruleSet = buildRuleSet(DEFAULTS);
  assert.equal(applyPost(ruleSet, {}, { isp: 'Censys, Inc.' }).length, 1);
});

test('the threshold is a parameter, not a constant', () => {
  const ruleSet = buildRuleSet({ ...DEFAULTS, whitelistedIsp: { enabled: true, maxScore: 20, isps: ISPS } });
  const akamai = (score) => applyPost(ruleSet, {}, { isp: 'Akamai Technologies, Inc.', abuseConfidenceScore: score });
  assert.equal(akamai(25).length, 0);
  assert.equal(akamai(15).length, 1);
});

test('the ISP rule reads domain and hostnames, not just isp', () => {
  const ruleSet = buildRuleSet(DEFAULTS);
  assert.equal(applyPost(ruleSet, {}, { isp: 'Some Reseller', domain: 'sita.aero', abuseConfidenceScore: 0 }).length, 1);
  assert.equal(applyPost(ruleSet, {}, { isp: 'Some Reseller', hostnames: ['edge.lido.example'], abuseConfidenceScore: 0 }).length, 1);
  assert.equal(applyPost(ruleSet, {}, { isp: 'Lidonet Communications', abuseConfidenceScore: 0 }).length, 0);
});

test('a typo in the ReviewRules parameter is reported, not ignored', () => {
  const ruleSet = buildRuleSet({ ...DEFAULTS, whitelistedISPs: { enabled: true } });
  assert.deepEqual(ruleSet.unknown, ['whitelistedISPs']);
});

test('every applied rule describes itself for the ticket', () => {
  const ruleSet = buildRuleSet(DEFAULTS);
  assert.equal(ruleSet.applied.length, 4);
  assert.ok(ruleSet.applied.every((line) => line.includes(': ')));
  assert.ok(ruleSet.applied.some((line) => line.includes('below 80')));
});
