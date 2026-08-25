'use strict';

/**
 * Whole-word keyword matching over normalised text.
 *
 * Ported unchanged in behaviour from the Python runner (`_normalise` /
 * `_compile_keywords`), because both halves of it are load-bearing:
 *
 *  - Normalising collapses punctuation, so one keyword `sita aero` matches
 *    `SITA.aero`, `sita-aero.net` and `SITA AERO` without the list having to
 *    guess formatting. It is also what makes `palo alto networks` match
 *    AbuseIPDB's `Palo Alto Networks, Inc` — the other playbooks in this
 *    collection need a substring match for exactly that case.
 *  - Word boundaries are what keep a four-letter keyword usable: a plain
 *    substring test for `lido` also fires on `Lidonet Communications` and
 *    `solido.com`, which would flood the ticket with noise.
 */

const NON_ALNUM = /[^a-z0-9]+/g;

function normalise(value) {
  const text = typeof value === 'string' ? value : value === null || value === undefined ? '' : String(value);
  return text.toLowerCase().replace(NON_ALNUM, ' ').trim();
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Compile keywords to whole-word patterns. Blank keywords are dropped. */
function compileKeywords(keywords) {
  if (!Array.isArray(keywords)) return [];
  const compiled = [];
  for (const keyword of keywords) {
    const normalised = normalise(keyword);
    if (!normalised) continue;
    compiled.push({ label: String(keyword), pattern: new RegExp(`\\b${escapeRegExp(normalised)}\\b`) });
  }
  return compiled;
}

/** The first keyword matching `haystack`, or null. */
function matchKeyword(compiled, haystack) {
  const found = compiled.find((entry) => entry.pattern.test(haystack));
  return found ? found.label : null;
}

module.exports = { compileKeywords, escapeRegExp, matchKeyword, normalise };
