'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { escapeCell, findingsToCsv } = require('../src/lib/csv');

test('a comma-bearing ISP name is quoted, not split', () => {
  assert.equal(escapeCell('Palo Alto Networks, Inc'), '"Palo Alto Networks, Inc"');
});

test('embedded quotes are doubled', () => {
  assert.equal(escapeCell('whitelisted ISP "lido"'), '"whitelisted ISP ""lido"""');
});

test('empty and missing values read n/a rather than blank', () => {
  assert.equal(escapeCell(null), 'n/a');
  assert.equal(escapeCell(undefined), 'n/a');
  assert.equal(escapeCell(''), 'n/a');
  // Zero is a real score and must survive.
  assert.equal(escapeCell(0), '0');
});

test('third-party text cannot become a spreadsheet formula', () => {
  // AbuseIPDB supplies isp/domain/hostnames and an operator opens this in Excel.
  assert.equal(escapeCell('=1+1'), "'=1+1");
  assert.equal(escapeCell('@SUM(A1)'), "'@SUM(A1)");
  assert.equal(escapeCell('-2+3'), "'-2+3");
});

test('newlines inside a value are quoted, keeping one row per finding', () => {
  assert.equal(escapeCell('a\nb'), '"a\nb"');
});

test('the document has a header row and one row per finding', () => {
  const csv = findingsToCsv([
    { ip: '1.2.3.4', line: 7, entry: '1.2.3.4', rules: 'whitelistedIsp', reasons: 'x', isp: 'Akamai Technologies, Inc.', abuseConfidenceScore: 0 },
    { ip: '10.0.0.1', line: 9, entry: '10.0.0.1', rules: 'internal', reasons: 'internal address space' },
  ]);
  const rows = csv.trimEnd().split('\r\n');
  assert.equal(rows.length, 3);
  assert.match(rows[0], /^IP,Line,Blob entry,Rules,Reason,ISP,/);
  assert.match(rows[1], /^1\.2\.3\.4,7,1\.2\.3\.4,whitelistedIsp,x,"Akamai Technologies, Inc\.",/);
  // A finding with no enrichment reads n/a rather than leaving holes.
  assert.match(rows[2], /,n\/a,n\/a,n\/a,n\/a,n\/a,n\/a,n\/a$/);
});
