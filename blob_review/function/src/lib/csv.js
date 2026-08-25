'use strict';

/**
 * RFC 4180 CSV, built here rather than in the Logic App.
 *
 * Quoting an ISP name like `Palo Alto Networks, Inc` correctly is a few lines of
 * JavaScript and a nightmare of nested `replace()` calls in the Workflow
 * Definition Language, so the runner hands the Logic App a finished document to
 * drop straight into the multipart attachment body.
 */

const COLUMNS = [
  ['ip', 'IP'],
  ['line', 'Line'],
  ['entry', 'Blob entry'],
  ['rules', 'Rules'],
  ['reasons', 'Reason'],
  ['isp', 'ISP'],
  ['domain', 'Domain'],
  ['hostnames', 'Hostnames'],
  ['countryCode', 'Country'],
  ['usageType', 'Usage type'],
  ['abuseConfidenceScore', 'Abuse confidence score'],
  ['totalReports', 'Total reports'],
  ['lastReportedAt', 'Last reported at'],
];

/** Spreadsheets execute a leading =, +, - or @ — and ISP text is third-party. */
const FORMULA_PREFIX = /^[=+\-@\t\r]/;

function escapeCell(value) {
  if (value === null || value === undefined) return 'n/a';
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);

  let text = Array.isArray(value) ? value.join(' ') : String(value);
  if (text === '') return 'n/a';
  if (FORMULA_PREFIX.test(text)) text = `'${text}`;
  if (/[",\r\n]/.test(text) || text !== text.trim()) {
    return `"${text.replace(/"/g, '""')}"`;
  }
  return text;
}

function toRow(values) {
  return values.map(escapeCell).join(',');
}

function findingsToCsv(findings) {
  const lines = [toRow(COLUMNS.map(([, header]) => header))];
  for (const finding of findings) {
    lines.push(toRow(COLUMNS.map(([key]) => finding[key])));
  }
  return `${lines.join('\r\n')}\r\n`;
}

module.exports = { COLUMNS, escapeCell, findingsToCsv, toRow };
