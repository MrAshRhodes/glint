'use strict';

// Runs Scripts/generate_appcast.sh against a fixture release with Sparkle's real tools
// (resolved into .build/artifacts by `swift build`) and a public test key pair.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');

const root = path.resolve(__dirname, '../..');
const tools = path.join(root, '.build/artifacts/sparkle/Sparkle/bin');
// The public RFC 8032 section 7.1 TEST 1 vector, not a release credential.
const seed = Buffer.from('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60', 'hex').toString('base64');
const publicKey = Buffer.from('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a', 'hex').toString('base64');
const changelog = '# Changelog\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n### Added\n\n- Fixture update.\n';

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 60000 });
  assert.equal(result.status, 0, `${command}: ${result.stderr}\n${result.stdout}`);
  return result.stdout;
}

function fixture(t, { plist = {}, notes = changelog } = {}) {
  assert.ok(fs.existsSync(path.join(tools, 'generate_appcast')), 'Run `swift build` to resolve Sparkle first');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'glint-appcast-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  fs.mkdirSync(path.join(dir, 'Scripts'));
  fs.copyFileSync(path.join(root, 'Scripts/generate_appcast.sh'), path.join(dir, 'Scripts/generate_appcast.sh'));
  fs.mkdirSync(path.join(dir, '.github/scripts'), { recursive: true });
  fs.copyFileSync(path.join(root, '.github/scripts/changelog.cjs'), path.join(dir, '.github/scripts/changelog.cjs'));
  fs.mkdirSync(path.join(dir, '.build/artifacts/sparkle/Sparkle'), { recursive: true });
  fs.symlinkSync(tools, path.join(dir, '.build/artifacts/sparkle/Sparkle/bin'));
  fs.writeFileSync(path.join(dir, 'CHANGELOG.md'), notes);

  const app = path.join(dir, 'dist/Glint.app');
  fs.mkdirSync(path.join(app, 'Contents/MacOS'), { recursive: true });
  fs.copyFileSync('/usr/bin/true', path.join(app, 'Contents/MacOS/Glint'));
  const infoPlist = path.join(app, 'Contents/Info.plist');
  fs.copyFileSync(path.join(root, 'Resources/Info.plist'), infoPlist);
  // Sparkle's generate_appcast caches by bundle identifier, so every fixture needs its own.
  const values = {
    CFBundleIdentifier: ['string', `io.github.mrashrhodes.glint.fixture.${path.basename(dir)}`],
    CFBundleVersion: ['string', '999999'],
    CFBundleShortVersionString: ['string', '1.0.0'],
    SUPublicEDKey: ['string', publicKey],
    ...plist,
  };
  for (const [key, [type, value]] of Object.entries(values)) {
    run('/usr/bin/plutil', ['-replace', key, `-${type}`, value, infoPlist]);
  }
  run('codesign', ['--force', '--sign', '-', app]);
  run('ditto', ['-c', '-k', '--norsrc', '--noextattr', '--keepParent', app, path.join(dir, 'dist/Glint-1.0.0.zip')]);

  const env = { ...process.env, GLINT_SPARKLE_PRIVATE_KEY: seed, GLINT_SPARKLE_PUBLIC_KEY: publicKey };
  return {
    dir,
    env,
    feed: path.join(dir, 'dist/appcast.xml'),
    generate: (version = '1.0.0') => spawnSync('bash', [path.join(dir, 'Scripts/generate_appcast.sh'), version], {
      env, encoding: 'utf8', timeout: 60000,
    }),
  };
}

test('real Sparkle tools sign the final archive and feed, and feed tampering is rejected', t => {
  const f = fixture(t);
  const result = f.generate();
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  const xml = fs.readFileSync(f.feed, 'utf8');
  assert.match(xml, /https:\/\/github\.com\/MrAshRhodes\/glint\/releases\/download\/v1\.0\.0\/Glint-1\.0\.0\.zip/);
  assert.match(xml, /https:\/\/github\.com\/MrAshRhodes\/glint\/releases\/tag\/v1\.0\.0/);
  assert.match(xml, /Fixture update/);
  assert.match(xml, /sparkle:edSignature=/);
  const checksum = fs.readFileSync(`${f.feed}.sha256`, 'utf8');
  assert.match(checksum, /^[0-9a-f]{64} {2}appcast\.xml\n$/);
  assert.equal(fs.readdirSync(path.join(f.dir, 'dist')).filter(name => name.startsWith('appcast.')).sort().join(),
    'appcast.xml,appcast.xml.sha256', 'the staging directory must not be left behind');

  fs.writeFileSync(f.feed, xml.replace('Fixture update', 'Tampered notes'));
  const verify = spawnSync(path.join(tools, 'sign_update'), ['--ed-key-file', '-', '--verify', f.feed], {
    input: seed, encoding: 'utf8', timeout: 10000,
  });
  assert.notEqual(verify.status, 0, 'a tampered appcast was accepted');
});

test('real Sparkle tools reject a tampered archive and an invalid archive signature', t => {
  const f = fixture(t);
  const result = f.generate();
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  const xml = fs.readFileSync(f.feed, 'utf8');
  const signature = xml.match(/sparkle:edSignature="([^"]+)"/)?.[1];
  assert.ok(signature, 'the generated feed must include an archive signature');
  const archive = path.join(f.dir, 'dist/Glint-1.0.0.zip');
  const verify = suppliedSignature => {
    const result = spawnSync(path.join(tools, 'sign_update'),
      ['--ed-key-file', '-', '--verify', archive, suppliedSignature], {
        input: seed, encoding: 'utf8', timeout: 10000,
      });
    assert.ifError(result.error);
    assert.equal(result.signal, null, 'verification must finish, not be killed');
    return result;
  };

  const valid = verify(signature);
  assert.equal(valid.status, 0, `${valid.stdout}\n${valid.stderr}`);

  const invalidSignature = Buffer.from(signature, 'base64');
  invalidSignature[0] ^= 1;
  assert.notEqual(verify(invalidSignature.toString('base64')).status, 0,
    'a well-formed but invalid signature was accepted');

  fs.appendFileSync(archive, 'tampered');
  assert.notEqual(verify(signature).status, 0, 'a tampered archive was accepted');
});

test('the app signature verifier rejects a modified signed bundle', t => {
  const f = fixture(t);
  const app = path.join(f.dir, 'dist/Glint.app');
  const script = path.join(root, 'Scripts/verify_signature.sh');
  run('bash', [script, app]);

  run('/usr/bin/plutil', ['-replace', 'CFBundleShortVersionString', '-string', '9.9.9',
    path.join(app, 'Contents/Info.plist')]);
  const result = spawnSync('bash', [script, app], { encoding: 'utf8', timeout: 10000 });
  assert.ifError(result.error);
  assert.equal(result.signal, null, 'verification must finish, not be killed');
  assert.notEqual(result.status, 0, 'a modified signed app was accepted');
  assert.match(result.stderr, /invalid code signature/);
});

test('a public key that differs from the one embedded in the app never yields a feed', t => {
  const f = fixture(t);
  f.env.GLINT_SPARKLE_PUBLIC_KEY = Buffer.alloc(32).toString('base64');
  const result = f.generate();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /archive public key mismatch/);
  assert.ok(!fs.existsSync(f.feed));
});

test('a private key that does not match the app\'s public key never yields a feed', t => {
  const f = fixture(t);
  f.env.GLINT_SPARKLE_PRIVATE_KEY = Buffer.alloc(32, 1).toString('base64');
  const result = f.generate();
  assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`);
  assert.match(result.stderr, /missing archive signature|does not match the app's public key/);
  assert.ok(!fs.existsSync(f.feed));
});

test('a missing private key fails without a Keychain fallback', t => {
  const f = fixture(t);
  f.env.GLINT_SPARKLE_PRIVATE_KEY = '';
  const result = f.generate();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Missing Sparkle private key/);
  assert.ok(!fs.existsSync(f.feed));
});

test('prereleases are not published to the update feed', t => {
  const f = fixture(t);
  const result = f.generate('1.0.0-beta.1');
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /prerelease/);
  assert.ok(!fs.existsSync(f.feed));
});

test('an app that does not require a signed feed is refused', t => {
  const f = fixture(t, { plist: { SURequireSignedFeed: ['bool', 'false'] } });
  const result = f.generate();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /archive must require a signed feed/);
  assert.ok(!fs.existsSync(f.feed));
});

test('a release without changelog notes is refused', t => {
  const f = fixture(t, { notes: '# Changelog\n\n## [Unreleased]\n' });
  const result = f.generate();
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /1\.0\.0/);
  assert.ok(!fs.existsSync(f.feed));
});
