#!/usr/bin/env node
'use strict';

// Keeps CHANGELOG.md (Keep a Changelog format) consistent with releases.
//
//   changelog.cjs check                               validate structure, order, dates and links
//   changelog.cjs release <version> [--date Y-M-D]    move [Unreleased] entries under a new version
//   changelog.cjs notes <version> [--allow-unreleased] print a version's entries for release notes
//
// Every command accepts --file <path> (default: CHANGELOG.md at the repository root).

const fs = require('node:fs');
const path = require('node:path');

// Same pattern as the release workflow's tag check.
const VERSION_RE = /^[0-9]+(\.[0-9]+){1,3}(-[0-9A-Za-z.-]+)?$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const SECTION_RE = /^## \[([^\]]+)\](?: - (\S+))?\s*$/;
const LINK_DEF_RE = /^\[([^\]]+)\]:\s+(\S+)\s*$/;
const UNRELEASED_LINK_RE = /^(https:\/\/github\.com\/[\w.-]+\/[\w.-]+)\/compare\/(\S+)\.\.\.HEAD$/;
const REFERENCE_RE = /\[([^\][]+)\](?![([:])/g;
const UNRELEASED = 'Unreleased';

function parse(text) {
  const lines = text.replace(/\r\n/g, '\n').split('\n');
  const defs = new Map();
  let defsStart = lines.length;
  for (let i = lines.length - 1; i >= 0; i--) {
    if (lines[i].trim() === '' || LINK_DEF_RE.test(lines[i])) defsStart = i;
    else break;
  }
  lines.forEach((line, index) => {
    const match = LINK_DEF_RE.exec(line);
    if (match) defs.set(match[1].toLowerCase(), { label: match[1], url: match[2], index });
  });
  const sections = [];
  lines.forEach((line, index) => {
    const match = index < defsStart && SECTION_RE.exec(line);
    if (match) sections.push({ label: match[1], date: match[2] ?? null, index });
  });
  sections.forEach((section, i) => {
    section.end = i + 1 < sections.length ? sections[i + 1].index : defsStart;
    section.body = lines.slice(section.index + 1, section.end);
  });
  return { lines, defs, defsStart, sections };
}

// Drops empty "### Added"-style subsections and surrounding blank lines.
function cleanBody(body) {
  const out = [];
  for (let i = 0; i < body.length; i++) {
    if (/^### /.test(body[i])) {
      let next = i + 1;
      while (next < body.length && body[next].trim() === '') next++;
      if (next === body.length || /^#{1,3} /.test(body[next])) {
        i = next - 1;
        continue;
      }
    }
    out.push(body[i]);
  }
  while (out.length && out[0].trim() === '') out.shift();
  while (out.length && out[out.length - 1].trim() === '') out.pop();
  return out.filter((line, i) => !(line.trim() === '' && out[i - 1]?.trim() === ''));
}

function parseVersion(version) {
  const [core, pre] = version.split(/-(.*)/s);
  return { core: core.split('.').map(Number), pre: pre ? pre.split('.') : [] };
}

// Semantic-version ordering, allowing the 2-4 numeric parts the release workflow accepts.
function compareVersions(a, b) {
  const x = parseVersion(a);
  const y = parseVersion(b);
  for (let i = 0; i < 4; i++) {
    const diff = (x.core[i] ?? 0) - (y.core[i] ?? 0);
    if (diff !== 0) return Math.sign(diff);
  }
  if (!x.pre.length || !y.pre.length) return Math.sign(y.pre.length - x.pre.length);
  for (let i = 0; i < Math.max(x.pre.length, y.pre.length); i++) {
    const [p, q] = [x.pre[i], y.pre[i]];
    if (p === undefined || q === undefined) return p === undefined ? -1 : 1;
    if (p === q) continue;
    const [pn, qn] = [/^\d+$/.test(p), /^\d+$/.test(q)];
    if (pn && qn) return Math.sign(Number(p) - Number(q));
    if (pn !== qn) return pn ? -1 : 1;
    return p < q ? -1 : 1;
  }
  return 0;
}

function isValidDate(date) {
  if (!DATE_RE.test(date)) return false;
  const parsed = new Date(`${date}T00:00:00Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().startsWith(date);
}

function localDate(now = new Date()) {
  const pad = number => String(number).padStart(2, '0');
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

function repositoryBase(defs) {
  const match = UNRELEASED_LINK_RE.exec(defs.get(UNRELEASED.toLowerCase())?.url ?? '');
  return match ? { base: match[1], previous: match[2] } : null;
}

// Returns a list of problems; an empty list means the changelog is consistent.
function check(text) {
  const { defs, sections } = parse(text);
  const problems = [];
  if (sections[0]?.label !== UNRELEASED) {
    problems.push('The first "## " section must be "## [Unreleased]".');
  }
  if (sections.filter(section => section.label === UNRELEASED).length > 1) {
    problems.push('There is more than one "## [Unreleased]" section.');
  }
  const releases = sections.filter(section => section.label !== UNRELEASED);
  const seen = new Set();
  releases.forEach((section, i) => {
    const heading = `"## [${section.label}]"`;
    if (!VERSION_RE.test(section.label)) problems.push(`${heading} is not a version such as 1.2.3.`);
    if (seen.has(section.label)) problems.push(`${heading} appears more than once.`);
    seen.add(section.label);
    if (!section.date) problems.push(`${heading} needs a release date: "## [${section.label}] - YYYY-MM-DD".`);
    else if (!isValidDate(section.date)) problems.push(`${heading} has an invalid date "${section.date}"; use YYYY-MM-DD.`);
    if (cleanBody(section.body).length === 0) problems.push(`${heading} has no entries.`);
    const older = releases[i + 1];
    if (older && VERSION_RE.test(section.label) && VERSION_RE.test(older.label)
        && compareVersions(section.label, older.label) <= 0) {
      problems.push(`${heading} is listed above the newer or equal "## [${older.label}]"; list versions newest first.`);
    }
    if (older && section.date && older.date && isValidDate(section.date) && isValidDate(older.date)
        && section.date < older.date) {
      problems.push(`${heading} (${section.date}) is dated before "## [${older.label}]" (${older.date}), which is listed below it.`);
    }
  });

  const repo = repositoryBase(defs);
  if (!repo) {
    problems.push('Add a link such as "[Unreleased]: https://github.com/OWNER/REPO/compare/v1.2.3...HEAD".');
  } else {
    const expected = new Map();
    if (releases.length) expected.set(UNRELEASED, `${repo.base}/compare/v${releases[0].label}...HEAD`);
    releases.forEach((section, i) => {
      const older = releases[i + 1];
      expected.set(section.label, older
        ? `${repo.base}/compare/v${older.label}...v${section.label}`
        : `${repo.base}/releases/tag/v${section.label}`);
    });
    for (const [label, url] of expected) {
      const actual = defs.get(label.toLowerCase())?.url;
      if (actual === undefined) problems.push(`Add the link "[${label}]: ${url}".`);
      else if (actual !== url) problems.push(`The "[${label}]" link should be ${url}, not ${actual}.`);
    }
  }

  for (const section of sections) {
    for (const label of references(section.body)) {
      if (/^#\d+$/.test(label) && !defs.has(label.toLowerCase())) {
        problems.push(`"[${label}]" is used in "## [${section.label}]" but has no link definition.`);
      }
    }
  }
  return [...new Set(problems)];
}

function references(body) {
  const labels = new Set();
  for (const line of body) {
    for (const match of line.replace(/`[^`]*`/g, '').matchAll(REFERENCE_RE)) labels.add(match[1]);
  }
  return labels;
}

function assertValid(text, context) {
  const problems = check(text);
  if (problems.length) {
    throw new Error(`${context}:\n${problems.map(problem => `  - ${problem}`).join('\n')}`);
  }
}

// Moves the [Unreleased] entries into a new "## [version] - date" section and updates the links.
function release(text, version, { date = localDate() } = {}) {
  if (!VERSION_RE.test(version)) throw new Error(`"${version}" is not a version such as 1.2.3.`);
  if (version.includes('-')) {
    throw new Error(`Pre-release ${version} keeps its entries under [Unreleased]; release them with the final version.`);
  }
  if (!isValidDate(date)) throw new Error(`"${date}" is not a date in YYYY-MM-DD format.`);
  assertValid(text, 'Fix CHANGELOG.md before releasing');

  const { lines, defs, sections } = parse(text);
  const unreleased = sections[0];
  const latest = sections[1];
  if (sections.some(section => section.label === version)) {
    throw new Error(`CHANGELOG.md already has a "## [${version}]" section.`);
  }
  if (latest && compareVersions(version, latest.label) <= 0) {
    throw new Error(`${version} must be newer than the latest release in CHANGELOG.md, ${latest.label}.`);
  }
  const entries = cleanBody(unreleased.body);
  if (!entries.length) {
    throw new Error('Nothing to release: add entries under "## [Unreleased]" first.');
  }

  const { base } = repositoryBase(defs);
  const unreleasedLink = defs.get(UNRELEASED.toLowerCase());
  const versionLink = latest
    ? `${base}/compare/v${latest.label}...v${version}`
    : `${base}/releases/tag/v${version}`;
  const out = [
    ...lines.slice(0, unreleased.index + 1),
    '',
    `## [${version}] - ${date}`,
    '',
    ...entries,
    '',
    ...lines.slice(unreleased.end),
  ];
  if (unreleasedLink.index > unreleased.index && unreleasedLink.index < unreleased.end) {
    throw new Error('Move the "[Unreleased]" link definition out of the Unreleased section.');
  }
  const shift = unreleasedLink.index >= unreleased.end ? out.length - lines.length : 0;
  out.splice(unreleasedLink.index + shift, 1,
    `[${UNRELEASED}]: ${base}/compare/v${version}...HEAD`,
    `[${version}]: ${versionLink}`);
  const result = out.join('\n');
  assertValid(result, 'The updated changelog is inconsistent');
  return result;
}

// Returns a section's entries plus the link definitions they use, ready for GitHub release notes.
function notes(text, version, { allowUnreleased = false } = {}) {
  const { defs, sections } = parse(text);
  let section = sections.find(candidate => candidate.label === version);
  if (!section && allowUnreleased) section = sections.find(candidate => candidate.label === UNRELEASED);
  if (!section) {
    throw new Error(`CHANGELOG.md has no "## [${version}]" section. Run \`make prepare-release VERSION=${version}\`, `
      + `merge it to main, then tag that commit.`);
  }
  const body = cleanBody(section.body);
  if (!body.length) {
    if (section.label === UNRELEASED) return '';
    throw new Error(`"## [${section.label}]" in CHANGELOG.md has no entries.`);
  }
  const used = [...references(body)]
    .map(label => defs.get(label.toLowerCase()))
    .filter(Boolean)
    .sort((a, b) => a.index - b.index)
    .map(def => `[${def.label}]: ${def.url}`);
  return [...body, ...(used.length ? ['', ...used] : [])].join('\n') + '\n';
}

function main(argv) {
  const args = [...argv];
  const option = name => {
    const at = args.indexOf(name);
    if (at === -1) return undefined;
    const value = args[at + 1];
    if (value === undefined || value.startsWith('--')) throw new Error(`${name} needs a value.`);
    args.splice(at, 2);
    return value;
  };
  const flag = name => {
    const at = args.indexOf(name);
    if (at !== -1) args.splice(at, 1);
    return at !== -1;
  };
  const file = option('--file') ?? path.join(__dirname, '..', '..', 'CHANGELOG.md');
  const date = option('--date');
  const allowUnreleased = flag('--allow-unreleased');
  const [command, version, ...rest] = args;
  const usage = 'Usage: changelog.cjs check | release <version> [--date YYYY-MM-DD] '
    + '| notes <version> [--allow-unreleased]  [--file CHANGELOG.md]';
  if (rest.length || (command === 'check' ? version !== undefined : !version)) throw new Error(usage);
  const text = fs.readFileSync(file, 'utf8');

  switch (command) {
    case 'check': {
      assertValid(text, `${path.basename(file)} is inconsistent`);
      console.log(`${path.basename(file)} is consistent.`);
      break;
    }
    case 'release': {
      fs.writeFileSync(file, release(text, version, { date: date ?? localDate() }));
      console.log(`Moved the Unreleased entries in ${path.basename(file)} to ${version}.`);
      break;
    }
    case 'notes': {
      process.stdout.write(notes(text, version, { allowUnreleased }));
      break;
    }
    default:
      throw new Error(usage);
  }
}

if (require.main === module) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    if (process.env.GITHUB_ACTIONS === 'true') {
      // Workflow commands need newlines encoded to keep a multi-line annotation together.
      console.error(`::error file=CHANGELOG.md,title=Changelog::${error.message.replace(/%/g, '%25').replace(/\n/g, '%0A')}`);
    } else {
      console.error(`error: ${error.message}`);
    }
    process.exit(1);
  }
}

module.exports = { check, release, notes, compareVersions, cleanBody, localDate };
