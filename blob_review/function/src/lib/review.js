'use strict';

const { checkMany } = require('./abuseipdb');
const { findingsToCsv } = require('./csv');
const { chunk, parseBlocklist } = require('./parse');
const { applyPost, applyPre, buildCorpus, buildRuleSet } = require('./rules');

/**
 * The review itself, split along the three Durable stages but with no Durable
 * dependency, so all of it is testable on a bare interpreter.
 *
 *   planReview   -> runs in the HTTP starter
 *   runBatch     -> runs in the activity
 *   summarise    -> runs in the orchestrator
 */

const DEFAULT_BATCH_SIZE = 1000;
const DEFAULT_MAX_FINDINGS = 5000;

function toFinding(entry, reasons, abuse) {
  const record = abuse || {};
  const hostnames = Array.isArray(record.hostnames) ? record.hostnames : [];
  return {
    ip: entry.ip || entry.text,
    line: entry.line,
    entry: entry.text,
    rules: reasons.map((item) => item.ruleId).join(' '),
    reasons: reasons.map((item) => item.reason).join('; '),
    checked: Boolean(abuse),
    isp: record.isp ?? null,
    domain: record.domain ?? null,
    hostnames: hostnames.length ? hostnames : null,
    countryCode: record.countryCode ?? null,
    usageType: record.usageType ?? null,
    abuseConfidenceScore: abuse ? (record.abuseConfidenceScore ?? 0) : null,
    totalReports: abuse ? (record.totalReports ?? 0) : null,
    lastReportedAt: record.lastReportedAt ?? null,
  };
}

/**
 * Parse the blob, apply the pre-stage rules and decide what still needs
 * AbuseIPDB. Terminal pre findings (internal, malformed) never leave this
 * function, so those addresses are never sent to a third party.
 */
function planReview(blobText, config = {}) {
  const ruleSet = buildRuleSet(config.rules);
  const { entries, counts: parseCounts } = parseBlocklist(blobText);
  const corpus = buildCorpus(entries);

  const preFindings = [];
  const candidates = [];
  const skipped = [];

  for (const entry of entries) {
    const { reasons, terminal } = applyPre(ruleSet, entry, corpus);
    if (terminal) {
      preFindings.push(toFinding(entry, reasons, null));
      continue;
    }
    if (entry.kind === 'cidr') {
      // AbuseIPDB /check takes a single address; /check-block is a different
      // endpoint with its own quota. Report the entry rather than drop it.
      skipped.push({ line: entry.line, entry: entry.text, reason: 'public CIDR range, not checked' });
      if (reasons.length) preFindings.push(toFinding(entry, reasons, null));
      continue;
    }
    candidates.push({ line: entry.line, text: entry.text, ip: entry.ip, kind: entry.kind, preReasons: reasons });
  }

  const batchSize = Number.parseInt(config.batchSize, 10) || DEFAULT_BATCH_SIZE;
  return {
    ruleSummary: { applied: ruleSet.applied, unknown: ruleSet.unknown },
    preFindings,
    skipped,
    batches: chunk(candidates, batchSize),
    counts: {
      lines: parseCounts.lines,
      entries: entries.length,
      commentsOrBlank: parseCounts.skippedLines,
      candidates: candidates.length,
      preFindings: preFindings.length,
      skippedCidrs: skipped.length,
    },
  };
}

/** Enrich one batch and apply the post-stage rules. Runs inside an activity. */
async function runBatch(batch, config = {}, deps = {}) {
  const ruleSet = buildRuleSet(config.rules);
  const items = Array.isArray(batch) ? batch : [];

  const { results, peakInFlight } = await checkMany(items.map((item) => item.ip), {
    apiKey: config.apiKey,
    maxAgeInDays: config.maxAgeInDays,
    parallelism: config.parallelism,
    timeoutMs: config.timeoutMs,
    maxAttempts: config.maxAttempts,
    fetchImpl: deps.fetchImpl,
    sleep: deps.sleep,
  });

  const findings = [];
  const errors = [];
  let checked = 0;

  for (let index = 0; index < items.length; index += 1) {
    const item = items[index];
    const outcome = results[index] || { error: 'no result' };
    if (outcome.error) {
      errors.push({ line: item.line, entry: item.text, error: outcome.error });
      continue;
    }
    checked += 1;
    const entry = { ip: item.ip, line: item.line, text: item.text };
    const reasons = [...(item.preReasons || []), ...applyPost(ruleSet, entry, outcome.data)];
    if (reasons.length) findings.push(toFinding(entry, reasons, outcome.data));
  }

  return {
    findings,
    errors,
    peakInFlight,
    counts: { requested: items.length, checked, findings: findings.length, errors: errors.length },
  };
}

function byLine(a, b) {
  return a.line - b.line;
}

/** Fold the plan and every batch result into the payload the Logic App reads. */
function summarise(plan, batchResults, config = {}) {
  const maxFindings = Number.parseInt(config.maxFindings, 10) || DEFAULT_MAX_FINDINGS;

  const findings = [...plan.preFindings];
  const errors = [];
  let checked = 0;
  let peakInFlight = 0;

  for (const result of batchResults) {
    findings.push(...result.findings);
    errors.push(...result.errors);
    checked += result.counts.checked;
    peakInFlight = Math.max(peakInFlight, result.peakInFlight || 0);
  }

  findings.sort(byLine);
  errors.sort(byLine);

  const truncated = findings.length > maxFindings;
  const reported = truncated ? findings.slice(0, maxFindings) : findings;

  return {
    summary: {
      entries: plan.counts.entries,
      checked,
      flagged: findings.length,
      internalOrMalformed: plan.counts.preFindings,
      skippedCidrs: plan.counts.skippedCidrs,
      errors: errors.length,
      peakInFlight,
      truncated,
      rulesApplied: plan.ruleSummary.applied,
      unknownRuleKeys: plan.ruleSummary.unknown,
    },
    findings: reported,
    // Diagnostics are capped; the summary counts above never are, so a capped
    // array cannot hide how much was dropped.
    skipped: plan.skipped.slice(0, 100),
    errorDetail: errors.slice(0, 100),
    csv: reported.length ? findingsToCsv(reported) : '',
  };
}

module.exports = { DEFAULT_BATCH_SIZE, DEFAULT_MAX_FINDINGS, planReview, runBatch, summarise, toFinding };
