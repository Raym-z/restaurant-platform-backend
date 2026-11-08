import { describe, expect, it } from "vitest";

import {
  ipBucketValue,
  keyedHash,
  normalizeIp,
  selectClientIp,
} from "../../supabase/functions/_shared/clientIdentity.ts";

const config = (header: string | null, hops = 1) => ({
  trustedHeader: header,
  trustedProxyHops: hops,
});

describe("client IP normalization", () => {
  it("normalizes IPv4 and IPv6 values", () => {
    expect(normalizeIp("203.0.113.10")).toBe("v4:203.0.113.10");
    expect(normalizeIp("2001:db8::1")).toBe(
      "v6:20010db8000000000000000000000001",
    );
    expect(normalizeIp("[2001:db8::1]")).toBe(
      "v6:20010db8000000000000000000000001",
    );
    expect(normalizeIp("::ffff:192.0.2.1")).toBe(
      "v6:00000000000000000000ffffc0000201",
    );
  });

  it("rejects malformed, zoned, port-bearing, and oversized values", () => {
    for (const value of [
      "999.1.1.1",
      "1.2.3",
      "1.2.3.4:443",
      "[2001:db8::1]:443",
      "fe80::1%eth0",
      "2001:::1",
      "x".repeat(100),
    ]) {
      expect(normalizeIp(value)).toBeNull();
    }
  });
});

describe("trusted client IP selection", () => {
  it("uses the peer address when no trusted header is configured", () => {
    const headers = new Headers({ "x-forwarded-for": "1.2.3.4" });
    const identity = selectClientIp({
      headers,
      peerAddress: "198.51.100.7",
      config: config(null),
    });

    expect(identity).toEqual({ ip: "v4:198.51.100.7", source: "peer" });
  });

  it("does not trust the first x-forwarded-for value", () => {
    const headers = new Headers({
      "x-forwarded-for": "203.0.113.9, 10.0.0.5",
    });
    const identity = selectClientIp({
      headers,
      peerAddress: "198.51.100.7",
      config: config("x-forwarded-for", 1),
    });

    expect(identity).toEqual({ ip: "v4:10.0.0.5", source: "header" });
  });

  it("selects the correct hop from the right", () => {
    const headers = new Headers({
      "x-forwarded-for": "203.0.113.9, 10.0.0.5, 10.0.0.6",
    });

    expect(
      selectClientIp({
        headers,
        peerAddress: null,
        config: config("x-forwarded-for", 2),
      }),
    ).toEqual({ ip: "v4:10.0.0.5", source: "header" });

    expect(
      selectClientIp({
        headers,
        peerAddress: null,
        config: config("x-forwarded-for", 3),
      }),
    ).toEqual({ ip: "v4:203.0.113.9", source: "header" });
  });

  it("falls back to the peer for insufficient hops, duplicates, or malformed values", () => {
    const tooFew = new Headers({ "x-forwarded-for": "203.0.113.9" });
    expect(
      selectClientIp({
        headers: tooFew,
        peerAddress: "198.51.100.7",
        config: config("x-forwarded-for", 2),
      }),
    ).toEqual({ ip: "v4:198.51.100.7", source: "peer" });

    const duplicate = new Headers({
      "cf-connecting-ip": "203.0.113.9, 198.51.100.8",
    });
    expect(
      selectClientIp({
        headers: duplicate,
        peerAddress: "198.51.100.7",
        config: config("cf-connecting-ip"),
      }),
    ).toEqual({ ip: "v4:198.51.100.7", source: "peer" });

    const malformed = new Headers({ "x-real-ip": "not-an-ip" });
    expect(
      selectClientIp({
        headers: malformed,
        peerAddress: null,
        config: config("x-real-ip"),
      }),
    ).toEqual({ ip: null, source: "missing" });
  });

  it("handles missing, IPv6, and oversized trusted values", () => {
    expect(
      selectClientIp({
        headers: new Headers(),
        peerAddress: null,
        config: config("x-real-ip"),
      }),
    ).toEqual({ ip: null, source: "missing" });

    expect(
      selectClientIp({
        headers: new Headers({ "x-real-ip": "2001:db8::1" }),
        peerAddress: null,
        config: config("x-real-ip"),
      }),
    ).toEqual({
      ip: "v6:20010db8000000000000000000000001",
      source: "header",
    });

    expect(
      selectClientIp({
        headers: new Headers({ "x-real-ip": `1.${"2".repeat(100)}` }),
        peerAddress: "198.51.100.7",
        config: config("x-real-ip"),
      }),
    ).toEqual({ ip: "v4:198.51.100.7", source: "peer" });
  });
});

describe("privacy-preserving bucket keys", () => {
  it("does not store the raw IP and is stable per secret", async () => {
    const secret = "a".repeat(32);
    const ip = "203.0.113.10";
    const first = await keyedHash(secret, ip);
    const second = await keyedHash(secret, ip);
    const otherSecret = await keyedHash("b".repeat(32), ip);

    expect(first).toMatch(/^[0-9a-f]{64}$/);
    expect(first).toBe(second);
    expect(first).not.toBe(otherSecret);
    expect(first).not.toContain(ip);
    expect(ipBucketValue({ ip: null, source: "missing" })).toBe("unknown");
  });
});
