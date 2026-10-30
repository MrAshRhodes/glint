'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

const root = path.resolve(__dirname, '../..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');

function fixture(t, config = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'glint-notary-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin);
  fs.mkdirSync(path.join(dir, 'Glint.app'));
  fs.writeFileSync(path.join(dir, 'Glint.dmg'), 'test disk image');
  const calls = path.join(dir, 'calls.jsonl');
  const mock = path.join(bin, 'mock.cjs');
  fs.writeFileSync(mock, `#!${process.execPath}
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const tool = path.basename(process.argv[1]);
const args = process.argv.slice(2);
const config = JSON.parse(process.env.MOCK_CONFIG);
fs.appendFileSync(process.env.MOCK_CALLS, JSON.stringify({ tool, args }) + '\\n');
if (tool === 'xcrun') {
  if (args[0] === '--find') {
    console.log('/mock/' + args[1]);
  } else if (args[0] === 'notarytool' && args[1] === 'history') {
    process.exit(config.historyExit || 0);
  } else if (args[0] === 'notarytool' && args[1] === 'submit') {
    console.log(config.result ?? '{"id":"test-submission","status":"Accepted"}');
    process.exit(config.submitExit || 0);
  } else if (args[0] === 'notarytool' && args[1] === 'log') {
    console.log('Apple diagnostics');
  } else if (args[0] === 'stapler') {
    const status = args[1] === 'staple' ? config.stapleExit : config.validateExit;
    process.exit(status || 0);
  } else {
    process.exit(99);
  }
} else if (tool === 'codesign') {
  if (args.includes('--verify')) process.exit(config.signatureExit || 0);
  if (args.includes('--requirements')) {
    console.log('designated => identifier "io.github.mrashrhodes.glint" and anchor apple generic');
  } else {
    const arch = args.includes('--arch') ? args[args.indexOf('--arch') + 1] : '';
    console.log('Identifier=' + (config.identifier || 'io.github.mrashrhodes.glint'));
    console.log(config.adhoc ? 'Signature=adhoc' : 'Authority=Developer ID Application: Test');
    console.log('CodeDirectory v=20500 flags=' + (config.noRuntime === arch ? '0x0(none)' : '0x10000(runtime)'));
    if (config.noTimestamp !== arch) console.log('Timestamp=Oct 30 2026');
  }
} else if (tool === 'lipo') {
  if (config.lipoExit) process.exit(config.lipoExit);
  console.log(config.archs ?? 'arm64 x86_64');
} else if (tool === 'spctl') {
  process.exit(config.assessExit || 0);
} else if (tool === 'ditto') {
  fs.writeFileSync(args[args.length - 1], 'test submission archive');
} else {
  process.exit(99);
}
`, { mode: 0o755 });
  for (const name of ['xcrun', 'codesign', 'lipo', 'spctl', 'ditto']) {
    fs.symlinkSync(mock, path.join(bin, name));
  }
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (/^(GLINT_|GITHUB_)/.test(key)) delete env[key];
  }
  Object.assign(env, {
    PATH: `${bin}${path.delimiter}${process.env.PATH}`,
    RUNNER_TEMP: dir,
    GLINT_NOTARY_PROFILE: 'test-profile',
    MOCK_CONFIG: JSON.stringify(config),
    MOCK_CALLS: calls,
  });
  return {
    dir,
    env,
    run(script, args, overrides = {}) {
      const result = spawnSync('/bin/bash', [path.join(root, 'Scripts', script), ...args], {
        cwd: dir,
        env: { ...env, ...overrides },
        encoding: 'utf8',
        timeout: 15000,
      });
      assert.ifError(result.error);
      return { ...result, output: result.stdout + result.stderr };
    },
    calls() {
      return fs.existsSync(calls) ? fs.readFileSync(calls, 'utf8').trim().split('\n').map(JSON.parse) : [];
    },
  };
}

function hasCall(f, tool, ...args) {
  return f.calls().some(call => call.tool === tool && args.every((arg, i) => call.args[i] === arg));
}

test('credential preflight requires a profile or a complete, nonempty API key', t => {
  const f = fixture(t);
  for (const overrides of [
    { GLINT_NOTARY_PROFILE: '' },
    { GLINT_NOTARY_PROFILE: '', GLINT_NOTARY_KEY_PATH: '/missing.p8', GLINT_NOTARY_KEY_ID: 'key', GLINT_NOTARY_ISSUER_ID: 'issuer' },
  ]) {
    const result = f.run('notarize.sh', ['--check-credentials'], overrides);
    assert.notEqual(result.status, 0);
    assert.match(result.output, /set GLINT_NOTARY_PROFILE|private key is missing/);
  }
  assert.deepEqual(f.calls(), []);
});

test('preflight validates credentials with Apple and propagates authentication failure', t => {
  const f = fixture(t, { historyExit: 1 });
  const result = f.run('notarize.sh', ['--check-credentials']);
  assert.notEqual(result.status, 0);
  assert.ok(hasCall(f, 'xcrun', 'notarytool', 'history'));
  assert.ok(!hasCall(f, 'xcrun', 'notarytool', 'submit'));
});

test('preflight supports a team API key without a stored profile', t => {
  const f = fixture(t);
  const key = path.join(f.dir, 'key.p8');
  fs.writeFileSync(key, 'fixture key, not a credential');
  const result = f.run('notarize.sh', ['--check-credentials'], {
    GLINT_NOTARY_PROFILE: '', GLINT_NOTARY_KEY_PATH: key,
    GLINT_NOTARY_KEY_ID: 'key-id', GLINT_NOTARY_ISSUER_ID: 'issuer-id',
  });
  assert.equal(result.status, 0, result.output);
  assert.ok(hasCall(f, 'xcrun', 'notarytool', 'history', '--key', key, '--key-id', 'key-id', '--issuer', 'issuer-id'));
});

for (const status of ['Invalid', 'Rejected', 'In Progress', 'Unknown']) {
  test(`notarization status ${status} blocks stapling and assessment`, t => {
    const f = fixture(t, { result: JSON.stringify({ id: 'test-submission', status }) });
    const result = f.run('notarize.sh', ['Glint.dmg']);
    assert.notEqual(result.status, 0);
    assert.match(result.output, /did not finish with Accepted/);
    assert.ok(hasCall(f, 'xcrun', 'notarytool', 'log', 'test-submission'));
    assert.ok(!hasCall(f, 'xcrun', 'stapler'));
    assert.ok(!hasCall(f, 'spctl'));
  });
}

for (const [name, config] of [
  ['transport failure despite Accepted output', { submitExit: 1 }],
  ['malformed JSON', { result: 'not-json' }],
  ['missing status', { result: '{"id":"test-submission"}' }],
  ['empty response', { result: '' }],
]) {
  test(`${name} cannot publish a notarized result`, t => {
    const f = fixture(t, config);
    const result = f.run('notarize.sh', ['Glint.dmg']);
    assert.notEqual(result.status, 0);
    assert.match(result.output, /did not finish with Accepted/);
    assert.ok(!hasCall(f, 'xcrun', 'stapler'));
    assert.ok(!hasCall(f, 'spctl'));
    assert.deepEqual(fs.readdirSync(f.dir).filter(name => name.startsWith('glint-notary.')), []);
  });
}

for (const format of ['app', 'dmg']) {
  test(`Accepted ${format} is stapled, validated and assessed in order`, t => {
    const f = fixture(t);
    const result = f.run('notarize.sh', [`Glint.${format}`]);
    assert.equal(result.status, 0, result.output);
    const stages = f.calls().filter(call => call.tool === 'spctl' ||
      (call.tool === 'xcrun' && call.args[0] !== '--find'))
      .map(call => call.tool === 'spctl' ? 'assess' : call.args[1]);
    assert.deepEqual(stages, format === 'app'
      ? ['submit', 'staple', 'validate', 'validate', 'assess']
      : ['submit', 'staple', 'validate', 'assess']);
    assert.equal(hasCall(f, 'ditto'), format === 'app');
    assert.deepEqual(fs.readdirSync(f.dir).filter(name => name.startsWith('glint-notary.')), []);
  });
}

for (const [name, config] of [
  ['stapling fails', { stapleExit: 1 }],
  ['ticket validation fails', { validateExit: 1 }],
]) {
  test(`${name} prevents Gatekeeper assessment`, t => {
    const f = fixture(t, config);
    assert.notEqual(f.run('notarize.sh', ['Glint.dmg']).status, 0);
    assert.ok(!hasCall(f, 'spctl'));
  });
}

test('Gatekeeper rejection is fatal even after successful notarization', t => {
  const f = fixture(t, { assessExit: 1 });
  assert.notEqual(f.run('notarize.sh', ['Glint.dmg']).status, 0);
  assert.ok(hasCall(f, 'spctl'));
});

test('only app and DMG targets with a valid signature can be submitted', t => {
  const f = fixture(t, { signatureExit: 1 });
  fs.writeFileSync(path.join(f.dir, 'Glint.zip'), 'not staplable');
  for (const name of ['Glint.zip', 'Glint.dmg', 'Glint.app']) {
    assert.notEqual(f.run('notarize.sh', [name]).status, 0);
  }
  assert.ok(!hasCall(f, 'xcrun', 'notarytool', 'submit'));
});

for (const [name, config] of [
  ['missing ticket', { validateExit: 1 }],
  ['Gatekeeper rejection', { assessExit: 1 }],
  ['ad-hoc identity', { adhoc: true }],
  ['wrong identifier', { identifier: 'wrong.bundle' }],
  ['missing hardened runtime in Intel slice', { noRuntime: 'x86_64' }],
  ['missing timestamp in Intel slice', { noTimestamp: 'x86_64' }],
  ['unreadable architectures', { lipoExit: 1 }],
  ['empty architectures', { archs: '' }],
]) {
  test(`require-notarized rejects ${name} even with a matching requirement file`, t => {
    const f = fixture(t, config);
    const result = f.run('verify_signature.sh', ['Glint.app', '--require-notarized']);
    assert.notEqual(result.status, 0, result.output);
    if (config.validateExit) {
      assert.ok(hasCall(f, 'xcrun', 'stapler', 'validate'));
      assert.ok(!hasCall(f, 'spctl'));
    }
    if (config.assessExit) assert.ok(hasCall(f, 'spctl'));
  });
}

test('notarized packaging fails before building without identity or credentials', t => {
  const f = fixture(t);
  for (const identity of ['', '-']) {
    const result = f.run('package_release.sh', ['--notarize'], { GLINT_SIGN_IDENTITY: identity });
    assert.notEqual(result.status, 0);
    assert.match(result.output, /requires GLINT_SIGN_IDENTITY/);
  }
  assert.deepEqual(f.calls(), []);
  const result = f.run('package_release.sh', ['--notarize'], {
    GLINT_SIGN_IDENTITY: 'Developer ID Application: Test', GLINT_NOTARY_PROFILE: '',
  });
  assert.notEqual(result.status, 0);
  assert.match(result.output, /set GLINT_NOTARY_PROFILE/);
  assert.deepEqual(f.calls(), []);
});

test('the test certificate helper cannot overwrite either production requirement', { skip: process.platform !== 'darwin' }, t => {
  const f = fixture(t);
  for (const name of ['designated-requirement', 'developer-id-requirement']) {
    const target = path.join(root, 'packaging/signing', `${name}.txt`);
    const original = fs.readFileSync(target, 'utf8');
    const alias = path.join(f.dir, `${name}.txt`);
    fs.symlinkSync(target, alias);
    for (const req of [target, alias]) {
      const result = f.run('make_signing_cert.sh', [
        '--force', '--out', path.join(f.dir, 'cert'), '--requirement-file', req,
      ]);
      assert.notEqual(result.status, 0);
      assert.match(result.output, /refusing to overwrite a production signing requirement/);
      assert.equal(fs.readFileSync(target, 'utf8'), original);
    }
  }
  assert.ok(!fs.existsSync(path.join(f.dir, 'cert/glint-signing.key')));
});

test('the release workflow requires notarization, keeps secrets tag-scoped, and cleans up before publication', () => {
  const workflow = read('.github/workflows/release.yml');
  assert.match(workflow, /tags: \['v\*'\]/);
  assert.match(workflow, /environment: release/);
  assert.match(workflow, /persist-credentials: false/);
  assert.match(workflow, /import_signing_identity\.sh --require-developer-id/);
  assert.match(workflow, /run: Scripts\/package_release\.sh[^\n]*--require-universal[^\n]*--notarize/);
  assert.doesNotMatch(workflow, /GLINT_ALLOW_ADHOC|continue-on-error/);
  const clean = workflow.indexOf('- name: Remove notarization credentials');
  const publish = workflow.indexOf('- name: Publish the GitHub release');
  assert.ok(clean > 0 && publish > clean);
  assert.match(workflow.slice(clean, publish), /if: always\(\)/);
  assert.match(workflow.slice(clean, publish), /--cleanup "\$KEYCHAIN"/);
  assert.doesNotMatch(read('packaging/homebrew/glint.rb.tmpl'), /xattr|postflight|quarantine/);
});
