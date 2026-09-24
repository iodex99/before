/**
 * BEFORE — minimal DER / ASN.1 reader.
 *
 * Enough to parse an X.509 certificate and nothing more. Written by hand rather
 * than pulled from a package because this code runs in an edge function on two
 * runtimes, and a certificate parser is a small, well-specified thing that is
 * better read than trusted.
 *
 * DER, not BER: indefinite lengths are rejected rather than tolerated. A
 * certificate that is not valid DER is not a certificate we should accept.
 */

export class DerError extends Error {
  constructor(message: string) {
    super(`DER: ${message}`);
    this.name = 'DerError';
  }
}

export const TAG = {
  INTEGER: 0x02,
  BIT_STRING: 0x03,
  OCTET_STRING: 0x04,
  NULL: 0x05,
  OID: 0x06,
  UTF8_STRING: 0x0c,
  SEQUENCE: 0x30,
  SET: 0x31,
  UTC_TIME: 0x17,
  GENERALIZED_TIME: 0x18,
} as const;

export interface DerNode {
  tag: number;
  /** Offset of the tag byte. */
  start: number;
  /** Offset one past the final content byte. */
  end: number;
  /** Offset of the first content byte. */
  contentStart: number;
  contentEnd: number;
}

/** Read one TLV starting at `offset`. */
export function readNode(buffer: Uint8Array, offset: number): DerNode {
  if (offset >= buffer.length) throw new DerError('unexpected end of input');

  const start = offset;
  let tag = buffer[offset++];

  // High-tag-number form: subsequent bytes carry the tag, terminated by a byte
  // with the top bit clear.
  if ((tag & 0x1f) === 0x1f) {
    let value = 0;
    for (;;) {
      if (offset >= buffer.length) throw new DerError('truncated high-form tag');
      const byte = buffer[offset++];
      value = (value << 7) | (byte & 0x7f);
      if ((byte & 0x80) === 0) break;
      if (value > 0xffffff) throw new DerError('tag too large');
    }
    tag = value;
  }

  if (offset >= buffer.length) throw new DerError('missing length');
  const first = buffer[offset++];

  let length: number;
  if (first < 0x80) {
    length = first;
  } else {
    const count = first & 0x7f;
    // 0x80 is BER indefinite length, which DER forbids.
    if (count === 0) throw new DerError('indefinite length is not valid DER');
    if (count > 4) throw new DerError('length field too large');
    if (offset + count > buffer.length) throw new DerError('truncated length');

    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + buffer[offset++];
  }

  const contentStart = offset;
  const contentEnd = contentStart + length;
  if (contentEnd > buffer.length) throw new DerError('content runs past end of input');

  return { tag, start, end: contentEnd, contentStart, contentEnd };
}

/** Read one TLV and require it to have the given tag. */
export function expect(buffer: Uint8Array, offset: number, tag: number, what: string): DerNode {
  const node = readNode(buffer, offset);
  if (node.tag !== tag) {
    throw new DerError(`expected ${what} (tag 0x${tag.toString(16)}), got 0x${node.tag.toString(16)}`);
  }
  return node;
}

/** The direct children of a constructed node. */
export function children(buffer: Uint8Array, node: DerNode): DerNode[] {
  const result: DerNode[] = [];
  let offset = node.contentStart;
  while (offset < node.contentEnd) {
    const child = readNode(buffer, offset);
    result.push(child);
    if (child.end <= offset) throw new DerError('zero-length element; refusing to loop');
    offset = child.end;
  }
  return result;
}

/** The whole TLV, tag and length included. Needed for signature verification. */
export function raw(buffer: Uint8Array, node: DerNode): Uint8Array {
  return buffer.subarray(node.start, node.end);
}

export function content(buffer: Uint8Array, node: DerNode): Uint8Array {
  return buffer.subarray(node.contentStart, node.contentEnd);
}

/** Decode an OID to dotted-decimal form. */
export function readOid(buffer: Uint8Array, node: DerNode): string {
  if (node.tag !== TAG.OID) throw new DerError('not an OID');
  const bytes = content(buffer, node);
  if (bytes.length === 0) throw new DerError('empty OID');

  // The first byte packs the first two arcs as 40*a + b.
  const parts: number[] = [Math.floor(bytes[0] / 40), bytes[0] % 40];

  let value = 0;
  for (let i = 1; i < bytes.length; i++) {
    value = value * 128 + (bytes[i] & 0x7f);
    if ((bytes[i] & 0x80) === 0) {
      parts.push(value);
      value = 0;
    }
  }
  return parts.join('.');
}

/**
 * A BIT STRING's payload, minus the leading "unused bits" byte.
 * Certificates only ever use whole bytes here.
 */
export function readBitString(buffer: Uint8Array, node: DerNode): Uint8Array {
  if (node.tag !== TAG.BIT_STRING) throw new DerError('not a BIT STRING');
  const bytes = content(buffer, node);
  if (bytes.length === 0) throw new DerError('empty BIT STRING');
  if (bytes[0] !== 0) throw new DerError('unused bits in BIT STRING are not supported');
  return bytes.subarray(1);
}

/** UTCTime or GeneralizedTime. */
export function readTime(buffer: Uint8Array, node: DerNode): Date {
  const text = new TextDecoder().decode(content(buffer, node));

  let year: number;
  let rest: string;

  if (node.tag === TAG.UTC_TIME) {
    // RFC 5280: two-digit years 50..99 are 19xx, 00..49 are 20xx.
    const twoDigit = Number(text.slice(0, 2));
    if (Number.isNaN(twoDigit)) throw new DerError(`bad UTCTime: ${text}`);
    year = twoDigit >= 50 ? 1900 + twoDigit : 2000 + twoDigit;
    rest = text.slice(2);
  } else if (node.tag === TAG.GENERALIZED_TIME) {
    year = Number(text.slice(0, 4));
    rest = text.slice(4);
  } else {
    throw new DerError(`not a time (tag 0x${node.tag.toString(16)})`);
  }

  const match = rest.match(/^(\d{2})(\d{2})(\d{2})(\d{2})?(\d{2})?Z$/);
  if (!match || Number.isNaN(year)) throw new DerError(`unsupported time format: ${text}`);

  const [, month, day, hour, minute = '00', second = '00'] = match;
  return new Date(
    Date.UTC(year, Number(month) - 1, Number(day), Number(hour), Number(minute), Number(second)),
  );
}

/** Constant-time-ish byte comparison. Length is not secret here. */
export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

// ---------------------------------------------------------------------------
// base64 / base64url
// ---------------------------------------------------------------------------

export function base64ToBytes(input: string): Uint8Array {
  const normalised = input.replace(/\s+/g, '');
  const binary = atob(normalised);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function base64UrlToBytes(input: string): Uint8Array {
  const padded = input.replace(/-/g, '+').replace(/_/g, '/');
  return base64ToBytes(padded + '='.repeat((4 - (padded.length % 4)) % 4));
}

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

export function bytesToBase64Url(bytes: Uint8Array): string {
  return bytesToBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Strip PEM armour and decode. */
export function pemToBytes(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, '')
    .replace(/-----END [^-]+-----/g, '')
    .replace(/\s+/g, '');
  if (!body) throw new DerError('empty PEM body');
  return base64ToBytes(body);
}

// ---------------------------------------------------------------------------
// ECDSA signature encoding
// ---------------------------------------------------------------------------

/**
 * X.509 carries an ECDSA signature as DER `SEQUENCE { r INTEGER, s INTEGER }`.
 * WebCrypto wants the raw P1363 form, `r || s`, fixed width and unsigned.
 *
 * The conversion is where a naive implementation goes wrong: DER INTEGERs are
 * signed, so a value whose top bit is set carries a leading 0x00 that must be
 * dropped, and a short value must be left-padded to the curve size.
 */
export function derEcdsaToRaw(derSignature: Uint8Array, fieldSize = 32): Uint8Array {
  const sequence = expect(derSignature, 0, TAG.SEQUENCE, 'ECDSA-Sig-Value');
  const parts = children(derSignature, sequence);
  if (parts.length !== 2) throw new DerError('ECDSA signature must hold exactly r and s');

  const raw = new Uint8Array(fieldSize * 2);
  parts.forEach((part, index) => {
    if (part.tag !== TAG.INTEGER) throw new DerError('ECDSA component is not an INTEGER');

    let value = content(derSignature, part);
    // Drop the sign byte DER adds when the high bit is set.
    while (value.length > 1 && value[0] === 0x00) value = value.subarray(1);
    if (value.length > fieldSize) throw new DerError('ECDSA component larger than the field');

    raw.set(value, index * fieldSize + (fieldSize - value.length));
  });

  return raw;
}
