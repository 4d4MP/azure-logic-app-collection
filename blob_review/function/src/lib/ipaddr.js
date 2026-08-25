'use strict';

/**
 * IPv4/IPv6 address arithmetic, dependency-free.
 *
 * Node has no equivalent of Python's `ipaddress`, which is what the previous
 * Python runner leaned on. This module reimplements the part we need with
 * BigInt so both families go through the same code path.
 *
 * Parsing is deliberately strict — an entry that does not parse here becomes a
 * `malformed` finding, so "999.1.1.1", "10.0.0" and "192.168.0.256" must all be
 * rejected rather than coerced into something plausible.
 */

const V4_BITS = 32;
const V6_BITS = 128;

/** Special-purpose IPv4 space. Mirrors Python's `IPv4Address.is_private`. */
const PRIVATE_V4 = [
  '0.0.0.0/8',          // "this network"
  '10.0.0.0/8',         // RFC1918
  '100.64.0.0/10',      // CGNAT
  '127.0.0.0/8',        // loopback
  '169.254.0.0/16',     // link-local
  '172.16.0.0/12',      // RFC1918
  '192.0.0.0/24',       // IETF protocol assignments
  '192.0.2.0/24',       // TEST-NET-1
  '192.168.0.0/16',     // RFC1918
  '198.18.0.0/15',      // benchmarking
  '198.51.100.0/24',    // TEST-NET-2
  '203.0.113.0/24',     // TEST-NET-3
  '240.0.0.0/4',        // reserved
  '255.255.255.255/32', // broadcast
];

/** Special-purpose IPv6 space. Mirrors Python's `IPv6Address.is_private`. */
const PRIVATE_V6 = [
  '::/128',             // unspecified
  '::1/128',            // loopback
  '64:ff9b:1::/48',     // local-use IPv4/IPv6 translation
  '100::/64',           // discard-only
  '2001::/23',          // IETF protocol assignments
  '2001:db8::/32',      // documentation
  'fc00::/7',           // unique local
  'fe80::/10',          // link-local
];

/** `::ffff:0:0/96` — an IPv4 address wearing an IPv6 costume. */
const V4_MAPPED_PREFIX = 0xffffn;

function parseIPv4(text) {
  const parts = text.split('.');
  if (parts.length !== 4) return null;
  let value = 0n;
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null;
    // Leading zeros are ambiguous (octal in some resolvers) and are a typo signal.
    if (part.length > 1 && part[0] === '0') return null;
    const octet = Number(part);
    if (octet > 255) return null;
    value = (value << 8n) | BigInt(octet);
  }
  return { version: 4, value };
}

function expandGroups(parts) {
  const groups = [];
  for (let index = 0; index < parts.length; index += 1) {
    const part = parts[index];
    if (part.includes('.')) {
      // A dotted quad is only legal as the final group.
      if (index !== parts.length - 1) return null;
      const embedded = parseIPv4(part);
      if (!embedded) return null;
      groups.push(Number(embedded.value >> 16n), Number(embedded.value & 0xffffn));
      continue;
    }
    if (!/^[0-9a-fA-F]{1,4}$/.test(part)) return null;
    groups.push(parseInt(part, 16));
  }
  return groups;
}

function parseIPv6(text) {
  if (text.includes('%')) return null;            // zone ids do not belong on an EDL
  if (text.split('::').length > 2) return null;   // at most one '::'

  const marker = text.indexOf('::');
  const headText = marker === -1 ? text : text.slice(0, marker);
  const tailText = marker === -1 ? '' : text.slice(marker + 2);

  const headParts = headText === '' ? [] : headText.split(':');
  const tailParts = tailText === '' ? [] : tailText.split(':');
  if (headParts.includes('') || tailParts.includes('')) return null;

  const head = expandGroups(headParts);
  const tail = expandGroups(tailParts);
  if (head === null || tail === null) return null;
  // With a '::' present, an embedded quad in the head is not the final group.
  if (marker !== -1 && headParts.some((part) => part.includes('.'))) return null;

  const supplied = head.length + tail.length;
  if (marker === -1) {
    if (supplied !== 8) return null;
  } else if (supplied > 7) {
    return null;                                  // '::' must stand for >= 1 zero group
  }

  const groups = [...head, ...new Array(8 - supplied).fill(0), ...tail];
  let value = 0n;
  for (const group of groups) value = (value << 16n) | BigInt(group);
  return { version: 6, value };
}

/** Parse a bare address. Returns `{version, value}` or null. */
function parseAddress(text) {
  if (typeof text !== 'string' || text === '') return null;
  return text.includes(':') ? parseIPv6(text) : parseIPv4(text);
}

/**
 * Parse `address/prefix`. Host bits are masked off (Python's `strict=False`),
 * so `10.1.2.3/8` is accepted and becomes `10.0.0.0/8`.
 */
function parseNetwork(text) {
  if (typeof text !== 'string') return null;
  const slash = text.indexOf('/');
  if (slash === -1) return null;
  const address = parseAddress(text.slice(0, slash));
  const prefixText = text.slice(slash + 1);
  if (!address || !/^\d{1,3}$/.test(prefixText)) return null;
  const bits = address.version === 4 ? V4_BITS : V6_BITS;
  const prefix = Number(prefixText);
  if (prefix > bits) return null;
  const hostBits = BigInt(bits - prefix);
  return {
    version: address.version,
    value: (address.value >> hostBits) << hostBits,
    prefix,
    bits,
  };
}

/**
 * Classify one blocklist entry.
 *
 * A /32 or /128 is a single host written in CIDR form, so it is reported as an
 * address — carried over from the Python runner, which did the same.
 */
function parseEntry(text) {
  const address = parseAddress(text);
  if (address) return { kind: 'ip', address };
  const network = parseNetwork(text);
  if (!network) return { kind: 'invalid' };
  if (network.prefix === network.bits) {
    return { kind: 'ip', address: { version: network.version, value: network.value } };
  }
  return { kind: 'cidr', network };
}

function contains(network, address) {
  if (network.version !== address.version) return false;
  const hostBits = BigInt(network.bits - network.prefix);
  return (address.value >> hostBits) === (network.value >> hostBits);
}

function subnetOf(inner, outer) {
  if (inner.version !== outer.version) return false;
  if (inner.prefix < outer.prefix) return false;
  return contains(outer, { version: inner.version, value: inner.value });
}

/** The embedded IPv4 address of an `::ffff:a.b.c.d` mapping, if this is one. */
function ipv4Mapped(address) {
  if (address.version !== 6) return null;
  if (address.value >> 32n !== V4_MAPPED_PREFIX) return null;
  return { version: 4, value: address.value & 0xffffffffn };
}

function withinAny(entry, networks) {
  if (entry.kind === 'cidr') {
    return networks.some((network) => subnetOf(entry.network, network));
  }
  if (entry.kind !== 'ip') return false;
  const mapped = ipv4Mapped(entry.address);
  const candidates = mapped ? [entry.address, mapped] : [entry.address];
  return networks.some((network) => candidates.some((address) => contains(network, address)));
}

const PRIVATE_NETWORKS = [...PRIVATE_V4, ...PRIVATE_V6].map((cidr) => {
  const network = parseNetwork(cidr);
  if (!network) throw new Error(`built-in private network is unparseable: ${cidr}`);
  return network;
});

/** True for RFC1918 and the rest of the IANA special-purpose registry. */
function isPrivate(entry) {
  return withinAny(entry, PRIVATE_NETWORKS);
}

function formatIPv4(value) {
  return [24n, 16n, 8n, 0n].map((shift) => Number((value >> shift) & 0xffn)).join('.');
}

/** RFC 5952: lower-case, no leading zeros, longest run of zero groups collapsed. */
function formatIPv6(value) {
  const groups = [];
  for (let shift = 112n; shift >= 0n; shift -= 16n) {
    groups.push(Number((value >> shift) & 0xffffn));
  }
  let bestStart = -1;
  let bestLength = 0;
  let start = -1;
  for (let index = 0; index <= groups.length; index += 1) {
    if (index < groups.length && groups[index] === 0) {
      if (start === -1) start = index;
      continue;
    }
    if (start !== -1) {
      const length = index - start;
      if (length > bestLength) {
        bestStart = start;
        bestLength = length;
      }
      start = -1;
    }
  }
  const text = groups.map((group) => group.toString(16));
  if (bestLength < 2) return text.join(':');
  return `${text.slice(0, bestStart).join(':')}::${text.slice(bestStart + bestLength).join(':')}`;
}

function formatAddress(address) {
  if (address.version === 4) return formatIPv4(address.value);
  // RFC 5952 keeps IPv4-mapped addresses in dotted form; a ticket reader wants
  // to see ::ffff:10.0.0.1, not ::ffff:a00:1.
  const mapped = ipv4Mapped(address);
  if (mapped) return `::ffff:${formatIPv4(mapped.value)}`;
  return formatIPv6(address.value);
}

function formatEntry(entry) {
  if (entry.kind === 'ip') return formatAddress(entry.address);
  if (entry.kind === 'cidr') {
    return `${formatAddress({ version: entry.network.version, value: entry.network.value })}/${entry.network.prefix}`;
  }
  return null;
}

module.exports = {
  PRIVATE_V4,
  PRIVATE_V6,
  contains,
  formatAddress,
  formatEntry,
  ipv4Mapped,
  isPrivate,
  parseAddress,
  parseEntry,
  parseNetwork,
  subnetOf,
  withinAny,
};
