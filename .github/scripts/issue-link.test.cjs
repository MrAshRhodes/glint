'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { issueNumbers, checkIssueLink } = require('./issue-link.cjs');
const repository = 'MrAshRhodes/glint';

test('accepts GitHub closing keywords and deduplicates references', () => {
  for (const keyword of ['close', 'closes', 'closed', 'fix', 'fixes', 'fixed', 'resolve', 'resolves', 'resolved']) {
    assert.deepEqual(issueNumbers(`${keyword.toUpperCase()} #12`, repository), [12]);
  }
  assert.deepEqual(issueNumbers('Fixes #12, resolves #34.\nCloses #12', repository), [12, 34]);
});

test('accepts same-repository qualified references and issue URLs', () => {
  assert.deepEqual(issueNumbers('Fixes mrashrhodes/GLINT#12', repository), [12]);
  assert.deepEqual(issueNumbers('Resolves https://github.com/MrAshRhodes/glint/issues/34', repository), [34]);
});

test('rejects missing, malformed, placeholder and non-closing references', () => {
  for (const body of [null, '', 'Related to #12', 'Fixes #<issue>', 'Fixes #0', 'Fixes #-1',
    'Fixes #1abc', 'Fixes #1.5', 'Fixes #99999999999999999999',
    'Fixes https://github.com/MrAshRhodes/glint/pull/12']) {
    assert.throws(() => issueNumbers(body, repository), `Expected an invalid reference: ${body}`);
  }
});

test('ignores examples inside comments and code', () => {
  for (const body of ['<!-- Fixes #12 -->', '<!-- Fixes #12',
    '```\nFixes #12\n```', '~~~\nFixes #12\n~~~', '`Fixes #12`']) {
    assert.throws(() => issueNumbers(body, repository));
  }
  assert.deepEqual(issueNumbers('<!-- Fixes #12 -->\nFixes #34', repository), [34]);
});

test('rejects cross-repository references', () => {
  for (const body of ['Fixes someone/else#12', 'Fixes https://github.com/someone/else/issues/12',
    'Fixes #1\nFixes someone/else#12']) {
    assert.throws(() => issueNumbers(body, repository), /Link an issue in MrAshRhodes\/glint/);
  }
});

function fixture(body, getIssue = async () => ({ data: { state: 'open' } })) {
  const calls = [];
  return {
    calls,
    context: {
      repo: { owner: 'MrAshRhodes', repo: 'glint' },
      issue: { number: 99 },
      payload: { pull_request: { body: 'Fixes #999' } },
    },
    github: {
      rest: {
        pulls: { get: async args => {
          assert.deepEqual(args, { owner: 'MrAshRhodes', repo: 'glint', pull_number: 99 });
          return { data: { body } };
        } },
        issues: { get: async args => {
          calls.push(args);
          return getIssue(args);
        } },
      },
    },
  };
}

test('validates every issue using the live description, not the event payload', async () => {
  const f = fixture('Fixes #1\nCloses #2\nFixes #1');
  assert.deepEqual(await checkIssueLink(f), [1, 2]);
  assert.deepEqual(f.calls, [1, 2].map(issue_number => ({
    owner: 'MrAshRhodes', repo: 'glint', issue_number,
  })));
});

test('fails if the live description no longer references an issue', async () => {
  const f = fixture('');
  await assert.rejects(checkIssueLink(f), /Add a closing reference/);
  assert.deepEqual(f.calls, []);
});

test('rejects PR numbers and nonexistent issues', async () => {
  await assert.rejects(checkIssueLink(fixture('Fixes #1', async () => ({
    data: { pull_request: { url: 'https://api.github.com/repos/MrAshRhodes/glint/pulls/1' } },
  }))), /pull request, not an issue/);
  await assert.rejects(checkIssueLink(fixture('Fixes #1', async () => {
    throw Object.assign(new Error('Not Found'), { status: 404 });
  })), /Issue #1 does not exist/);
});

test('allows follow-up changes tied to an existing closed issue', async () => {
  assert.deepEqual(await checkIssueLink(fixture('Fixes #1', async () => ({
    data: { state: 'closed' },
  }))), [1]);
});

test('does not hide API or permission errors', async () => {
  for (const status of [403, 429, 500]) {
    const error = Object.assign(new Error('API failure'), { status });
    await assert.rejects(checkIssueLink(fixture('Fixes #1', async () => { throw error; })),
      caught => caught === error);
  }
});
