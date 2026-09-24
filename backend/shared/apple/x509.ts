/**
 * BEFORE — X.509 certificate parsing and chain verification.
 *
 * Only what is needed to validate the certificate chain Apple attaches to a
 * signed transaction: parse the fields, check each link, check validity dates,
 * and pin the root.
 *
 * The root is NOT hard-coded here. Apple Root CA G3 is downloaded once and
 * supplied through configuration — inventing a certificate fingerprint from
 * memory is exactly the kind of fabricated fact this codebase refuses to
 * produce, and a wrong one would either break every purchase or, worse, trust
 * the wrong issuer. See docs/SETUP.md.
 */

import {
  DerError,
  TAG,
  base64ToBytes,
  bytesEqual,
  children,
  content,
  derEcdsaToRaw,
  expect,
  raw,
  readBitString,
  readOid,
  readTime,
} from './der.ts';

/** ecdsa-with-SHA256. The only algorithm Apple uses for these chains. */
export const OID_ECDSA_SHA256 = '1.2.840.10045.4.3.2';
/** id-ecPublicKey */
export const OID_EC_PUBLIC_KEY = '1.2.840.10045.2.1';
/** prime256v1 / P-256 */
export const OID_P256 = '1.2.840.10045.3.1.7';

export class CertificateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CertificateError';
  }
}

export interface ParsedCertificate {
  /** Raw TBSCertificate TLV — the bytes the signature covers. */
  tbs: Uint8Array;
  signatureAlgorithm: string;
  /** DER ECDSA-Sig-Value from the outer signature. */
  signature: Uint8Array;
  /** Raw Name TLVs, compared byte-for-byte to link the chain. */
  issuerDer: Uint8Array;
  subjectDer: Uint8Array;
  /** Raw SubjectPublicKeyInfo TLV, ready for WebCrypto importKey('spki'). */
  spki: Uint8Array;
  publicKeyAlgorithm: string;
  publicKeyCurve: string | null;
  notBefore: Date;
  notAfter: Date;
}

/**
 * Parse a DER certificate.
 *
 * Certificate ::= SEQUENCE {
 *   tbsCertificate       TBSCertificate,
 *   signatureAlgorithm   AlgorithmIdentifier,
 *   signatureValue       BIT STRING
 * }
 */
export function parseCertificate(der: Uint8Array): ParsedCertificate {
  let certificate;
  try {
    certificate = expect(der, 0, TAG.SEQUENCE, 'Certificate');
  } catch (error) {
    throw new CertificateError(
      error instanceof DerError ? error.message : 'certificate is not valid DER',
    );
  }

  const top = children(der, certificate);
  if (top.length !== 3) throw new CertificateError('Certificate must hold exactly three elements');

  const [tbsNode, algorithmNode, signatureNode] = top;
  if (tbsNode.tag !== TAG.SEQUENCE) throw new CertificateError('TBSCertificate is not a SEQUENCE');

  const signatureAlgorithm = readOid(der, children(der, algorithmNode)[0]);
  const signature = readBitString(der, signatureNode);

  // TBSCertificate ::= SEQUENCE {
  //   version [0] EXPLICIT Version DEFAULT v1,
  //   serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo, ...
  // }
  const fields = children(der, tbsNode);
  // A v1 certificate omits the version tag entirely, so the offset is not fixed.
  let index = fields.length > 0 && fields[0].tag === 0xa0 ? 1 : 0;

  index++; // serialNumber
  index++; // inner signature algorithm

  const issuerNode = fields[index++];
  const validityNode = fields[index++];
  const subjectNode = fields[index++];
  const spkiNode = fields[index++];

  if (!issuerNode || !validityNode || !subjectNode || !spkiNode) {
    throw new CertificateError('TBSCertificate is missing required fields');
  }

  const validity = children(der, validityNode);
  if (validity.length !== 2) throw new CertificateError('Validity must hold notBefore and notAfter');

  const spkiFields = children(der, spkiNode);
  const algorithmFields = children(der, spkiFields[0]);
  const publicKeyAlgorithm = readOid(der, algorithmFields[0]);
  const publicKeyCurve =
    algorithmFields.length > 1 && algorithmFields[1].tag === TAG.OID
      ? readOid(der, algorithmFields[1])
      : null;

  return {
    tbs: raw(der, tbsNode),
    signatureAlgorithm,
    signature,
    issuerDer: raw(der, issuerNode),
    subjectDer: raw(der, subjectNode),
    spki: raw(der, spkiNode),
    publicKeyAlgorithm,
    publicKeyCurve,
    notBefore: readTime(der, validity[0]),
    notAfter: readTime(der, validity[1]),
  };
}

export function parseCertificateBase64(base64: string): ParsedCertificate {
  return parseCertificate(base64ToBytes(base64));
}

// ---------------------------------------------------------------------------
// Verification
// ---------------------------------------------------------------------------

const ECDSA_P256: EcKeyImportParams = { name: 'ECDSA', namedCurve: 'P-256' };
const ECDSA_SHA256: EcdsaParams = { name: 'ECDSA', hash: 'SHA-256' };

export async function importPublicKey(spki: Uint8Array): Promise<CryptoKey> {
  try {
    return await crypto.subtle.importKey('spki', spki as BufferSource, ECDSA_P256, false, ['verify']);
  } catch {
    throw new CertificateError('public key is not a usable P-256 ECDSA key');
  }
}

/** Verify `signature` (DER ECDSA-Sig-Value) over `data` with `key`. */
export async function verifyDerSignature(
  key: CryptoKey,
  derSignature: Uint8Array,
  data: Uint8Array,
): Promise<boolean> {
  let rawSignature: Uint8Array;
  try {
    rawSignature = derEcdsaToRaw(derSignature);
  } catch {
    return false;
  }
  return crypto.subtle.verify(ECDSA_SHA256, key, rawSignature as BufferSource, data as BufferSource);
}

export interface ChainVerificationOptions {
  /** DER of Apple Root CA G3. Supplied by configuration, never hard-coded. */
  rootCertificate: Uint8Array;
  /** Injected so validity-window behaviour is testable. */
  now?: Date;
}

/**
 * Verify a certificate chain, leaf first.
 *
 * Checks, in order:
 *   1. every certificate uses ECDSA-SHA256 over a P-256 key;
 *   2. every certificate is inside its validity window;
 *   3. each certificate's issuer name matches its parent's subject name;
 *   4. each certificate's signature verifies under its parent's public key;
 *   5. the final certificate is the pinned root, byte for byte.
 *
 * Step 5 is the one that matters. Without it, anyone can present a
 * self-consistent chain of their own and every other check still passes.
 *
 * Returns the leaf's public key, ready to verify the JWS itself.
 */
export async function verifyCertificateChain(
  chain: ParsedCertificate[],
  options: ChainVerificationOptions,
): Promise<CryptoKey> {
  const now = options.now ?? new Date();

  if (chain.length < 2) {
    throw new CertificateError('certificate chain must contain at least a leaf and a root');
  }
  if (chain.length > 6) {
    throw new CertificateError('certificate chain is implausibly long');
  }

  for (const [index, certificate] of chain.entries()) {
    if (certificate.signatureAlgorithm !== OID_ECDSA_SHA256) {
      throw new CertificateError(
        `certificate ${index} is signed with ${certificate.signatureAlgorithm}, expected ECDSA-SHA256`,
      );
    }
    if (certificate.publicKeyAlgorithm !== OID_EC_PUBLIC_KEY || certificate.publicKeyCurve !== OID_P256) {
      throw new CertificateError(`certificate ${index} does not carry a P-256 key`);
    }
    if (now < certificate.notBefore) {
      throw new CertificateError(`certificate ${index} is not valid until ${certificate.notBefore.toISOString()}`);
    }
    if (now > certificate.notAfter) {
      throw new CertificateError(`certificate ${index} expired on ${certificate.notAfter.toISOString()}`);
    }
  }

  // The pinned root, compared by its full SubjectPublicKeyInfo and subject name.
  const expectedRoot = parseCertificate(options.rootCertificate);
  const presentedRoot = chain[chain.length - 1];

  if (!bytesEqual(presentedRoot.spki, expectedRoot.spki)) {
    throw new CertificateError('chain does not terminate at the pinned Apple root certificate');
  }
  if (!bytesEqual(presentedRoot.subjectDer, expectedRoot.subjectDer)) {
    throw new CertificateError('root certificate subject does not match the pinned root');
  }

  // Walk from the leaf upward.
  for (let index = 0; index < chain.length - 1; index++) {
    const child = chain[index];
    const parent = chain[index + 1];

    if (!bytesEqual(child.issuerDer, parent.subjectDer)) {
      throw new CertificateError(`certificate ${index} was not issued by certificate ${index + 1}`);
    }

    const parentKey = await importPublicKey(parent.spki);
    const valid = await verifyDerSignature(parentKey, child.signature, child.tbs);
    if (!valid) {
      throw new CertificateError(`certificate ${index} signature does not verify under its issuer`);
    }
  }

  return importPublicKey(chain[0].spki);
}
