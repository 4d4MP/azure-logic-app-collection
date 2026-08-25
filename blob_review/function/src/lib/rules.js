'use strict';

const { isPrivate, parseNetwork, withinAny } = require('./ipaddr');
const { compileKeywords, matchKeyword, normalise } = require('./text');

/**
 * The rule registry.
 *
 * Adding a criterion is one object in `RULES` plus one key in the `ReviewRules`
 * Logic App parameter. Nothing else in this codebase knows the rules by name.
 *
 * Each rule declares:
 *   id            key under `ReviewRules`
 *   stage         'pre'  evaluated before AbuseIPDB, on the raw entry alone
 *                 'post' evaluated after enrichment, with the AbuseIPDB record
 *   terminal      (pre only) a match ends evaluation for that entry and keeps it
 *                 off AbuseIPDB entirely
 *   defaultEnabled
 *   prepare(cfg)  compile the config once per batch (regexes, networks, keywords)
 *   describe(ctx) one line for the ticket, so the report says what was applied
 *   evaluate(entry, ctx, scope) -> null | {reason}
 *
 * `scope` is `{corpus}` for pre rules and `{abuse}` for post rules.
 *
 * Terminal pre rules are how "first step is to filter out internal and typoed
 * IPs, the rest go through AbuseIPDB" is enforced: a terminal match never
 * reaches the enrichment stage, so those addresses are never sent to a third
 * party and cost no API quota.
 */

const MAX_PATTERN_LENGTH = 200;

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function compilePatterns(patterns, ruleId) {
  const compiled = [];
  for (const raw of asArray(patterns)) {
    const source = String(raw);
    // A pathological pattern would stall the whole batch; cap it and skip
    // anything the engine refuses rather than failing the run.
    if (!source || source.length > MAX_PATTERN_LENGTH) continue;
    try {
      compiled.push({ source, pattern: new RegExp(source) });
    } catch {
      compiled.push({ source, pattern: null, error: `unparseable regex in ${ruleId}.extraPatterns` });
    }
  }
  return compiled.filter((entry) => entry.pattern !== null);
}

function compileNetworks(cidrs) {
  const networks = [];
  for (const raw of asArray(cidrs)) {
    const network = parseNetwork(String(raw).trim()) || parseNetwork(`${String(raw).trim()}/32`);
    if (network) networks.push(network);
  }
  return networks;
}

const RULES = [
  {
    id: 'malformed',
    stage: 'pre',
    terminal: true,
    defaultEnabled: true,
    prepare: () => ({}),
    describe: () => 'entries that are not a valid IPv4/IPv6 address or CIDR (typos)',
    evaluate: (entry) => (entry.kind === 'invalid'
      ? { reason: 'malformed IP - not a valid IPv4/IPv6 address or CIDR' }
      : null),
  },
  {
    id: 'internal',
    stage: 'pre',
    terminal: true,
    defaultEnabled: true,
    prepare: (config) => ({
      networks: compileNetworks(config.extraCidrs),
      patterns: compilePatterns(config.extraPatterns, 'internal'),
    }),
    describe: (context) => {
      const parts = ['private / non-routable address space (RFC1918, loopback, link-local, CGNAT, TEST-NET, benchmarking, reserved, and the IPv6 equivalents)'];
      if (context.networks.length) parts.push(`extra CIDRs [${context.networks.length}]`);
      if (context.patterns.length) parts.push(`extra patterns [${context.patterns.map((item) => item.source).join(', ')}]`);
      return parts.join(' plus ');
    },
    evaluate: (entry, context) => {
      if (entry.kind === 'invalid') return null;
      if (isPrivate(entry)) return { reason: 'internal address space' };
      if (context.networks.length && withinAny(entry, context.networks)) {
        return { reason: 'internal address space (extraCidrs)' };
      }
      const hit = context.patterns.find((item) => item.pattern.test(entry.text));
      return hit ? { reason: `internal address space (matched /${hit.source}/)` } : null;
    },
  },
  {
    id: 'duplicate',
    stage: 'pre',
    // Terminal: the earliest occurrence is already queued for enrichment, so
    // looking the repeat up again would spend a second AbuseIPDB call on an
    // address that is going to be deleted either way.
    terminal: true,
    defaultEnabled: true,
    prepare: () => ({}),
    describe: () => 'an address that already appears on an earlier line - the later copy is flagged for removal',
    evaluate: (entry, context, scope) => {
      const lines = scope.corpus.linesByIp.get(entry.ip);
      if (!lines || lines.length < 2) return null;
      // The corpus is built in blob order, so lines[0] is the earliest. Only
      // the later copies are flagged: the first one is the keeper, and
      // flagging every occurrence would leave nobody knowing which to delete.
      const first = lines[0];
      if (entry.line === first) return null;
      return { reason: `duplicate entry - this address is already on line ${first}; remove this copy` };
    },
  },
  {
    id: 'whitelistedIsp',
    stage: 'post',
    defaultEnabled: true,
    prepare: (config) => ({
      keywords: compileKeywords(config.isps),
      maxScore: Number.isFinite(Number(config.maxScore)) ? Number(config.maxScore) : 80,
    }),
    describe: (context) => `addresses whose AbuseIPDB ISP, domain or hostnames match [${context.keywords.map((item) => item.label).join(', ')}] with an abuse confidence score below ${context.maxScore}`,
    evaluate: (entry, context, scope) => {
      const abuse = scope.abuse || {};
      const haystack = normalise([
        abuse.isp,
        abuse.domain,
        ...(Array.isArray(abuse.hostnames) ? abuse.hostnames : []),
      ].filter((part) => typeof part === 'string').join(' '));
      const matched = matchKeyword(context.keywords, haystack);
      if (!matched) return null;
      const score = Number(abuse.abuseConfidenceScore ?? 0);
      // At or above the threshold the address is genuinely bad: whitelisted ISP
      // or not, it has earned its place on the blocklist. Leave it alone.
      if (score >= context.maxScore) return null;
      return { reason: `whitelisted ISP "${matched}" with abuse confidence score ${score} < ${context.maxScore}` };
    },
  },
];

const RULES_BY_ID = new Map(RULES.map((rule) => [rule.id, rule]));

/**
 * Resolve the `ReviewRules` parameter against the registry.
 * Unknown keys are reported rather than ignored — a typo in the parameter would
 * otherwise silently disable a rule.
 */
function buildRuleSet(config) {
  const settings = config && typeof config === 'object' ? config : {};
  const active = { pre: [], post: [] };
  const applied = [];

  for (const rule of RULES) {
    const ruleConfig = settings[rule.id] && typeof settings[rule.id] === 'object' ? settings[rule.id] : {};
    const enabled = ruleConfig.enabled === undefined ? rule.defaultEnabled : Boolean(ruleConfig.enabled);
    if (!enabled) continue;
    const context = rule.prepare(ruleConfig);
    const entry = { id: rule.id, terminal: Boolean(rule.terminal), context, evaluate: rule.evaluate };
    active[rule.stage].push(entry);
    applied.push(`${rule.id}: ${rule.describe(context)}`);
  }

  const unknown = Object.keys(settings).filter((key) => !RULES_BY_ID.has(key));
  return { ...active, applied, unknown };
}

/**
 * Index the corpus so cross-entry rules (duplicate) have something to look at.
 *
 * Keyed on the canonical address, so `1.2.3.4` and `1.2.3.4/32` are correctly
 * the same entry, as are `2001:db8::1` and `2001:0db8:0000::0001`. Malformed
 * lines have no canonical form and are skipped: a repeated typo is reported as
 * malformed on each line it appears, which is what needs fixing anyway.
 *
 * Line lists are built in blob order, so element 0 is always the earliest.
 */
function buildCorpus(entries) {
  const linesByIp = new Map();
  for (const entry of entries) {
    if (!entry.ip) continue;
    const lines = linesByIp.get(entry.ip);
    if (lines) lines.push(entry.line);
    else linesByIp.set(entry.ip, [entry.line]);
  }
  return { linesByIp };
}

/**
 * Run the pre-stage rules.
 * Every enabled rule is evaluated so an entry can carry several reasons, but a
 * terminal match stops the entry from reaching AbuseIPDB.
 */
function applyPre(ruleSet, entry, corpus) {
  const reasons = [];
  let terminal = false;
  for (const rule of ruleSet.pre) {
    const verdict = rule.evaluate(entry, rule.context, { corpus });
    if (!verdict) continue;
    reasons.push({ ruleId: rule.id, reason: verdict.reason });
    if (rule.terminal) terminal = true;
  }
  return { reasons, terminal };
}

/** Run the post-stage rules. All are evaluated; reasons accumulate. */
function applyPost(ruleSet, entry, abuse) {
  const reasons = [];
  for (const rule of ruleSet.post) {
    const verdict = rule.evaluate(entry, rule.context, { abuse });
    if (verdict) reasons.push({ ruleId: rule.id, reason: verdict.reason });
  }
  return reasons;
}

module.exports = { RULES, applyPost, applyPre, buildCorpus, buildRuleSet };
