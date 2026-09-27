/**
 * GitHub Actions workflow checks.
 *
 * A workflow with a YAML error does not fail loudly — it silently does not run,
 * and the first you know is that nothing was ever tested. These checks make
 * that a red test on a laptop instead.
 *
 * They also cross-reference the workflows against the repository: an `npm run`
 * that no longer exists, or a script path that moved, is caught here rather
 * than on a push.
 */

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import yaml from 'js-yaml';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '../..');
const workflowDir = join(root, '.github/workflows');

interface Step {
  name?: string;
  uses?: string;
  run?: string;
  with?: Record<string, unknown>;
  'working-directory'?: string;
}

interface Job {
  name?: string;
  'runs-on'?: string;
  'timeout-minutes'?: number;
  steps?: Step[];
  needs?: string | string[];
  services?: Record<string, unknown>;
}

interface Workflow {
  name?: string;
  on?: unknown;
  concurrency?: { group?: string; 'cancel-in-progress'?: boolean };
  permissions?: Record<string, string>;
  jobs?: Record<string, Job>;
}

const files = existsSync(workflowDir)
  ? readdirSync(workflowDir).filter((f) => f.endsWith('.yml') || f.endsWith('.yaml'))
  : [];

const workflows = files.map((file) => ({
  file,
  raw: readFileSync(join(workflowDir, file), 'utf8'),
  doc: yaml.load(readFileSync(join(workflowDir, file), 'utf8')) as Workflow,
}));

const packageJson = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')) as {
  scripts: Record<string, string>;
};

function allSteps(workflow: Workflow): Array<{ job: string; step: Step }> {
  return Object.entries(workflow.jobs ?? {}).flatMap(([job, definition]) =>
    (definition.steps ?? []).map((step) => ({ job, step })),
  );
}

// ---------------------------------------------------------------------------

test('workflows exist and parse as YAML', () => {
  assert.ok(files.length >= 2, `expected CI and iOS workflows, found ${files.join(', ') || 'none'}`);
  for (const { file, doc } of workflows) {
    assert.ok(doc && typeof doc === 'object', `${file} did not parse into an object`);
    assert.ok(doc.jobs && Object.keys(doc.jobs).length > 0, `${file} defines no jobs`);
  }
});

test('every workflow declares a trigger', () => {
  for (const { file, doc } of workflows) {
    // `on` is a YAML 1.1 boolean, so js-yaml parses the key as `true`. Check
    // the raw text rather than trusting the parsed key.
    const hasTrigger = doc.on !== undefined || (doc as Record<string, unknown>)[String(true)] !== undefined;
    assert.ok(hasTrigger, `${file} has no "on:" trigger`);
  }
});

test('every job has a timeout', () => {
  // The default is six hours. A hung simulator should not cost six hours.
  for (const { file, doc } of workflows) {
    for (const [name, job] of Object.entries(doc.jobs ?? {})) {
      assert.ok(
        typeof job['timeout-minutes'] === 'number',
        `${file}: job "${name}" has no timeout-minutes`,
      );
      assert.ok(
        job['timeout-minutes']! <= 60,
        `${file}: job "${name}" allows ${job['timeout-minutes']} minutes`,
      );
    }
  }
});

test('every workflow requests least-privilege permissions', () => {
  for (const { file, doc } of workflows) {
    assert.ok(doc.permissions, `${file} does not set permissions`);
    assert.equal(
      doc.permissions?.contents,
      'read',
      `${file} should only need read access to contents`,
    );
    for (const [scope, level] of Object.entries(doc.permissions ?? {})) {
      assert.notEqual(level, 'write', `${file} requests write on ${scope}`);
    }
  }
});

test('every workflow serialises, and only the safe ones cancel', () => {
  // Two different rules, and the difference matters. A CI run is cheap and
  // idempotent, so a superseded one should be cancelled. A release run is
  // neither: cancelling an upload midway burns a build number and can leave
  // App Store Connect holding a half-delivered build. Those must queue.
  const RELEASE_WORKFLOWS = new Set(['testflight.yml']);

  for (const { file, doc } of workflows) {
    assert.ok(doc.concurrency?.group, `${file} has no concurrency group`);

    if (RELEASE_WORKFLOWS.has(file)) {
      assert.equal(
        doc.concurrency?.['cancel-in-progress'],
        false,
        `${file} is a release workflow and must queue rather than cancel`,
      );
    } else {
      assert.equal(
        doc.concurrency?.['cancel-in-progress'],
        true,
        `${file} does not cancel superseded runs`,
      );
    }
  }
});

test('the release workflow is never triggered by an ordinary push', () => {
  // A TestFlight build costs a build number, a processing slot, and a
  // notification to every tester. It happens when someone asks for it.
  const release = workflows.find((w) => w.file === 'testflight.yml');
  assert.ok(release, 'testflight.yml not found');

  const triggers = (release.doc.on ?? (release.doc as Record<string, unknown>)[String(true)]) as
    | Record<string, unknown>
    | undefined;
  assert.ok(triggers, 'no triggers declared');

  assert.ok('workflow_dispatch' in triggers, 'release must be runnable manually');

  const push = triggers.push as { branches?: string[]; tags?: string[] } | undefined;
  if (push) {
    assert.ok(!push.branches, 'the release workflow must not trigger on a branch push');
    assert.ok(push.tags?.length, 'a push trigger on the release workflow must be tag-only');
  }
});

test('the release workflow cleans up signing material even on failure', () => {
  const release = workflows.find((w) => w.file === 'testflight.yml');
  assert.ok(release);

  const cleanup = (release.doc.jobs?.release?.steps ?? []).find((s) =>
    /clean up signing/i.test(s.name ?? ''),
  ) as (Step & { if?: string }) | undefined;

  assert.ok(cleanup, 'no cleanup step');
  assert.equal(
    (cleanup as Record<string, unknown>).if,
    'always()',
    'a signing keychain left behind on a failed run is a credential left on a runner',
  );
  assert.match(cleanup.run ?? '', /delete-keychain/);
});

// ---------------------------------------------------------------------------
// Cross-references — the checks that actually catch drift
// ---------------------------------------------------------------------------

test('every `npm run` in a workflow names a script that exists', () => {
  const missing: string[] = [];

  for (const { file, doc } of workflows) {
    for (const { job, step } of allSteps(doc)) {
      for (const match of (step.run ?? '').matchAll(/npm run (?:--silent )?([\w:]+)/g)) {
        if (!packageJson.scripts[match[1]]) {
          missing.push(`${file} / ${job}: npm run ${match[1]}`);
        }
      }
    }
  }

  assert.deepEqual(missing, [], 'workflows reference npm scripts that do not exist');
});

test('every script path a workflow runs exists on disk', () => {
  const missing: string[] = [];

  for (const { file, doc } of workflows) {
    for (const { job, step } of allSteps(doc)) {
      for (const match of (step.run ?? '').matchAll(/\b(?:bash|sh)\s+([\w./-]+\.sh)/g)) {
        if (!existsSync(join(root, match[1]))) {
          missing.push(`${file} / ${job}: ${match[1]}`);
        }
      }
    }
  }

  assert.deepEqual(missing, [], 'workflows run scripts that are not in the repository');
});

test('every working-directory a workflow uses exists', () => {
  for (const { file, doc } of workflows) {
    for (const { job, step } of allSteps(doc)) {
      const directory = step['working-directory'];
      if (!directory) continue;
      assert.ok(
        existsSync(join(root, directory)),
        `${file} / ${job}: working-directory "${directory}" does not exist`,
      );
    }
  }
});

test('actions are pinned to a major version', () => {
  for (const { file, doc } of workflows) {
    for (const { job, step } of allSteps(doc)) {
      if (!step.uses) continue;
      assert.match(
        step.uses,
        /@v\d+/,
        `${file} / ${job}: "${step.uses}" is not pinned to a major version`,
      );
    }
  }
});

// ---------------------------------------------------------------------------
// Project-specific requirements
// ---------------------------------------------------------------------------

test('CI runs Node 22 or newer', () => {
  // Below 22.6 Node cannot execute TypeScript directly, and the entire
  // no-build-step arrangement stops working.
  const ci = workflows.find((w) => w.file === 'ci.yml');
  assert.ok(ci, 'ci.yml not found');

  const nodeSteps = allSteps(ci.doc).filter((s) => s.step.uses?.startsWith('actions/setup-node'));
  assert.ok(nodeSteps.length > 0, 'ci.yml never sets up Node');

  for (const { job, step } of nodeSteps) {
    const version = String(step.with?.['node-version'] ?? '');
    assert.ok(
      Number.parseInt(version, 10) >= 22,
      `ci.yml / ${job}: node-version is "${version}", but 22+ is required`,
    );
  }
});

test('CI verifies the migrations against a real Postgres', () => {
  const ci = workflows.find((w) => w.file === 'ci.yml');
  assert.ok(ci);

  const database = ci.doc.jobs?.database;
  assert.ok(database, 'ci.yml has no database job');
  assert.ok(database.services?.postgres, 'the database job has no Postgres service');
  assert.ok(
    allSteps(ci.doc).some((s) => s.step.run?.includes('verify-migrations.sh')),
    'the database job does not run the migration verifier',
  );
});

test('CI runs the secret scan', () => {
  const ci = workflows.find((w) => w.file === 'ci.yml');
  assert.ok(ci);
  assert.ok(
    allSteps(ci.doc).some((s) => s.step.run?.includes('check:secrets')),
    'no job runs the secret scan',
  );
});

test('the iOS workflow runs the score parity tests', () => {
  const ios = workflows.find((w) => w.file === 'ios.yml');
  assert.ok(ios, 'ios.yml not found');

  assert.ok(
    allSteps(ios.doc).some((s) => s.step.run?.includes('swift test --package-path ios/BeforeKit')),
    'ios.yml does not run the BeforeKit tests, which are the score parity check',
  );
  assert.ok(
    Object.values(ios.doc.jobs ?? {}).every((job) => String(job['runs-on']).startsWith('macos')),
    'every iOS job must run on macOS',
  );
});

test('the iOS workflow supplies a config file before building', () => {
  // AppConfig fatals on a missing Info.plist value, so a build without
  // Config.xcconfig fails in a way that looks like a code error.
  const ios = workflows.find((w) => w.file === 'ios.yml');
  assert.ok(ios);

  for (const [name, job] of Object.entries(ios.doc.jobs ?? {})) {
    const steps = job.steps ?? [];
    const buildsProject = steps.some((s) => s.run?.includes('xcodegen generate'));
    if (!buildsProject) continue;

    const configIndex = steps.findIndex((s) => s.run?.includes('Config.xcconfig'));
    const generateIndex = steps.findIndex((s) => s.run?.includes('xcodegen generate'));

    assert.ok(configIndex >= 0, `ios.yml / ${name} generates a project without writing Config.xcconfig`);
    assert.ok(
      configIndex < generateIndex,
      `ios.yml / ${name} writes Config.xcconfig after generating the project`,
    );
  }
});

test('no workflow hard-codes a credential', () => {
  for (const { file, raw } of workflows) {
    for (const pattern of [/sk-ant-[a-zA-Z0-9_-]{8,}/, /eyJ[A-Za-z0-9_-]{30,}\./, /AKIA[0-9A-Z]{16}/]) {
      assert.ok(!pattern.test(raw), `${file} appears to contain a credential`);
    }
  }
});
