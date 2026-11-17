/**
 * The client address a limit is keyed by. An IPv4 address is one client. An IPv6 client
 * usually owns a whole /64 and can change the other 64 bits at will, so its key is the /64
 * prefix: otherwise one machine would have 2^64 separate allowances. A site is often given
 * a /48, which holds 65,536 such /64s, so an IPv6 client has a second, wider key, its /48,
 * and the daily caps in D1 count it under both.
 */

/** The keys of one client address. */
export interface AddressKeys {
  /** The IPv4 address, the /64 of an IPv6 address, or `unknown`. */
  key: string;
  /** The /48 of an IPv6 address. Null for IPv4 and `unknown`, which have the one key. */
  wide: string | null;
}

/** The key for a value that is not an address. All such requests share one allowance. */
export const UNKNOWN_ADDRESS = "unknown";

function parseIPv4(text: string): number[] | null {
  const parts = text.split(".");
  if (parts.length !== 4) return null;
  const octets: number[] = [];
  for (const part of parts) {
    // No leading zeros: some parsers read "010" as octal, so it names no single address.
    if (!/^(0|[1-9]\d{0,2})$/.test(part)) return null;
    const octet = Number(part);
    if (octet > 255) return null;
    octets.push(octet);
  }
  return octets;
}

/** The 16-bit groups of one side of `::`, or of a whole address without it. */
function parseGroups(text: string, mayEndInIPv4: boolean): number[] | null {
  if (text === "") return [];
  const parts = text.split(":");
  const groups: number[] = [];
  for (const [index, part] of parts.entries()) {
    if (mayEndInIPv4 && index === parts.length - 1 && part.includes(".")) {
      const octets = parseIPv4(part);
      if (!octets) return null;
      const [a = 0, b = 0, c = 0, d = 0] = octets;
      groups.push(a * 256 + b, c * 256 + d);
    } else {
      if (!/^[0-9a-fA-F]{1,4}$/.test(part)) return null;
      groups.push(Number.parseInt(part, 16));
    }
  }
  return groups;
}

/** The eight groups of an IPv6 address, with `::` expanded, or null when it is not one. */
function parseIPv6(text: string): number[] | null {
  const sides = text.split("::");
  if (sides.length > 2) return null;
  const [head = "", tail] = sides;
  if (tail === undefined) {
    const groups = parseGroups(head, true);
    return groups?.length === 8 ? groups : null;
  }
  const before = parseGroups(head, false);
  const after = parseGroups(tail, true);
  if (!before || !after) return null;
  // `::` stands for at least one group of zeros.
  const missing = 8 - before.length - after.length;
  if (missing < 1) return null;
  return [...before, ...new Array<number>(missing).fill(0), ...after];
}

/**
 * Normalizes what `CF-Connecting-IP` holds: `203.0.113.7` stays as it is, an IPv6 address
 * becomes its /64 (`2001:db8:0:1::/64`, four lowercase groups without leading zeros) with
 * its /48 (`2001:db8:0::/48`, three groups) as the wide key, and an IPv4-mapped IPv6 address
 * (`::ffff:203.0.113.7`) becomes the IPv4 address it stands for. Anything else is `unknown`.
 */
export function addressKeys(raw: string | null | undefined): AddressKeys {
  if (typeof raw !== "string" || raw.length > 64) return { key: UNKNOWN_ADDRESS, wide: null };
  let text = raw.trim();
  if (text.startsWith("[") && text.endsWith("]")) text = text.slice(1, -1);

  const v4 = parseIPv4(text);
  if (v4) return { key: v4.join("."), wide: null };

  const groups = parseIPv6(text);
  if (!groups) return { key: UNKNOWN_ADDRESS, wide: null };
  const [g0 = 0, g1 = 0, g2 = 0, g3 = 0, g4 = 0, g5 = 0, g6 = 0, g7 = 0] = groups;
  if (g0 === 0 && g1 === 0 && g2 === 0 && g3 === 0 && g4 === 0 && g5 === 0xffff) {
    return { key: `${g6 >> 8}.${g6 & 255}.${g7 >> 8}.${g7 & 255}`, wide: null };
  }
  const prefix = (count: number): string =>
    `${groups
      .slice(0, count)
      .map((group) => group.toString(16))
      .join(":")}::/${count * 16}`;
  return { key: prefix(4), wide: prefix(3) };
}

/** The one key the per-minute limiter uses: the IPv4 address or the /64. */
export function addressKey(raw: string | null | undefined): string {
  return addressKeys(raw).key;
}
