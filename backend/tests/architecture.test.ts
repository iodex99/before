/**
 * Architectural rules, enforced.
 *
 * Each of these is written down in .claude/rules/backend-api.md. A rule nobody
 * checks is a suggestion, and this is the class of thing that decays silently:
 * one `Deno.env` in shared code and the Node test suite stops running at all.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const backendRoot = join(here, '..');

function tsFiles(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) tsFiles(full, out);
    else if (entry.endsWith('.ts')) out.push(full);
  }
  return out;
}

const shared = tsFiles(join(backendRoot, 'shared')).map((path) => ({
  path: relative(backendRoot, path).split('\\').join('/'),
  body: readFileSync(path, 'utf8'),
}));

const functions = tsFiles(join(backendRoot, 'supabase/functions')).map((path) => ({
  path: relative(backendRoot, path).split('\\').join('/'),
  body: readFileSync(path, 'utf8'),
}));

const stripComments = (body: string) =>
  body
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split('\n')
    .map((line) => line.replace(/\/\/.*$/, ''))
    .join('\n');

test('shared code was found', () => {
  assert.ok(shared.length > 10, `expected the shared tree, found ${shared.length} files`);
  assert.ok(functions.length > 5, `expected the functions tree, found ${functions.length} files`);
});

// ---------------------------------------------------------------------------
// Runtime neutrality — this is what makes `npm run test:backend` work at all
// ---------------------------------------------------------------------------

test('shared code uses no runtime-specific globals', () => {
  const offenders: string[] = [];
  for (const file of shared) {
    stripComments(file.body).split('\n').forEach((line, index) => {
      if (/\bDeno\./.test(line)) offenders.push(`${file.path}:${index + 1} Deno.*`);
      if (/\bprocess\.(env|argv|cwd)/.test(line)) offenders.push(`${file.path}:${index + 1} process.*`);
      if (/from ['"]node:/.test(line)) offenders.push(`${file.path}:${index + 1} node: import`);
    });
  }
  assert.deepEqual(offenders, [], 'shared code must load on both Deno and Node');
});

test('relative imports in shared code carry the .ts extension', () => {
  const offenders: string[] = [];
  for (const file of [...shared, ...functions]) {
    for (const match of stripComments(file.body).matchAll(/from\s+['"](\.[^'"]+)['"]/g)) {
      const specifier = match[1];
      if (!specifier.endsWith('.ts') && !specifier.endsWith('.json')) {
        offenders.push(`${file.path}: ${specifier}`);
      }
    }
  }
  assert.deepEqual(offenders, [], 'Deno requires explicit extensions; so does Node type stripping');
});

test('shared code reads no secret at module scope', () => {
  // Secrets are passed in as arguments from the edge of a function, so shared
  // code can be imported by a test without an environment.
  for (const file of shared) {
    assert.ok(
      !/^(?:const|let)\s+\w+\s*=\s*.*(?:API_KEY|SERVICE_ROLE|SECRET)/m.test(stripComments(file.body)),
      `${file.path} reads a secret at module scope`,
    );
  }
});

// ---------------------------------------------------------------------------
// API surface
// ---------------------------------------------------------------------------

test('every endpoint is versioned under /v1', () => {
  const endpoints = functions.flatMap((file) =>
    [...file.body.matchAll(/endpoint:\s*'([^']+)'/g)].map((m) => ({ path: file.path, endpoint: m[1] })),
  );

  assert.ok(endpoints.length >= 6, `expected several endpoints, found ${endpoints.length}`);
  for (const { path, endpoint } of endpoints) {
    assert.ok(endpoint.startsWith('/v1/'), `${path}: "${endpoint}" is not under /v1`);
  }
});

test('every edge function serves a handler through a context wrapper', () => {
  const entryPoints = functions.filter((f) => f.path.endsWith('/index.ts'));
  assert.ok(entryPoints.length >= 7, `expected several functions, found ${entryPoints.length}`);

  for (const file of entryPoints) {
    assert.match(
      file.body,
      /Deno\.serve\(\s*with(Public)?Context\(/,
      `${file.path} does not serve a handler`,
    );
  }
});

test('exactly one endpoint is unauthenticated, and it is the one Apple calls', () => {
  // withPublicContext has no session and runs everything with the service role.
  // If it ever appears on a second endpoint, that is a decision someone must
  // make deliberately rather than discover later.
  const publicEndpoints = functions
    .filter((f) => f.path.endsWith('/index.ts') && /withPublicContext\(/.test(f.body))
    .map((f) => f.path);

  assert.deepEqual(
    publicEndpoints,
    ['supabase/functions/app-store-notifications/index.ts'],
    'an endpoint became unauthenticated',
  );
});

test('the unauthenticated endpoint verifies a signature before doing anything', () => {
  const notifications = functions.find((f) => f.path.includes('app-store-notifications'));
  assert.ok(notifications);

  // The signature is the only authentication this endpoint has.
  assert.match(notifications.body, /verifyAppleSignedPayload/);
  assert.match(notifications.body, /rootCertificate/);

  const verifyIndex = notifications.body.indexOf('verifyAppleSignedPayload');
  const writeIndex = notifications.body.indexOf(".from('subscriptions')");
  assert.ok(
    verifyIndex > 0 && writeIndex > verifyIndex,
    'verification must happen before anything is written',
  );
});

// ---------------------------------------------------------------------------
// The rules that protect the product
// ---------------------------------------------------------------------------

test('the score is computed by the engine, in exactly one place', () => {
  const callers = functions.filter((f) => /PurchaseScoreEngine\.score\(/.test(f.body));
  assert.equal(
    callers.length,
    1,
    `the engine should be called from one place, found: ${callers.map((c) => c.path).join(', ')}`,
  );
  assert.ok(callers[0].path.includes('analyze-purchase'));
});

test('no function writes a score the model supplied', () => {
  for (const file of functions) {
    // The validated analysis carries signals and a confidence; it deliberately
    // has no score field. This catches an attempt to invent one.
    assert.ok(
      !/validated\.score|validated\.verdict/.test(file.body),
      `${file.path} reads a score or verdict from model output`,
    );
  }
});

test('the model suggestion never reaches the persisted verdict', () => {
  const analyze = functions.find((f) => f.path.includes('analyze-purchase'));
  assert.ok(analyze);
  assert.ok(
    !/verdict:\s*validated\.modelSuggestedAction|suggested_action:\s*validated\./.test(analyze.body),
    'modelSuggestedAction is advisory only and must not be persisted as the verdict',
  );
  assert.match(
    analyze.body,
    /verdict:\s*scored\.verdict/,
    'the persisted verdict must come from the score engine',
  );
});

test('logging goes through the allow-listed logger, not console', () => {
  const offenders: string[] = [];
  for (const file of functions) {
    if (file.path.endsWith('_shared/log.ts')) continue;
    stripComments(file.body).split('\n').forEach((line, index) => {
      if (/console\.(log|info|warn|error)\(/.test(line)) {
        offenders.push(`${file.path}:${index + 1}`);
      }
    });
  }
  assert.deepEqual(offenders, [], 'use ctx.log — console bypasses the field allow-list');
});

test('the analysis endpoint honours an idempotency key', () => {
  const analyze = functions.find((f) => f.path.includes('analyze-purchase'));
  assert.ok(analyze);
  assert.match(analyze.body, /idempotency-key/i);
  assert.match(analyze.body, /resolveIdempotent/);
});

test('the deeper-explanation endpoint is Plus-gated and cannot take free text', () => {
  const explain = functions.find((f) => f.path.includes('explain'));
  assert.ok(explain);

  assert.match(explain.body, /isPlus\(/, 'deeper explanations are a Plus feature (§35)');
  assert.match(explain.body, /forbidden/, 'a free user must get a clear refusal, not a silent one');

  // Rule 1 / §8: BEFORE is not a chatbot. The angle comes from a closed set,
  // and the body must never carry a user-supplied question.
  assert.match(explain.body, /ANGLES/);
  assert.ok(
    !/body\.question|body\.prompt|body\.message|freeText/i.test(explain.body),
    'the explain endpoint must not accept a free-text question',
  );

  // A follow-up is not a loophole around the safety scan.
  assert.match(explain.body, /scanStrings|scanText/);
});

test('the explanation prompt is given no new material to invent from', () => {
  const explain = functions.find((f) => f.path.includes('explain'));
  assert.ok(explain);

  // No image, no metadata fetch, no wardrobe — only the analysis BEFORE already
  // produced, so there is nothing to fabricate a new fact from (Rule 5).
  for (const forbidden of ['loadImageForModel', 'fetchProductMetadata', 'loadWardrobe']) {
    assert.ok(!explain.body.includes(forbidden), `explain must not use ${forbidden}`);
  }
});

test('the wardrobe endpoint enforces the free cap server-side', () => {
  const wardrobe = functions.find((f) => f.path.includes('wardrobe'));
  assert.ok(wardrobe);

  assert.match(wardrobe.body, /freeWardrobeItems/);
  assert.match(wardrobe.body, /quota_exceeded/, 'hitting the cap is an offer, not an error');

  // Reads and writes go through the caller-scoped client so RLS does the work.
  assert.ok(
    !/ctx\.admin\s*\n?\s*\.from\('wardrobe_items'\)/.test(wardrobe.body),
    'wardrobe rows must be reached through the user-scoped client, not the service role',
  );
});

test('deleting a wardrobe item removes its image before the row', () => {
  const wardrobe = functions.find((f) => f.path.includes('wardrobe'));
  assert.ok(wardrobe);

  const storageIndex = wardrobe.body.indexOf("storage.from('wardrobe')");
  const deleteIndex = wardrobe.body.indexOf(".delete()");
  assert.ok(
    storageIndex > 0 && deleteIndex > storageIndex,
    'a row cascade cannot reach storage, so the object must go first',
  );
});

test('the export endpoint relies on RLS rather than its own filtering', () => {
  const exportFn = functions.find((f) => f.path.includes('account-export'));
  assert.ok(exportFn);

  assert.match(exportFn.body, /rpc\('export_user_data'\)/);
  // export_user_data() is security invoker. A second `where user_id =` here
  // would be another place to get it wrong.
  assert.ok(
    !/\.eq\('user_id'/.test(exportFn.body),
    'the export must not re-implement the filtering the database already does',
  );
  assert.match(exportFn.body, /createSignedUrl/, 'images are linked, never inlined');
});

test('every Apple-signed payload is verified before it is trusted', () => {
  for (const name of ['subscription-sync', 'app-store-notifications']) {
    const file = functions.find((f) => f.path.includes(name));
    assert.ok(file, `${name} not found`);

    assert.match(file.body, /verifyTransaction|verifyAppleSignedPayload/, `${name} does not verify`);
    assert.match(file.body, /rootCertificate/, `${name} does not pin the root`);

    // A sandbox transaction must never grant production entitlement.
    assert.match(file.body, /allowSandbox|sandbox/i, `${name} does not separate sandbox`);
  }
});

test('subscription-sync stores only verified values, never what the client claimed', () => {
  const sync = functions.find((f) => f.path.includes('subscription-sync'));
  assert.ok(sync);

  // The stored row is built from `transaction` (verified) and `snapshot`
  // (fetched from Apple) — never from the request body.
  const upsertStart = sync.body.indexOf("from('subscriptions').upsert");
  const upsertEnd = sync.body.indexOf('{ onConflict', upsertStart);
  const upsertBlock = sync.body.slice(upsertStart, upsertEnd);

  assert.ok(upsertStart > 0 && upsertEnd > upsertStart, 'could not locate the upsert');
  assert.ok(
    !/body\./.test(upsertBlock),
    `the subscription row must not carry client-supplied values: ${upsertBlock.match(/body\.\w+/g)?.join(', ')}`,
  );
});

test('quota is consumed only after a successful analysis', () => {
  const analyze = functions.find((f) => f.path.includes('analyze-purchase'));
  assert.ok(analyze);

  const ledgerIndex = analyze.body.indexOf("from('usage_ledger')");
  const completedIndex = analyze.body.indexOf("status: 'completed'");
  assert.ok(ledgerIndex > 0 && completedIndex > 0);
  assert.ok(
    completedIndex < ledgerIndex,
    'the ledger row must be written after the analysis is marked completed — a failure must cost nothing',
  );
});
