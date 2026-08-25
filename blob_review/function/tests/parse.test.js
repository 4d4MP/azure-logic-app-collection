'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { chunk, parseBlocklist } = require('../src/lib/parse');

test('line numbers survive blanks, comments and CRLF', () => {
  const blob = [
    '# Sentinel Threat Intelligence IPs',   // 1
    '',                                     // 2
    '1.2.3.4',                              // 3
    '// retired 2026-01',                   // 4
    '  5.6.7.8  ',                          // 5, padded
    '<!-- stray markup -->',                // 6
    '9.9.9.9',                              // 7
  ].join('\r\n');

  const { entries, counts } = parseBlocklist(blob);
  assert.deepEqual(entries.map((entry) => [entry.line, entry.ip]), [
    [3, '1.2.3.4'],
    [5, '5.6.7.8'],
    [7, '9.9.9.9'],
  ]);
  assert.equal(counts.lines, 7);
  assert.equal(counts.skippedLines, 4);
});

test('a trailing newline does not invent an entry', () => {
  const { entries } = parseBlocklist('1.2.3.4\n5.6.7.8\n');
  assert.equal(entries.length, 2);
  assert.equal(entries[1].line, 2);
});

test('a malformed line is kept, with its line number, not dropped', () => {
  const { entries } = parseBlocklist('1.2.3.4\n999.1.1.1\n');
  assert.equal(entries[1].kind, 'invalid');
  assert.equal(entries[1].line, 2);
  assert.equal(entries[1].text, '999.1.1.1');
  assert.equal(entries[1].ip, null);
});

test('non-string input does not throw', () => {
  assert.deepEqual(parseBlocklist(null).entries, []);
  assert.deepEqual(parseBlocklist(undefined).entries, []);
});

test('chunk splits evenly and never returns a zero-width batch', () => {
  assert.deepEqual(chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]]);
  assert.deepEqual(chunk([], 10), []);
  assert.equal(chunk([1, 2, 3], 0).length, 3);
});
