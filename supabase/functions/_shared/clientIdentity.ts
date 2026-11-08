export type TrustedIpConfig = {
  trustedHeader: string | null;
  trustedProxyHops: number;
};

export type ClientIdentity = {
  ip: string | null;
  source: "peer" | "header" | "missing";
};

const TRUSTED_HEADERS = new Set([
  "cf-connecting-ip",
  "x-real-ip",
  "x-forwarded-for",
]);

export const isTrustedIpHeader = (value: string): boolean =>
  TRUSTED_HEADERS.has(value.toLowerCase());

const IPV4_PATTERN = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;

const parseIpv4 = (raw: string): string | null => {
  const match = IPV4_PATTERN.exec(raw);
  if (match === null) return null;

  const octets = match.slice(1).map((part) => Number(part));
  if (octets.some((octet) => octet < 0 || octet > 255)) return null;

  return `v4:${octets.join(".")}`;
};

const parseIpv6Side = (side: string): string[] | null => {
  if (side === "") return [];

  const parts = side.split(":");
  const groups: string[] = [];

  for (const part of parts) {
    if (part.length === 0) return null;

    const ipv4 = parseIpv4(part);
    if (ipv4 !== null) {
      const octets = ipv4.slice(3).split(".").map(Number);
      groups.push(
        ((octets[0]! << 8) | octets[1]!).toString(16),
        ((octets[2]! << 8) | octets[3]!).toString(16),
      );
      continue;
    }

    if (!/^[0-9a-fA-F]{1,4}$/.test(part)) return null;
    groups.push(part.toLowerCase());
  }

  return groups;
};

const parseIpv6 = (raw: string): string | null => {
  if (!raw.includes(":")) return null;

  const doubleColonIndex = raw.indexOf("::");
  if (
    doubleColonIndex !== -1 &&
    raw.indexOf("::", doubleColonIndex + 2) !== -1
  ) {
    return null;
  }

  let left: string[];
  let right: string[];

  if (doubleColonIndex === -1) {
    const parsed = parseIpv6Side(raw);
    if (parsed === null) return null;
    left = parsed;
    right = [];
    if (left.length !== 8) return null;
  } else {
    const parsedLeft = parseIpv6Side(raw.slice(0, doubleColonIndex));
    const parsedRight = parseIpv6Side(raw.slice(doubleColonIndex + 2));
    if (parsedLeft === null || parsedRight === null) return null;

    left = parsedLeft;
    right = parsedRight;
    const missing = 8 - left.length - right.length;
    if (missing < 1) return null;
    left = [...left, ...Array.from({ length: missing }, () => "0"), ...right];
  }

  if (left.length !== 8) return null;

  return `v6:${left.map((group) => group.padStart(4, "0")).join("")}`;
};

/**
 * Normalize an IPv4 or IPv6 address into a stable, canonical string. Returns
 * null for malformed, oversized, zoned, or port-bearing values.
 */
export const normalizeIp = (raw: string): string | null => {
  const value = raw.trim();
  if (value.length === 0 || value.length > 64) return null;
  if (/[\s\u0000-\u001f\u007f]/.test(value)) return null;
  if (value.includes("%")) return null;

  const withoutBrackets =
    value.startsWith("[") && value.endsWith("]") ? value.slice(1, -1) : value;

  return parseIpv4(withoutBrackets) ?? parseIpv6(withoutBrackets);
};

const selectHeaderValue = (
  headers: Headers,
  header: string,
  hops: number,
): string | null => {
  const raw = headers.get(header);
  if (raw === null) return null;

  if (header === "x-forwarded-for") {
    const values = raw
      .split(",")
      .map((value) => value.trim())
      .filter((value) => value.length > 0);

    if (values.length === 0 || hops < 1 || hops > values.length) return null;
    return values[values.length - hops] ?? null;
  }

  // A comma in a single-value header indicates duplicate/spoofed values.
  if (raw.includes(",")) return null;
  return raw.trim();
};

export const selectClientIp = (input: {
  headers: Headers;
  peerAddress: string | null;
  config: TrustedIpConfig;
}): ClientIdentity => {
  const peer =
    input.peerAddress === null ? null : normalizeIp(input.peerAddress);

  if (input.config.trustedHeader !== null) {
    const header = input.config.trustedHeader.toLowerCase();
    if (TRUSTED_HEADERS.has(header)) {
      const value = selectHeaderValue(
        input.headers,
        header,
        input.config.trustedProxyHops,
      );
      const normalized = value === null ? null : normalizeIp(value);
      if (normalized !== null) {
        return { ip: normalized, source: "header" };
      }
    }
  }

  if (peer !== null) {
    return { ip: peer, source: "peer" };
  }

  return { ip: null, source: "missing" };
};

export const ipBucketValue = (identity: ClientIdentity): string =>
  identity.ip ?? "unknown";

const keyCache = new Map<string, Promise<CryptoKey>>();

const importHmacKey = (secret: string): Promise<CryptoKey> => {
  const cached = keyCache.get(secret);
  if (cached !== undefined) return cached;

  const imported = crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  keyCache.set(secret, imported);
  return imported;
};

export const keyedHash = async (
  secret: string,
  value: string,
): Promise<string> => {
  const key = await importHmacKey(secret);
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(value),
  );

  return Array.from(new Uint8Array(signature))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
};
