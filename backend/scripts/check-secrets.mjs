#!/usr/bin/env node
/**
 * Fails if anything that looks like key material has found its way into the
 * repository — with particular attention to the iOS tree, which ships to
 * devices and cannot be rotated after the fact.
 *
 * Run: npm run check:secrets
 */

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '../..');

const SKIP_DIRS = new Set([
  'node_modules', '.git', 'DerivedData', '.build', 'build', '.swiftpm', 'coverage',
]);

const SCAN_EXTENSIONS = new Set([
  '.swift', '.ts', '.tsx', '.js', '.mjs', '.json', '.plist', '.sql', '.md',
  '.yml', '.yaml', '.sh', '.entitlements', '.xcconfig', '.storekit',
]);

/** Line-level patterns that are never acceptable anywhere in the repo. */
const FORBIDDEN = [
  { name: 'Anthropic API key', pattern: /sk-ant-[a-zA-Z0-9_-]{16,}/ },
  { name: 'OpenAI API key', pattern: /sk-proj-[a-zA-Z0-9_-]{16,}/ },
  { name: 'Google API key', pattern: /AIza[0-9A-Za-z_-]{30,}/ },
  { name: 'AWS access key id', pattern: /\bAKIA[0-9A-Z]{16}\b/ },
  // A Supabase service-role JWT always carries this role claim.
  { name: 'Supabase service-role JWT', pattern: /eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]*c2VydmljZV9yb2xl/ },
];

/**
 * A PEM private key, checked across the whole file rather than line by line.
 *
 * The body-length requirement is what makes this useful: the marker alone
 * appears in documentation, in `.env.example`, and in test fixtures that carry
 * no key material. A real P-256 key is ~200 base64 characters and an RSA key is
 * far more, so requiring 120 keeps every genuine key and drops the noise.
 *
 * Matching the bare marker instead would train people to ignore this script,
 * which is worse than not running it.
 */
const PEM_KEY = {
  name: 'private key block',
  pattern: /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----[\r\n]+([A-Za-z0-9+/=\s]{120,})-----END/,
};

/** Additionally forbidden inside ios/ — the app must never know these exist. */
const IOS_FORBIDDEN = [
  { name: 'service-role key reference', pattern: /SUPABASE_SERVICE_ROLE_KEY|service_role/ },
  { name: 'AI provider key reference', pattern: /ANTHROPIC_API_KEY|OPENAI_API_KEY|GEMINI_API_KEY/ },
  { name: 'App Store private key', pattern: /APPLE_PRIVATE_KEY/ },
];

/** `.env.example` is a template of empty placeholders and is meant to exist. */
const ALLOWED_FILES = new Set(['.env.example', 'check-secrets.mjs']);

const findings = [];

function walk(dir) {
  for (const entry of readdirSync(dir)) {
    if (SKIP_DIRS.has(entry)) continue;
    const full = join(dir, entry);
    const stats = statSync(full);
    if (stats.isDirectory()) {
      walk(full);
      continue;
    }
    if (stats.size > 2 * 1024 * 1024) continue;

    const extension = entry.slice(entry.lastIndexOf('.'));
    if (!SCAN_EXTENSIONS.has(extension) && entry !== '.env.example') continue;
    if (ALLOWED_FILES.has(entry)) continue;

    scan(full);
  }
}

function scan(file) {
  const relativePath = relative(root, file).split(sep).join('/');
  let content;
  try {
    content = readFileSync(file, 'utf8');
  } catch {
    return;
  }

  const rules = relativePath.startsWith('ios/') ? [...FORBIDDEN, ...IOS_FORBIDDEN] : FORBIDDEN;

  content.split('\n').forEach((line, index) => {
    for (const rule of rules) {
      if (rule.pattern.test(line)) {
        findings.push({ file: relativePath, line: index + 1, rule: rule.name });
      }
    }
  });

  // PEM blocks span lines, so they are matched against the whole file.
  const pemMatch = content.match(PEM_KEY.pattern);
  if (pemMatch) {
    const line = content.slice(0, pemMatch.index).split('\n').length;
    findings.push({ file: relativePath, line, rule: PEM_KEY.name });
  }
}

walk(root);

if (findings.length > 0) {
  console.error(`\nFAIL: ${findings.length} potential secret${findings.length === 1 ? '' : 's'} found\n`);
  for (const finding of findings) {
    console.error(`  ${finding.file}:${finding.line}  ${finding.rule}`);
  }
  console.error('\nNothing server-side may ship inside the iOS bundle.');
  console.error('The app is allowed to know SUPABASE_URL and SUPABASE_ANON_KEY, and nothing else.\n');
  process.exit(1);
}

console.log('OK: no key material found in the repository.');
