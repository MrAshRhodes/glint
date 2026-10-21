'use strict';

function issueNumbers(body, repository) {
  const text = (body ?? '')
    .replace(/<!--[\s\S]*?(?:-->|$)/g, '')
    .replace(/```[\s\S]*?(?:```|$)|~~~[\s\S]*?(?:~~~|$)/g, '')
    .replace(/`[^`]*`/g, '');
  const references = /\b(?:close[sd]?|fix(?:es|ed)?|resolve[sd]?):?\s+(?:#([1-9]\d*)|([\w.-]+\/[\w.-]+)#([1-9]\d*)|https:\/\/github\.com\/([\w.-]+\/[\w.-]+)\/issues\/([1-9]\d*))(?=$|[\s,;)]|\.(?!\d))/gi;
  const numbers = new Set();
  for (const match of text.matchAll(references)) {
    const target = match[2] ?? match[4] ?? repository;
    if (target.toLowerCase() !== repository.toLowerCase()) {
      throw new Error(`Link an issue in ${repository}, not ${target}.`);
    }
    const number = Number(match[1] ?? match[3] ?? match[5]);
    if (!Number.isSafeInteger(number)) throw new Error('The linked issue number is invalid.');
    numbers.add(number);
  }
  if (numbers.size === 0) {
    throw new Error('Add a closing reference such as "Fixes #123" to the PR description (outside comments or code), using a real issue in this repository.');
  }
  return [...numbers];
}

async function checkIssueLink({ github, context }) {
  const { owner, repo } = context.repo;
  // Read the current description, not a stale event payload after an edit or rerun.
  const { data: pull } = await github.rest.pulls.get({
    owner, repo, pull_number: context.issue.number,
  });
  const numbers = issueNumbers(pull.body, `${owner}/${repo}`);
  for (const number of numbers) {
    let issue;
    try {
      ({ data: issue } = await github.rest.issues.get({ owner, repo, issue_number: number }));
    } catch (error) {
      if (error.status === 404) throw new Error(`Issue #${number} does not exist in ${owner}/${repo}.`);
      throw error;
    }
    if (issue.pull_request) throw new Error(`#${number} is a pull request, not an issue.`);
  }
  return numbers;
}

module.exports = { issueNumbers, checkIssueLink };
