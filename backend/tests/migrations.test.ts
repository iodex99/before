/**
 * Static checks over the SQL migrations.
 *
 * These catch the class of mistake that is invisible in review and catastrophic
 * in production: a new user-owned table that nobody remembered to put RLS on.
 * No database required, so they run in CI on every change.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(here, '../supabase/migrations');

const files = readdirSync(migrationsDir)
  .filter((name) => name.endsWith('.sql'))
  .sort();

const sql = files.map((name) => ({ name, body: readFileSync(join(migrationsDir, name), 'utf8') }));
const allSql = sql.map((f) => f.body).join('\n');

/** Strip comments so `-- create table ...` in prose is never treated as code. */
function stripComments(body: string): string {
  return body
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split('\n')
    .map((line) => line.replace(/--.*$/, ''))
    .join('\n');
}

const code = stripComments(allSql);

/** Every `create table public.x (...)` with its body. */
function tableDefinitions(): Map<string, string> {
  const tables = new Map<string, string>();
  const pattern = /create table (?:if not exists )?public\.(\w+)\s*\(/gi;
  let match: RegExpExecArray | null;

  while ((match = pattern.exec(code)) !== null) {
    const name = match[1];
    // Walk to the matching close paren so nested parens in constraints are handled.
    let depth = 1;
    let index = pattern.lastIndex;
    while (index < code.length && depth > 0) {
      if (code[index] === '(') depth++;
      else if (code[index] === ')') depth--;
      index++;
    }
    tables.set(name, code.slice(match.index, index));
  }
  return tables;
}

const tables = tableDefinitions();

test('migrations exist and are uniquely, sequentially numbered', () => {
  assert.ok(files.length > 0, 'no migrations found');
  const numbers = files.map((name) => {
    const match = name.match(/^(\d{4})_/);
    assert.ok(match, `migration "${name}" must start with a 4-digit sequence`);
    return Number(match[1]);
  });
  assert.deepEqual(numbers, [...new Set(numbers)], 'duplicate migration numbers');
  assert.deepEqual(numbers, [...numbers].sort((a, b) => a - b), 'migrations out of order');
});

test('every user-owned table enables row level security', () => {
  for (const [name, body] of tables) {
    if (!/\buser_id\b/.test(body)) continue;
    assert.match(
      code,
      new RegExp(`alter table public\\.${name} enable row level security`, 'i'),
      `table "${name}" has user_id but never enables RLS`,
    );
  }
});

test('every table in public enables row level security, owned or not', () => {
  for (const name of tables.keys()) {
    assert.match(
      code,
      new RegExp(`alter table public\\.${name} enable row level security`, 'i'),
      `table "${name}" never enables RLS — default-deny is the only safe default here`,
    );
  }
});

test('user-owned tables scope every policy to auth.uid(), never USING (true)', () => {
  const policyPattern =
    /create policy\s+(?:"([^"]+)"|(\w+))\s+on\s+(?:public\.)?(\w+)[\s\S]*?(?=create policy|create table|create index|create trigger|alter table|create or replace|insert into|$)/gi;

  let match: RegExpExecArray | null;
  let checked = 0;

  while ((match = policyPattern.exec(code)) !== null) {
    const policyName = match[1] ?? match[2];
    const tableName = match[3];
    const body = match[0];
    const definition = tables.get(tableName);
    if (!definition || !/\buser_id\b|\bid uuid primary key references auth\.users\b/.test(definition)) {
      continue;
    }

    checked++;
    assert.ok(
      /auth\.uid\(\)/.test(body),
      `policy "${policyName}" on "${tableName}" does not reference auth.uid()`,
    );
    assert.ok(
      !/using\s*\(\s*true\s*\)/i.test(body),
      `policy "${policyName}" on "${tableName}" uses USING (true) on a user-owned table`,
    );
  }

  assert.ok(checked > 5, `expected to check several policies, only checked ${checked}`);
});

test('tables with updated_at have the set_updated_at trigger', () => {
  for (const [name, body] of tables) {
    if (!/\bupdated_at\b/.test(body)) continue;
    assert.match(
      code,
      new RegExp(`create trigger \\w+\\s+before update on public\\.${name}`, 'i'),
      `table "${name}" has updated_at but no trigger to maintain it`,
    );
  }
});

test('storage buckets are private', () => {
  const inserts = code.match(/insert into storage\.buckets[\s\S]*?;/gi) ?? [];
  assert.ok(inserts.length > 0, 'expected storage buckets to be created');
  for (const statement of inserts) {
    assert.ok(
      !/,\s*true\s*,/.test(statement),
      'a storage bucket is marked public — every bucket in BEFORE is private',
    );
  }
});

test('money columns are numeric, never floating point', () => {
  for (const [name, body] of tables) {
    const floats = body.match(/\b\w*(?:price|amount|cost)\w*\s+(real|double precision|float\d*)/gi);
    assert.equal(floats, null, `table "${name}" stores money as a float: ${floats?.join(', ')}`);
  }
});

test('migrations are additive — no destructive statements', () => {
  for (const { name, body } of sql) {
    const stripped = stripComments(body);
    for (const pattern of [/\bdrop table\b/i, /\btruncate\b/i, /\bdrop column\b/i]) {
      assert.ok(
        !pattern.test(stripped),
        `migration "${name}" contains a destructive statement matching ${pattern}`,
      );
    }
  }
});

test('security definer functions pin search_path', () => {
  const definers = code.match(/create or replace function[\s\S]*?(?=\$\$)/gi) ?? [];
  for (const definition of definers) {
    if (!/security definer/i.test(definition)) continue;
    assert.ok(
      /set search_path\s*=/i.test(definition),
      `a security definer function does not pin search_path:\n${definition.slice(0, 160)}`,
    );
  }
});

test('the expected core tables all exist', () => {
  const expected = [
    'users',
    'user_preferences',
    'analyses',
    'analysis_factors',
    'analysis_products',
    'wardrobe_items',
    'saved_items',
    'purchase_outcomes',
    'usage_ledger',
    'subscriptions',
    'share_events',
    'analytics_events',
  ];
  for (const name of expected) {
    assert.ok(tables.has(name), `expected table "${name}" is missing`);
  }
});

test('the enums match the TypeScript contract', async () => {
  const { VERDICTS, CATEGORIES, SUGGESTED_ACTIONS, SIGNAL_KEYS } = await import('../shared/types.ts');

  const enumValues = (typeName: string): string[] => {
    const match = code.match(new RegExp(`create type public\\.${typeName} as enum \\(([\\s\\S]*?)\\);`, 'i'));
    assert.ok(match, `enum ${typeName} not found`);
    return [...match[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
  };

  assert.deepEqual(enumValues('verdict'), [...VERDICTS]);
  assert.deepEqual(enumValues('product_category'), [...CATEGORIES]);
  assert.deepEqual(enumValues('suggested_action'), [...SUGGESTED_ACTIONS]);
  assert.deepEqual(enumValues('signal_key'), [...SIGNAL_KEYS]);
});
