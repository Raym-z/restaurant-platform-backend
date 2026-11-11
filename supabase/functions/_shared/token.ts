const base64Url = (bytes: Uint8Array): string => {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
};

/**
 * Generate a 32-byte CSPRNG opaque token. The raw value is returned once to the
 * intended holder; only its SHA-256 hash is stored server-side.
 */
export const generateOpaqueToken = (): string => {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return base64Url(bytes);
};

/**
 * Generate a 32-byte CSPRNG guest token. The raw value is returned once to the
 * device; only its SHA-256 hash is stored server-side.
 */
export const generateGuestToken = (): string => generateOpaqueToken();

export const generateInvitationToken = (): string => generateOpaqueToken();

export const sha256Hex = async (value: string): Promise<string> => {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );

  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
};
