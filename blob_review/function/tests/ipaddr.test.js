'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { formatEntry, isPrivate, parseEntry, parseNetwork } = require('../src/lib/ipaddr');

const classify = (text) => parseEntry(text).kind;
const internal = (text) => isPrivate(parseEntry(text));

test('rejects the typos an EDL actually collects', () => {
  for (const bad of [
    '999.1.1.1', '10.0.0', '1.2.3.4.5', '192.168.0.256', '1.2.3.4.', '.1.2.3',
    '10.0.0.1.', '1.2.3.-4', '', 'not-an-ip', '1.2.3.4/33', '::1/129',
    '1:2:3:4:5:6:7', '1:2:3:4:5:6:7:8:9', '1::2::3', 'fe80::1%eth0', '12345::1',
  ]) {
    assert.equal(classify(bad), 'invalid', `${bad} should be malformed`);
  }
});

test('rejects leading-zero octets, which resolvers disagree about', () => {
  assert.equal(classify('010.0.0.1'), 'invalid');
  assert.equal(classify('192.168.01.1'), 'invalid');
});

test('accepts the addresses that belong on a blocklist', () => {
  for (const good of ['8.8.8.8', '1.2.3.4', '255.255.255.254', '2001:4860:4860::8888', '::ffff:8.8.8.8']) {
    assert.equal(classify(good), 'ip', `${good} should parse`);
  }
});

test('a /32 or /128 is a single host, not a range', () => {
  assert.equal(classify('1.2.3.4/32'), 'ip');
  assert.equal(formatEntry(parseEntry('1.2.3.4/32')), '1.2.3.4');
  assert.equal(classify('2001:db8::1/128'), 'ip');
  assert.equal(classify('10.0.0.0/8'), 'cidr');
});

test('host bits are masked off, matching ipaddress(strict=False)', () => {
  assert.equal(formatEntry(parseEntry('1.2.3.4/8')), '1.0.0.0/8');
  assert.equal(formatEntry(parseEntry('192.168.5.9/16')), '192.168.0.0/16');
});

test('the near misses a naive startsWith or regex gets wrong', () => {
  // Each of these sits next to real RFC1918 space and is the reason this module
  // does CIDR arithmetic instead of prefix strings.
  for (const routable of ['1.10.0.1', '172.15.0.1', '172.32.0.1', '193.168.0.1', '110.0.0.1']) {
    assert.equal(internal(routable), false, `${routable} must not be internal`);
  }
  for (const reserved of ['172.16.0.1', '172.31.255.254', '10.34.2.7', '192.168.1.1']) {
    assert.equal(internal(reserved), true, `${reserved} must be internal`);
  }
});

test('internal covers the whole special-purpose registry, not just RFC1918', () => {
  for (const special of [
    '127.0.0.1',        // loopback
    '169.254.1.1',      // link-local
    '100.64.0.1',       // CGNAT
    '192.0.2.1',        // TEST-NET-1
    '198.51.100.1',     // TEST-NET-2
    '203.0.113.1',      // TEST-NET-3
    '198.18.0.1',       // benchmarking
    '240.0.0.1',        // reserved
    '255.255.255.255',  // broadcast
    '0.0.0.0',          // this network
  ]) {
    assert.equal(internal(special), true, `${special} must be internal`);
  }
});

test('IPv6 private space and its public near misses', () => {
  for (const reserved of ['::1', '::', 'fc00::1', 'fd12:3456::1', 'fe80::1', '2001:db8::1', '2001::1']) {
    assert.equal(internal(reserved), true, `${reserved} must be internal`);
  }
  for (const routable of ['2001:4860:4860::8888', '2606:4700:4700::1111', 'fec0::1']) {
    assert.equal(internal(routable), false, `${routable} must not be internal`);
  }
});

test('an IPv4-mapped IPv6 address inherits the IPv4 verdict', () => {
  assert.equal(internal('::ffff:10.0.0.1'), true);
  assert.equal(internal('::ffff:8.8.8.8'), false);
  assert.equal(formatEntry(parseEntry('::ffff:10.0.0.1')), '::ffff:10.0.0.1');
});

test('a private CIDR range is internal; a public one is not', () => {
  assert.equal(internal('192.168.0.0/16'), true);
  assert.equal(internal('10.0.0.0/8'), true);
  assert.equal(internal('1.1.1.0/24'), false);
  // A range that merely straddles private space is not a subnet of it.
  assert.equal(internal('172.0.0.0/8'), false);
});

test('IPv6 is compressed per RFC 5952', () => {
  assert.equal(formatEntry(parseEntry('2001:0db8:0000:0000:0000:0000:0000:0001')), '2001:db8::1');
  assert.equal(formatEntry(parseEntry('0:0:0:0:0:0:0:1')), '::1');
  assert.equal(formatEntry(parseEntry('1:0:0:2:0:0:0:3')), '1:0:0:2::3');
});

test('parseNetwork refuses anything without a usable prefix', () => {
  assert.equal(parseNetwork('10.0.0.0'), null);
  assert.equal(parseNetwork('10.0.0.0/'), null);
  assert.equal(parseNetwork('10.0.0.0/x'), null);
});
