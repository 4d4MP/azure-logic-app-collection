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
  whitelistedIsp: { enabled: true, maxScore: 80, isps: ISPS },
};

function pre(config, blob) {
  const ruleSet = buildRuleSet(config);
  const { entries } = parseBlocklist(blob);
  const corpus = buildCorpus(entries);
  return entries.map((entry) => ({ entry, verdict: applyPre(ruleSet, entry, corpus) }));
}

test('the default rule set is internal + malformed + whitelistedIsp', () => {
  const ruleSet = buildRuleSet({});
  assert.deepEqual(ruleSet.pre.map((rule) => rule.id), ['malformed', 'internal']);
  assert.deepEqual(ruleSet.post.map((rule) => rule.id), ['whitelistedIsp']);
  // duplicate ships in the registry but off by default.
  assert.ok(RULES.some((rule) => rule.id === 'duplicate' && rule.defaultEnabled === false));
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

test('the duplicate rule is non-terminal, so a repeat still gets enriched', () => {
  const config = { ...DEFAULTS, duplicate: { enabled: true } };
  const results = pre(config, '8.8.8.8\n1.2.3.4\n8.8.8.8\n');
  assert.equal(results[0].verdict.terminal, false, 'must still reach AbuseIPDB');
  assert.match(results[0].verdict.reasons[0].reason, /also on line\(s\) 3/);
  assert.match(results[2].verdict.reasons[0].reason, /also on line\(s\) 1/);
  assert.deepEqual(results[1].verdict.reasons, []);
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
  assert.equal(ruleSet.applied.length, 3);
  assert.ok(ruleSet.applied.every((line) => line.includes(': ')));
  assert.ok(ruleSet.applied.some((line) => line.includes('below 80')));
});
