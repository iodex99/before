/**
 * Static checks over the Swift source.
 *
 * These do not replace a compiler. They catch the specific things a compiler
 * would catch that are worth catching on a machine without one — a mistyped
 * theme token, an accessibility identifier a UI test looks for that no longer
 * exists, an analytics event that was never declared — plus the project rules
 * in .claude/rules/ios.md, which a compiler would never catch at all.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const iosRoot = join(here, '../../ios');

function swiftFiles(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir)) {
    if (entry === '.build' || entry === 'DerivedData' || entry.endsWith('.xcodeproj')) continue;
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) swiftFiles(full, out);
    else if (entry.endsWith('.swift')) out.push(full);
  }
  return out;
}

const allFiles = swiftFiles(iosRoot);
const sources = allFiles.map((path) => ({
  path: relative(iosRoot, path).split('\\').join('/'),
  body: readFileSync(path, 'utf8'),
}));

const appSources = sources.filter(
  (f) => !f.path.startsWith('BEFORETests/') && !f.path.startsWith('BEFOREUITests/') && !f.path.includes('/Tests/'),
);
const featureSources = sources.filter((f) => f.path.startsWith('BEFORE/Features/'));

/** Source with line comments and block comments removed. */
function stripComments(body: string): string {
  return body
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split('\n')
    .map((line) => line.replace(/\/\/.*$/, ''))
    .join('\n');
}

test('the Swift tree was found', () => {
  assert.ok(sources.length > 20, `expected a full Swift tree, found ${sources.length} files`);
});

// ---------------------------------------------------------------------------
// Theme tokens — a typo here is a compile error on a Mac and invisible here
// ---------------------------------------------------------------------------

test('every BeforeTheme token referenced in the app is actually defined', () => {
  const theme = stripComments(
    readFileSync(join(iosRoot, 'BEFORE/Theme/BeforeTheme.swift'), 'utf8'),
  );

  /**
   * Nested namespaces (Spacing, Radius, …) and their members, parsed by walking
   * braces. The distinction matters: in `BeforeTheme.Spacing.gutter` the third
   * segment is a token to verify, but in `BeforeTheme.background.opacity(0.5)`
   * it is a SwiftUI method on the returned Color and none of our business.
   */
  const namespaces = new Map<string, Set<string>>();
  for (const match of theme.matchAll(/(?:public )?enum\s+(\w+)\s*\{/g)) {
    const name = match[1];
    if (name === 'BeforeTheme') continue;

    let depth = 1;
    let index = match.index + match[0].length;
    while (index < theme.length && depth > 0) {
      if (theme[index] === '{') depth++;
      else if (theme[index] === '}') depth--;
      index++;
    }
    const body = theme.slice(match.index + match[0].length, index - 1);
    namespaces.set(
      name,
      new Set([...body.matchAll(/static (?:let|var|func)\s+(\w+)/g)].map((m) => m[1])),
    );
  }

  const topLevel = new Set<string>([
    ...[...theme.matchAll(/static (?:let|var|func)\s+(\w+)/g)].map((m) => m[1]),
    ...namespaces.keys(),
  ]);

  const missing = new Set<string>();
  for (const file of appSources) {
    if (file.path.endsWith('BeforeTheme.swift')) continue;
    for (const match of stripComments(file.body).matchAll(/BeforeTheme\.(\w+)(?:\.(\w+))?/g)) {
      const [, first, second] = match;
      if (!topLevel.has(first)) {
        missing.add(`${file.path}: BeforeTheme.${first}`);
        continue;
      }
      const members = namespaces.get(first);
      if (members && second && !members.has(second)) {
        missing.add(`${file.path}: BeforeTheme.${first}.${second}`);
      }
    }
  }

  assert.deepEqual([...missing], [], 'undefined theme tokens');
  assert.ok(namespaces.size >= 4, `expected several theme namespaces, found ${namespaces.size}`);
});

test('feature code styles through the theme, never literals', () => {
  const offenders: string[] = [];

  for (const file of featureSources) {
    // The share card is rendered at a fixed export size, so its point values are
    // intentional and independent of Dynamic Type.
    if (file.path.includes('Share/ShareCard.swift')) continue;

    stripComments(file.body).split('\n').forEach((line, index) => {
      if (/Color\(red:|Color\(hex:|UIColor\(red:/.test(line)) {
        offenders.push(`${file.path}:${index + 1} literal colour`);
      }
      if (/cornerRadius:\s*\d+(?!\s*\/)/.test(line) && !line.includes('BeforeTheme')) {
        offenders.push(`${file.path}:${index + 1} literal corner radius`);
      }
      if (/\.font\(\.system\(size:/.test(line)) {
        offenders.push(`${file.path}:${index + 1} literal font size`);
      }
    });
  }

  assert.deepEqual(offenders, [], 'feature code must use BeforeTheme tokens');
});

// ---------------------------------------------------------------------------
// Analytics
// ---------------------------------------------------------------------------

test('every tracked analytics event is declared in the enum', () => {
  const analytics = readFileSync(join(iosRoot, 'BEFORE/Core/Analytics.swift'), 'utf8');
  const declared = new Set(
    [...analytics.matchAll(/case (\w+)(?:\s*=\s*"[^"]+")?/g)].map((m) => m[1]),
  );

  const missing: string[] = [];
  for (const file of appSources) {
    for (const match of stripComments(file.body).matchAll(/Analytics\.track\(\s*\.(\w+)/g)) {
      if (!declared.has(match[1])) missing.push(`${file.path}: .${match[1]}`);
    }
  }

  assert.deepEqual(missing, [], 'undeclared analytics events');
});

test('analytics events actually fire for the key moments', () => {
  const tracked = new Set<string>();
  for (const file of appSources) {
    for (const match of file.body.matchAll(/Analytics\.track\(\s*\.(\w+)/g)) tracked.add(match[1]);
  }

  // The events the funnel is built on. If one stops firing, the product goes
  // blind at exactly the point that matters.
  for (const required of [
    'onboardingStarted',
    'onboardingCompleted',
    'analysisStarted',
    'analysisCompleted',
    'analysisFailed',
    'verdictViewed',
    'itemSaved',
    'paywallViewed',
    'subscriptionStarted',
    'restoreStarted',
  ]) {
    assert.ok(tracked.has(required), `nothing fires Analytics.track(.${required})`);
  }
});

// ---------------------------------------------------------------------------
// UI test contract
// ---------------------------------------------------------------------------

test('every accessibility identifier a UI test looks for exists in the app', () => {
  const uiTests = sources.filter((f) => f.path.startsWith('BEFOREUITests/'));
  assert.ok(uiTests.length > 0, 'no UI tests found');

  const declared = new Set<string>();
  /**
   * Some identifiers are interpolated, e.g. `"outcome.\(action.rawValue)"`,
   * which is correct and DRY but not statically resolvable. The static PREFIX
   * is, so it is recorded and any identifier beginning with it is accepted.
   */
  const prefixes: string[] = [];

  for (const file of appSources) {
    for (const match of file.body.matchAll(/accessibilityIdentifier\("([^"]*)"\)/g)) {
      if (!match[1].includes('\\(')) declared.add(match[1]);
    }
    for (const match of file.body.matchAll(/accessibilityIdentifier\("([^"\\]*)\\\(/g)) {
      if (match[1]) prefixes.push(match[1]);
    }
  }

  const missing: string[] = [];
  for (const file of uiTests) {
    // Identifiers follow a dotted convention, which is what distinguishes them
    // from plain button titles in the same lookup calls.
    for (const match of file.body.matchAll(/(?:buttons|staticTexts|textFields|otherElements)\["([a-z]+\.[A-Za-z.]+)"\]/g)) {
      const identifier = match[1];
      if (declared.has(identifier)) continue;
      if (prefixes.some((prefix) => identifier.startsWith(prefix))) continue;
      missing.push(`${file.path}: "${identifier}"`);
    }
  }

  assert.deepEqual(missing, [], 'UI tests reference identifiers that no view sets');
});

// ---------------------------------------------------------------------------
// Project rules (.claude/rules/ios.md)
// ---------------------------------------------------------------------------

test('no force-unwraps or try! outside tests', () => {
  const offenders: string[] = [];

  for (const file of appSources) {
    stripComments(file.body).split('\n').forEach((line, index) => {
      if (/\btry!/.test(line)) offenders.push(`${file.path}:${index + 1} try!`);

      // `foo!.bar` or `foo!)` or `foo!,` — but not `!=`, `!foo`, or a
      // force-unwrapped type annotation in a test-only stub.
      if (/[A-Za-z_\]\)]\!(?=[\.\),\s]|$)/.test(line) && !/!=/.test(line)) {
        offenders.push(`${file.path}:${index + 1} force unwrap: ${line.trim().slice(0, 70)}`);
      }
    });
  }

  assert.deepEqual(offenders, [], 'force-unwrapping is not allowed outside test targets');
});

test('no completion-handler or DispatchQueue concurrency in new code', () => {
  const offenders: string[] = [];
  for (const file of appSources) {
    stripComments(file.body).split('\n').forEach((line, index) => {
      if (/DispatchQueue\.(main|global)/.test(line)) {
        offenders.push(`${file.path}:${index + 1} DispatchQueue`);
      }
    });
  }
  assert.deepEqual(offenders, [], 'use async/await, not DispatchQueue');
});

test('the app target never references a server-side secret', () => {
  const forbidden = [
    /SUPABASE_SERVICE_ROLE_KEY/,
    /ANTHROPIC_API_KEY/,
    /OPENAI_API_KEY/,
    /GEMINI_API_KEY/,
    /APPLE_PRIVATE_KEY/,
    /service_role/,
  ];

  const offenders: string[] = [];
  for (const file of sources) {
    for (const pattern of forbidden) {
      if (pattern.test(file.body)) offenders.push(`${file.path}: ${pattern}`);
    }
  }
  assert.deepEqual(offenders, [], 'the iOS target must know only the URL and the anon key');
});

test('entitlement is never read from UserDefaults as a source of truth', () => {
  const subscription = readFileSync(
    join(iosRoot, 'BEFORE/Services/SubscriptionManager.swift'),
    'utf8',
  );

  // The cache exists so the paywall does not flash on launch. What matters is
  // that refreshEntitlements() overwrites it from verified transactions.
  assert.match(subscription, /Transaction\.currentEntitlements/);
  assert.match(subscription, /case \.verified/);
  assert.ok(
    subscription.includes('UserDefaults.standard.set(entitled'),
    'the cached flag must be written FROM the verified check, never the reverse',
  );

  for (const file of appSources) {
    if (file.path.endsWith('SubscriptionManager.swift')) continue;
    assert.ok(
      !/UserDefaults[\s\S]{0,80}(isPlus|premium)/i.test(file.body),
      `${file.path} reads entitlement from UserDefaults`,
    );
  }
});

// ---------------------------------------------------------------------------
// Product rules that are visible in source
// ---------------------------------------------------------------------------

test('no user-facing copy claims guaranteed savings', () => {
  // Spec §32: "potential spend avoided", never "you saved".
  const banned = [
    /"[^"]*\byou saved\b[^"]*"/i,
    /"[^"]*guaranteed to save[^"]*"/i,
    /"[^"]*\balways knows best\b[^"]*"/i,
    /"[^"]*AI-powered[^"]*"/i,
  ];

  const offenders: string[] = [];
  for (const file of appSources) {
    // Comments are stripped: several of them quote the banned phrases in order
    // to explain why they are banned.
    const code = stripComments(file.body);
    for (const pattern of banned) {
      const match = code.match(pattern);
      if (match) offenders.push(`${file.path}: ${match[0]}`);
    }
  }
  assert.deepEqual(offenders, [], 'banned marketing language found in app copy');
});

test('the AI nature of the advice is disclosed in the app', () => {
  // App Store review needs this stated in the app, not only in a policy.
  const combined = appSources.map((f) => f.body).join('\n');
  assert.match(
    combined,
    /generated by AI|AI-generated/,
    'no in-app disclosure that verdicts are AI-generated',
  );
});

test('account deletion tells the user we cannot cancel their subscription', () => {
  const profile = readFileSync(join(iosRoot, 'BEFORE/Features/Profile/ProfileView.swift'), 'utf8');
  assert.match(profile, /only Apple can do that/i);
});

// ---------------------------------------------------------------------------
// Swift 6 concurrency traps.
//
// Both of these were real CI failures. They are here because they are
// invisible on a machine without a Swift compiler, and because the obvious
// "fix" for the first one — `nonisolated(unsafe)` — compiles and is a race.
// ---------------------------------------------------------------------------

test('a cancellable task is held in a TaskHandle, not a stored Task?', () => {
  // `deinit` on a `@MainActor` type is nonisolated under Swift 6, so it cannot
  // read a main-actor-isolated `Task?`. `TaskHandle` puts the handle behind a
  // lock so `deinit { work.cancel() }` is both legal and race-free.
  const offenders: string[] = [];

  for (const { path, body } of sources) {
    if (path.endsWith('Support/TaskHandle.swift')) continue; // the one place it belongs
    for (const [index, line] of stripComments(body).split('\n').entries()) {
      if (/\b(?:var|let)\s+\w+\s*:\s*Task</.test(line)) {
        offenders.push(`${path}:${index + 1}`);
      }
    }
  }

  assert.deepEqual(
    offenders,
    [],
    'stored Task properties cannot be cancelled from deinit — use BeforeKit.TaskHandle',
  );
});

test('every deinit only calls methods, never touches stored state', () => {
  const offenders: string[] = [];

  for (const { path, body } of sources) {
    const stripped = stripComments(body);
    for (const match of stripped.matchAll(/\bdeinit\s*\{([^{}]*)\}/g)) {
      const inside = match[1];
      // `x.cancel()`, `x.invalidate()` — a call on a Sendable helper — is fine.
      // An assignment, or a member read without a call, is main-actor state.
      const remaining = inside.replace(/\b[\w.]+\([^()]*\)\s*;?/g, '').trim();
      if (remaining.length > 0) {
        const line = stripped.slice(0, match.index).split('\n').length;
        offenders.push(`${path}:${line} — leftover: ${remaining}`);
      }
    }
  }

  assert.deepEqual(offenders, [], 'a nonisolated deinit cannot read main-actor state');
});

test('Decimal money is converted before it is rounded', () => {
  // `Decimal` has no `rounded()`. Writing one makes Swift look for a
  // floating-point `*` and report the error on the multiplication instead,
  // which sends you looking in the wrong place.
  const offenders: string[] = [];

  for (const { path, body } of sources) {
    for (const [index, line] of stripComments(body).split('\n').entries()) {
      if (!line.includes('.rounded()')) continue;
      if (!/\bprice\b|\bDecimal\b/.test(line)) continue;
      if (line.includes('NSDecimalNumber') || line.includes('doubleValue')) continue;
      offenders.push(`${path}:${index + 1}`);
    }
  }

  assert.deepEqual(
    offenders,
    [],
    'Decimal has no rounded() — go through NSDecimalNumber(decimal:).doubleValue',
  );
});

test('a titled Section never also passes header: or footer:', () => {
  // SwiftUI has `Section(_:content:)` and `Section(content:header:footer:)` and
  // nothing in between. `Section("Privacy") { … } footer: { … }` is three
  // compile errors, every one of them pointing at the title rather than at the
  // footer that is actually the problem.
  const offenders: string[] = [];

  for (const { path, body } of sources) {
    // Brace counting is only safe once string literals are gone: a `}` inside
    // user-facing copy would throw the walk off.
    const src = stripComments(body).replace(/"(?:[^"\\n]|\.)*"/g, '""');

    for (const match of src.matchAll(/Section\(\s*[^)\s][^)]*\)\s*\{/g)) {
      let depth = 0;
      let i = match.index! + match[0].length - 1;
      for (; i < src.length; i++) {
        if (src[i] === '{') depth += 1;
        else if (src[i] === '}' && --depth === 0) break;
      }

      const trailing = /^\s*(header|footer)\s*:/.exec(src.slice(i + 1, i + 40));
      if (trailing) {
        const line = src.slice(0, match.index).split('\n').length;
        offenders.push(`${path}:${line} — Section(title) { … } ${trailing[1]}:`);
      }
    }
  }

  assert.deepEqual(
    offenders,
    [],
    'write Section { content } header: { Text(title) } footer: { … } instead',
  );
});
