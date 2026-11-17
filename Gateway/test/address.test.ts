import { describe, expect, it } from "vitest";
import { UNKNOWN_ADDRESS, addressKey, addressKeys } from "../src/address";

describe("addressKey", () => {
  it.each([
    ["203.0.113.7", "203.0.113.7"],
    ["0.0.0.0", "0.0.0.0"],
    ["255.255.255.255", "255.255.255.255"],
    [" 198.51.100.9 ", "198.51.100.9"],
  ])("keeps the IPv4 address %j", (raw, key) => {
    expect(addressKey(raw)).toBe(key);
  });

  it.each([
    ["2001:db8:1:2:3:4:5:6", "2001:db8:1:2::/64"],
    ["2001:0db8:0001:0002:ffff:ffff:ffff:ffff", "2001:db8:1:2::/64"],
    ["2001:DB8:1:2::1", "2001:db8:1:2::/64"],
    // `::` in every place it can stand.
    ["2001:db8::1", "2001:db8:0:0::/64"],
    ["2001:db8::", "2001:db8:0:0::/64"],
    ["2001:db8:1::2:3", "2001:db8:1:0::/64"],
    ["2001:db8:1:2:3::", "2001:db8:1:2::/64"],
    ["::1", "0:0:0:0::/64"],
    ["::", "0:0:0:0::/64"],
    ["1::", "1:0:0:0::/64"],
    ["::2:3:4:5:6:7:8", "0:2:3:4::/64"],
    ["1:2:3:4:5:6:7::", "1:2:3:4::/64"],
    ["fe80::1ff:fe23:4567:890a", "fe80:0:0:0::/64"],
    ["[2001:db8:1:2::1]", "2001:db8:1:2::/64"],
    // An IPv4 tail that is not an IPv4-mapped address is just the last 32 bits.
    ["64:ff9b::203.0.113.7", "64:ff9b:0:0::/64"],
    ["2001:db8:1:2:3:4:203.0.113.7", "2001:db8:1:2::/64"],
  ])("reduces the IPv6 address %j to its /64", (raw, key) => {
    expect(addressKey(raw)).toBe(key);
  });

  it("gives every address of one /64 the same key, and the next /64 another", () => {
    const a = addressKey("2001:db8:aa:bb:1111:2222:3333:4444");
    expect(addressKey("2001:db8:aa:bb::1")).toBe(a);
    expect(addressKey("2001:db8:aa:bb:ffff:ffff:ffff:ffff")).toBe(a);
    expect(addressKey("2001:db8:aa:bc::1")).not.toBe(a);
  });

  it.each([
    ["::ffff:203.0.113.7", "203.0.113.7"],
    ["::FFFF:203.0.113.7", "203.0.113.7"],
    ["::ffff:cb00:7107", "203.0.113.7"],
    ["0:0:0:0:0:ffff:203.0.113.7", "203.0.113.7"],
    ["0000:0000:0000:0000:0000:ffff:cb00:7107", "203.0.113.7"],
  ])("reads the IPv4-mapped address %j as IPv4", (raw, key) => {
    expect(addressKey(raw)).toBe(key);
  });

  it.each([
    null,
    undefined,
    "",
    " ",
    "unknown",
    "not an address",
    "203.0.113",
    "203.0.113.7.1",
    "203.0.113.256",
    "203.0.113.-1",
    "203.0.113.07",
    "203.0.113.7:443",
    "0x7f.0.0.1",
    "1.2.3.4e0",
    ":",
    ":::",
    "1::2::3",
    "1:2:3:4:5:6:7",
    "1:2:3:4:5:6:7:8:9",
    "1:2:3:4:5:6:7:8::",
    "::1:2:3:4:5:6:7:8",
    "12345::1",
    "g::1",
    "2001:db8:1:2:",
    ":2001:db8:1:2::",
    "2001:db8::1%eth0",
    "2001:db8:1:2::1/64",
    "1.2.3.4::1",
    "::1.2.3.4.5",
    "::203.0.113.7:1",
    "[2001:db8::1",
    "2001:db8::\n1",
    "a".repeat(65),
  ])("answers unknown for %j", (raw) => {
    expect(addressKey(raw)).toBe(UNKNOWN_ADDRESS);
  });
});

describe("addressKeys", () => {
  it.each([
    ["2001:db8:1:2:3:4:5:6", "2001:db8:1:2::/64", "2001:db8:1::/48"],
    ["2001:0db8:0001:0002:ffff:ffff:ffff:ffff", "2001:db8:1:2::/64", "2001:db8:1::/48"],
    ["2001:DB8:AB:2::1", "2001:db8:ab:2::/64", "2001:db8:ab::/48"],
    ["2001:db8::1", "2001:db8:0:0::/64", "2001:db8:0::/48"],
    ["::1", "0:0:0:0::/64", "0:0:0::/48"],
    ["::", "0:0:0:0::/64", "0:0:0::/48"],
    ["1::", "1:0:0:0::/64", "1:0:0::/48"],
    ["fe80::1ff:fe23:4567:890a", "fe80:0:0:0::/64", "fe80:0:0::/48"],
    ["[2001:db8:1:2::1]", "2001:db8:1:2::/64", "2001:db8:1::/48"],
    ["64:ff9b::203.0.113.7", "64:ff9b:0:0::/64", "64:ff9b:0::/48"],
    ["ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "ffff:ffff:ffff:ffff::/64", "ffff:ffff:ffff::/48"],
  ])("gives the IPv6 address %j its /64 and its /48", (raw, key, wide) => {
    expect(addressKeys(raw)).toEqual({ key, wide });
    expect(addressKey(raw)).toBe(key);
  });

  it("gives every /64 of one /48 the same wide key, and the next /48 another", () => {
    const { key, wide } = addressKeys("2001:db8:aa:bb::1");
    expect(addressKeys("2001:db8:aa:bc::1")).toEqual({ key: "2001:db8:aa:bc::/64", wide });
    expect(addressKeys("2001:db8:aa:ffff:1:2:3:4").wide).toBe(wide);
    expect(addressKeys("2001:db8:aa::").wide).toBe(wide);
    expect(addressKeys("2001:db8:ab:bb::1").wide).not.toBe(wide);
    expect(addressKeys("2001:db9:aa:bb::1").wide).not.toBe(wide);
    // The two keys of one address never collide: each ends in its own prefix length.
    expect(key).not.toBe(wide);
    expect(wide).toMatch(/::\/48$/);
    expect(key).toMatch(/::\/64$/);
  });

  it.each([
    ["203.0.113.7", "203.0.113.7"],
    [" 198.51.100.9 ", "198.51.100.9"],
    ["::ffff:203.0.113.7", "203.0.113.7"],
    ["0:0:0:0:0:ffff:cb00:7107", "203.0.113.7"],
  ])("gives the IPv4 address %j one key and no wide key", (raw, key) => {
    expect(addressKeys(raw)).toEqual({ key, wide: null });
  });

  it.each([null, undefined, "", "unknown", "203.0.113.256", "1::2::3", "2001:db8:1:2::1/64", "a".repeat(65)])(
    "gives %j the unknown key and no wide key",
    (raw) => {
      expect(addressKeys(raw)).toEqual({ key: UNKNOWN_ADDRESS, wide: null });
    },
  );
});
