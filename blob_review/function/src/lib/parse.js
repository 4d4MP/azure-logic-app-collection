'use strict';

const { parseEntry, formatEntry } = require('./ipaddr');

/**
 * Turn the raw blocklist blob into entries that remember where they came from.
 *
 * The EDL is written by the other playbooks in this collection as plain
 * newline-separated addresses (`ti_handling_automation` composes
 * `<existing>\n<new IPs joined by \n>\n` and PUTs it as a BlockBlob), so despite
 * the `index.html` name there is no markup in it. Comment and `<` prefixes are
 * defensive only.
 *
 * The line number is the whole point of parsing here rather than in the Logic
 * App: `split` -> `trim` -> `filter` over a Logic App array destroys the index,
 * and a finding without a line number is a finding an operator has to grep for.
 */

const COMMENT_PREFIXES = ['#', '//', '<'];

function isSkippable(text) {
  return text === '' || COMMENT_PREFIXES.some((prefix) => text.startsWith(prefix));
}

/**
 * @returns {{entries: Array, counts: {lines: number, skippedLines: number}}}
 *   Each entry is `{line, text, kind, address?, network?, ip}` where `line` is
 *   1-based and `ip` is the canonical form (null when the entry is malformed).
 */
function parseBlocklist(blobText) {
  const text = typeof blobText === 'string' ? blobText : String(blobText ?? '');
  const lines = text.replace(/\r/g, '').split('\n');

  const entries = [];
  let skippedLines = 0;

  for (let index = 0; index < lines.length; index += 1) {
    const trimmed = lines[index].trim();
    if (isSkippable(trimmed)) {
      skippedLines += 1;
      continue;
    }
    const parsed = parseEntry(trimmed);
    entries.push({
      line: index + 1,
      text: trimmed,
      kind: parsed.kind,
      address: parsed.address,
      network: parsed.network,
      ip: formatEntry(parsed),
    });
  }

  return { entries, counts: { lines: lines.length, skippedLines } };
}

function chunk(items, size) {
  const width = Math.max(1, Math.floor(size));
  const batches = [];
  for (let index = 0; index < items.length; index += width) {
    batches.push(items.slice(index, index + width));
  }
  return batches;
}

module.exports = { chunk, isSkippable, parseBlocklist };
