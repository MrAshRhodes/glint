'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { test } = require('node:test');
const { check, release, notes, compareVersions, cleanBody } = require('./changelog.cjs');

const script = path.join(__dirname, 'changelog.cjs');
const base = 'https://github.com/owner/repo';

function changelog({ unreleased = '### Added\n\n- New thing. ([#3])', links } = {}) {
  return `# Changelog

Intro with an inline [link](https://keepachangelog.com/).

## [Unreleased]

${unreleased}

## [1.1.0] - 2026-02-01

### Fixed

- A fix. ([#2])

## [1.0.0] - 2026-01-01

First release.

### Added

- Everything.

${links ?? `[Unreleased]: ${base}/compare/v1.1.0...HEAD
[1.1.0]: ${base}/compare/v1.0.0...v1.1.0
[1.0.0]: ${base}/releases/tag/v1.0.0
[#2]: ${base}/pull/2
[#3]: ${base}/pull/3`}
`;
}

test('the repository changelog is consistent', () => {
  const text = fs.readFileSync(path.join(__dirname, '..', '..', 'CHANGELOG.md'), 'utf8');
  assert.deepEqual(check(text), []);
});

test('release moves Unreleased entries under a dated version and updates the links', () => {
  const result = release(changelog({ unreleased: '### Added\n\n- New thing. ([#3])\n\n### Fixed\n\n### Removed\n' }),
    '1.2.0', { date: '2026-03-04' });
  assert.match(result, /## \[Unreleased\]\n\n## \[1\.2\.0\] - 2026-03-04\n\n### Added\n\n- New thing\. \(\[#3\]\)\n\n## \[1\.1\.0\]/);
  assert.doesNotMatch(result, /### Fixed\n\n### Removed/, 'empty subsections are dropped');
  assert.match(result, new RegExp(`\\[Unreleased\\]: ${base}/compare/v1\\.2\\.0\\.\\.\\.HEAD\\n`
    + `\\[1\\.2\\.0\\]: ${base}/compare/v1\\.1\\.0\\.\\.\\.v1\\.2\\.0\\n\\[1\\.1\\.0\\]:`));
  assert.deepEqual(check(result), []);
  assert.ok(result.endsWith('\n'));
});

test('release refuses to publish an empty, duplicate, older or invalid version', () => {
  assert.throws(() => release(changelog({ unreleased: '### Added\n\n### Fixed' }), '1.2.0'), /Nothing to release/);
  assert.throws(() => release(changelog({ unreleased: '' }), '1.2.0'), /Nothing to release/);
  assert.throws(() => release(changelog(), '1.1.0'), /already has a "## \[1\.1\.0\]" section/);
  assert.throws(() => release(changelog(), '1.0.5'), /must be newer than the latest release in CHANGELOG\.md, 1\.1\.0/);
  assert.throws(() => release(changelog(), 'v1.2.0'), /not a version/);
  assert.throws(() => release(changelog(), '1.2.0-beta.1'), /Pre-release/);
  assert.throws(() => release(changelog(), '1.2.0', { date: '2026-02-30' }), /not a date/);
});

test('release refuses to edit an inconsistent changelog', () => {
  const missing = changelog({ links: `[1.1.0]: ${base}/compare/v1.0.0...v1.1.0\n[1.0.0]: ${base}/releases/tag/v1.0.0` });
  assert.throws(() => release(missing, '1.2.0'), /Fix CHANGELOG\.md before releasing[\s\S]*\[Unreleased\]/);
});

test('notes returns a version section with the link definitions it uses', () => {
  assert.equal(notes(changelog(), '1.1.0'), `### Fixed\n\n- A fix. ([#2])\n\n[#2]: ${base}/pull/2\n`);
  assert.equal(notes(changelog(), '1.0.0'), 'First release.\n\n### Added\n\n- Everything.\n');
});

test('notes requires the version section unless pre-releases may use Unreleased', () => {
  assert.throws(() => notes(changelog(), '1.2.0'), /no "## \[1\.2\.0\]" section\. Run `make prepare-release VERSION=1\.2\.0`/);
  assert.equal(notes(changelog(), '1.2.0-beta.1', { allowUnreleased: true }),
    `### Added\n\n- New thing. ([#3])\n\n[#3]: ${base}/pull/3\n`);
  assert.equal(notes(changelog({ unreleased: '### Added' }), '1.2.0-beta.1', { allowUnreleased: true }), '');
  assert.equal(notes(changelog(), '1.1.0', { allowUnreleased: true }).startsWith('### Fixed'), true);
});

test('check reports structure, ordering, date and link problems', () => {
  const swap = text => text.replace(/## \[1\.1\.0\] - 2026-02-01\n\n### Fixed\n\n- A fix\. \(\[#2\]\)\n\n/, '')
    .replace('- Everything.\n', `- Everything.\n\n## [1.1.0] - 2026-02-01\n\n### Fixed\n\n- A fix. ([#2])\n`);
  const cases = [
    [changelog().replace('## [Unreleased]\n', ''), /first "## " section must be "## \[Unreleased\]"/],
    [changelog().replace('## [1.1.0] - 2026-02-01', '## [1.1.0]'), /needs a release date/],
    [changelog().replace('2026-02-01', '2026-13-01'), /invalid date "2026-13-01"/],
    [changelog().replace('2026-02-01', '2025-12-01'), /dated before "## \[1\.0\.0\]" \(2026-01-01\), which is listed below it/],
    [swap(changelog()), /"## \[1\.0\.0\]" is listed above the newer or equal "## \[1\.1\.0\]"/],
    [changelog().replace('- A fix. ([#2])', ''), /"## \[1\.1\.0\]" has no entries/],
    [changelog().replace(`[#3]: ${base}/pull/3`, ''), /"\[#3\]" is used in "## \[Unreleased\]" but has no link definition/],
    [changelog().replace(`[1.1.0]: ${base}/compare/v1.0.0...v1.1.0\n`, ''), /Add the link "\[1\.1\.0\]: .*compare\/v1\.0\.0\.\.\.v1\.1\.0"/],
    [changelog().replace('compare/v1.1.0...HEAD', 'compare/v1.0.0...HEAD'), /"\[Unreleased\]" link should be .*compare\/v1\.1\.0\.\.\.HEAD/],
    [changelog().replace('## [1.0.0]', '## [1.1.0]'), /appears more than once/],
  ];
  for (const [text, expected] of cases) {
    const problems = check(text);
    assert.ok(problems.some(problem => expected.test(problem)), `Expected ${expected} in:\n${problems.join('\n')}`);
  }
});

test('references inside code spans do not need link definitions', () => {
  assert.deepEqual(check(changelog({ unreleased: '### Added\n\n- Supports `[#9]` literally. ([#3])' })), []);
});

test('versions compare by semantic-version precedence', () => {
  const ordered = ['1.0.0-alpha', '1.0.0-alpha.1', '1.0.0-alpha.beta', '1.0.0-beta', '1.0.0-beta.2',
    '1.0.0-beta.11', '1.0.0-rc.1', '1.0.0', '1.0.1', '1.0.10', '1.1', '1.1.0.1', '2.0.0'];
  for (let i = 1; i < ordered.length; i++) {
    assert.equal(compareVersions(ordered[i - 1], ordered[i]), -1, `${ordered[i - 1]} < ${ordered[i]}`);
    assert.equal(compareVersions(ordered[i], ordered[i - 1]), 1, `${ordered[i]} > ${ordered[i - 1]}`);
  }
  assert.equal(compareVersions('1.1', '1.1.0'), 0);
});

test('cleanBody drops empty subsections and blank edges', () => {
  assert.deepEqual(cleanBody(['', '### Added', '', '### Fixed', '', '- Fix.', '', '### Removed', '']),
    ['### Fixed', '', '- Fix.']);
});

test('the CLI edits the file, prints notes and fails with a clear message', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'changelog-'));
  try {
    const file = path.join(dir, 'CHANGELOG.md');
    fs.writeFileSync(file, changelog());
    const run = (...args) => execFileSync(process.execPath, [script, ...args, '--file', file],
      { encoding: 'utf8', env: { ...process.env, GITHUB_ACTIONS: '' }, stdio: 'pipe' });
    assert.match(run('check'), /is consistent/);
    run('release', '1.2.0', '--date', '2026-03-04');
    assert.match(fs.readFileSync(file, 'utf8'), /## \[1\.2\.0\] - 2026-03-04/);
    assert.equal(run('notes', '1.2.0'), `### Added\n\n- New thing. ([#3])\n\n[#3]: ${base}/pull/3\n`);
    assert.throws(() => run('notes', '9.9.9'), error => /error: CHANGELOG\.md has no "## \[9\.9\.9\]"/.test(error.stderr));
    assert.throws(() => run('release'), error => /Usage:/.test(error.stderr));
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
