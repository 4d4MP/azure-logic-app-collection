'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { compileKeywords, matchKeyword, normalise } = require('../src/lib/text');

const KEYWORDS = compileKeywords([
  'akamai technologies', 'google', 'palo alto networks',
  'the shadowserver foundation', 'censys', 'lufthansa', 'lido', 'sita aero',
]);
const match = (text) => matchKeyword(KEYWORDS, normalise(text));

test('normalising collapses punctuation and case', () => {
  assert.equal(normalise('SITA.aero'), 'sita aero');
  assert.equal(normalise('Palo Alto Networks, Inc.'), 'palo alto networks inc');
  assert.equal(normalise(null), '');
  assert.equal(normalise(undefined), '');
});

test('a keyword matches through punctuation and legal suffixes', () => {
  assert.equal(match('SITA.aero'), 'sita aero');
  assert.equal(match('sita-aero.net'), 'sita aero');
  assert.equal(match('Palo Alto Networks, Inc'), 'palo alto networks');
  assert.equal(match('Akamai Technologies, Inc.'), 'akamai technologies');
  assert.equal(match('Deutsche Lufthansa AG'), 'lufthansa');
  assert.equal(match('Censys, Inc.'), 'censys');
  assert.equal(match('The Shadowserver Foundation'), 'the shadowserver foundation');
});

test('word boundaries keep short keywords usable', () => {
  // Every one of these matches a plain substring test and must not match here.
  assert.equal(match('Lidonet Communications'), null);
  assert.equal(match('solido.com'), null);
  assert.equal(match('Sitawi Finance'), null);
  assert.equal(match('Googol Hosting'), null);
});

test('blank and non-string keywords are dropped, not crashed on', () => {
  const compiled = compileKeywords(['', '   ', null, 'lido']);
  assert.equal(compiled.length, 1);
  assert.equal(matchKeyword(compiled, normalise('LIDO GmbH')), 'lido');
  assert.deepEqual(compileKeywords('not-an-array'), []);
});

test('regex metacharacters in a keyword are literal', () => {
  const compiled = compileKeywords(['a.b']);
  assert.equal(matchKeyword(compiled, normalise('a.b')), 'a.b');
  assert.equal(matchKeyword(compiled, normalise('axb')), null);
});
