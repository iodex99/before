#!/usr/bin/env node
/**
 * Generates a REAL ECDSA P-256 certificate chain and signed JWS payloads for
 * the Apple verification tests.
 *
 * Why generate rather than hand-write fixtures: the point of the verifier is
 * that it rejects a chain that does not terminate at the pinned root. Testing
 * that honestly needs two independent, internally-consistent chains — one
 * trusted, one not — and those have to be genuinely signed or the test proves
 * nothing.
 *
 * Output is committed, so the test suite needs no OpenSSL. Re-run only when the
 * fixture shape changes:
 *
 *   node backend/scripts/make-apple-test-fixtures.mjs
 *
 * Requires: openssl (3.x) on PATH.
 */

import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createSign, createPrivateKey } from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const outputPath = join(here, '../shared/fixtures/apple-chain.json');

const workDir = mkdtempSync(join(tmpdir(), 'before-certs-'));
const openssl = (...args) => execFileSync('openssl', args, { cwd: workDir, stdio: ['ignore', 'pipe', 'pipe'] });

const DAYS = '7300'; // 20 years — comfortably inside UTCTime's 2049 boundary

/** A three-certificate chain: leaf <- intermediate <- self-signed root. */
function buildChain(prefix, { leafSubject }) {
  const file = (name) => `${prefix}-${name}`;

  // Root: self-signed CA.
  openssl('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', file('root.key'));
  openssl(
    'req', '-new', '-x509', '-key', file('root.key'), '-sha256', '-days', DAYS,
    '-subj', `/CN=${prefix} Test Root CA/O=BEFORE Tests`,
    '-addext', 'basicConstraints=critical,CA:TRUE',
    '-out', file('root.pem'),
  );

  // Intermediate, signed by the root.
  openssl('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', file('int.key'));
  openssl('req', '-new', '-key', file('int.key'), '-sha256',
    '-subj', `/CN=${prefix} Test Intermediate/O=BEFORE Tests`, '-out', file('int.csr'));
  writeFileSync(join(workDir, file('int.ext')), 'basicConstraints=critical,CA:TRUE,pathlen:0\n');
  openssl(
    'x509', '-req', '-in', file('int.csr'), '-CA', file('root.pem'), '-CAkey', file('root.key'),
    '-CAcreateserial', '-sha256', '-days', DAYS,
    '-extfile', file('int.ext'), '-out', file('int.pem'),
  );

  // Leaf, signed by the intermediate.
  openssl('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', file('leaf.key'));
  openssl('req', '-new', '-key', file('leaf.key'), '-sha256',
    '-subj', leafSubject, '-out', file('leaf.csr'));
  writeFileSync(join(workDir, file('leaf.ext')), 'basicConstraints=critical,CA:FALSE\n');
  openssl(
    'x509', '-req', '-in', file('leaf.csr'), '-CA', file('int.pem'), '-CAkey', file('int.key'),
    '-CAcreateserial', '-sha256', '-days', DAYS,
    '-extfile', file('leaf.ext'), '-out', file('leaf.pem'),
  );

  const pem = (name) => readFileSync(join(workDir, file(name)), 'utf8');
  const derBase64 = (name) =>
    pem(name)
      .replace(/-----BEGIN CERTIFICATE-----/g, '')
      .replace(/-----END CERTIFICATE-----/g, '')
      .replace(/\s+/g, '');

  // openssl writes SEC1 EC keys; convert to PKCS#8 so node can load them plainly.
  openssl('pkcs8', '-topk8', '-nocrypt', '-in', file('leaf.key'), '-out', file('leaf.pk8.pem'));

  return {
    leafDer: derBase64('leaf.pem'),
    intermediateDer: derBase64('int.pem'),
    rootDer: derBase64('root.pem'),
    rootPem: pem('root.pem'),
    leafPrivateKeyPem: pem('leaf.pk8.pem'),
  };
}

const base64Url = (buffer) =>
  Buffer.from(buffer).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/** Sign a compact ES256 JWS. JOSE uses raw r||s, not the DER form. */
function signJws(payload, chain, { corruptSignature = false, algorithm = 'ES256' } = {}) {
  const header = {
    alg: algorithm,
    x5c: [chain.leafDer, chain.intermediateDer, chain.rootDer],
  };

  const protectedSegment = base64Url(Buffer.from(JSON.stringify(header)));
  const payloadSegment = base64Url(Buffer.from(JSON.stringify(payload)));

  const signer = createSign('SHA256');
  signer.update(`${protectedSegment}.${payloadSegment}`);
  signer.end();

  const signature = signer.sign({
    key: createPrivateKey(chain.leafPrivateKeyPem),
    dsaEncoding: 'ieee-p1363', // raw r||s, which is what JOSE requires
  });

  if (corruptSignature) signature[0] ^= 0xff;

  return `${protectedSegment}.${payloadSegment}.${base64Url(signature)}`;
}

// ---------------------------------------------------------------------------

try {
  const trusted = buildChain('apple', { leafSubject: '/CN=Prod ECC Mac App Store and iTunes Store Receipt Signing/O=BEFORE Tests' });
  // A completely separate, internally valid chain. Every check except the root
  // pin passes for this one — which is precisely what makes it the test that
  // matters.
  const rogue = buildChain('rogue', { leafSubject: '/CN=Definitely Apple, Honestly/O=Not Apple' });

  const transaction = {
    transactionId: '2000000500000001',
    originalTransactionId: '2000000400000001',
    bundleId: 'com.yourcompany.before',
    productId: 'before.plus.yearly',
    purchaseDate: 1790000000000,
    originalPurchaseDate: 1790000000000,
    expiresDate: 1821536000000,
    type: 'Auto-Renewable Subscription',
    inAppOwnershipType: 'PURCHASED',
    environment: 'Production',
    appAccountToken: '2b0b8c5e-9b8a-4c6f-9d1e-7a3f5c2d1e4b',
  };

  const sandboxTransaction = { ...transaction, environment: 'Sandbox', transactionId: '2000000500000002' };
  const foreignTransaction = { ...transaction, bundleId: 'com.someoneelse.app', transactionId: '2000000500000003' };

  const notification = {
    notificationType: 'DID_RENEW',
    notificationUUID: 'd1b0f6c2-7a3e-4f5b-9c8d-1e2f3a4b5c6d',
    version: '2.0',
    signedDate: 1790000100000,
    data: {
      bundleId: 'com.yourcompany.before',
      environment: 'Production',
      status: 1,
      signedTransactionInfo: signJws(transaction, trusted),
    },
  };

  const fixtures = {
    $comment: [
      'Generated by backend/scripts/make-apple-test-fixtures.mjs using a real',
      'OpenSSL ECDSA P-256 chain. Not Apple certificates — a stand-in with the',
      'same shape, so the verifier can be tested without Apple in the loop.',
      'validAt is inside every certificate validity window.',
    ],
    validAt: new Date().toISOString(),
    trustedRootDer: trusted.rootDer,
    rogueRootDer: rogue.rootDer,
    chain: {
      leafDer: trusted.leafDer,
      intermediateDer: trusted.intermediateDer,
      rootDer: trusted.rootDer,
    },
    tokens: {
      transaction: signJws(transaction, trusted),
      sandboxTransaction: signJws(sandboxTransaction, trusted),
      foreignBundleTransaction: signJws(foreignTransaction, trusted),
      notification: signJws(notification, trusted),
      // Same payload, signed by a chain rooted somewhere else entirely.
      rogueChain: signJws(transaction, rogue),
      // Valid chain, tampered signature.
      corruptSignature: signJws(transaction, trusted, { corruptSignature: true }),
      // Valid chain and signature, but an algorithm we must refuse.
      wrongAlgorithm: signJws(transaction, trusted, { algorithm: 'HS256' }),
    },
    payloads: { transaction, sandboxTransaction, foreignTransaction, notification },
  };

  mkdirSync(dirname(outputPath), { recursive: true });
  writeFileSync(outputPath, `${JSON.stringify(fixtures, null, 2)}\n`);

  console.log(`Wrote ${outputPath}`);
  console.log(`  trusted chain: leaf + intermediate + root`);
  console.log(`  rogue chain:   independent root, for the pinning test`);
  console.log(`  tokens:        ${Object.keys(fixtures.tokens).length}`);
} finally {
  rmSync(workDir, { recursive: true, force: true });
}
