'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');
const { readLimits, checkOverlay, checkExport, evaluate, parseArguments, main } = require('./perf-guard.cjs');

const script = path.join(__dirname, 'perf-guard.cjs');
const limits = { fullWarmP95Ms: 100, damageWarmP95Ms: 10, firstDrawMaxMs: 2000, exportP95Ms: 5000 };
const environment = {
  PERF_OVERLAY_FULL_WARM_P95_MS: '100',
  PERF_OVERLAY_DAMAGE_WARM_P95_MS: '10',
  PERF_OVERLAY_FIRST_DRAW_MAX_MS: '2000',
  PERF_EXPORT_P95_MS: '5000',
};

function distribution(count, p95, max = p95) {
  return { count, p50_ms: p95 / 2, p95_ms: p95, max_ms: max, over_8_3ms: 0, over_16_7ms: 0, over_50ms: 0 };
}

// The shape OverlayDrawingBenchmark --summarize writes: three scenarios, a first-draw and a warm group each.
function overlaySummary({ drawMode = 'full', warmP95 = 20, firstMax = 300, warmCount = 600, firstCount = 5, tweak } = {}) {
  const groups = [];
  for (const scenario of ['area-cursor', 'area-selection', 'window-hover']) {
    groups.push({
      scenario, phase: 'fresh-process-first-draw', draw_mode: drawMode,
      update: distribution(firstCount, 1), draw: distribution(firstCount, 1),
      update_and_draw: distribution(firstCount, firstMax / 2),
      setup_update_and_draw: distribution(firstCount, firstMax, firstMax),
      view_setup: distribution(firstCount, 1),
      cpu_stalls_over_50ms_within_first_2s: 0,
    }, {
      scenario, phase: 'warm-draw', draw_mode: drawMode,
      update: distribution(warmCount, 1), draw: distribution(warmCount, warmP95 / 2),
      update_and_draw: distribution(warmCount, warmP95, warmP95 * 2),
      cpu_stalls_over_50ms_within_first_2s: 0,
    });
  }
  const summary = { measurement: 'offscreen synchronous CPU update/draw', groups };
  tweak?.(summary);
  return summary;
}

function exportReport({ p95 = 400, count = 30, reliable = true, source = 'synthetic', dpi = 144, scale = 2,
  profile = true, tweak } = {}) {
  const report = {
    measurement: 'synthetic styled render + PNG encode, CPU only; no screen pixels',
    frame: { width: 2880, height: 1800, source },
    backing_scale: scale, warm_iterations: count,
    render_and_encode: { count, min_ms: p95 / 2, p50_ms: p95 * 0.8, p95_ms: p95, max_ms: p95 * 1.2, p95_reliable: reliable },
    png: { bytes: 4_000_000, dpi, has_profile: profile },
  };
  tweak?.(report);
  return report;
}

test('accepts a run inside every limit', () => {
  const guard = evaluate({
    overlays: [{ label: 'full', summary: overlaySummary() },
      { label: 'damage', summary: overlaySummary({ drawMode: 'damage', warmP95: 1 }) }],
    exportReport: exportReport(), limits,
  });
  assert.equal(guard.passed, true);
  assert.deepEqual(guard.failures, []);
  assert.equal(guard.overlay.length, 12);
  assert.ok(guard.overlay.every(row => row.passed));
  assert.equal(guard.export.passed, true);
});

test('warm p95 is compared with the limit of the draw mode that produced it', () => {
  const slowDamage = checkOverlay(overlaySummary({ drawMode: 'damage', warmP95: 30 }), limits, 'damage');
  assert.equal(slowDamage.failures.length, 3);
  assert.match(slowDamage.failures[0], /damage area-cursor warm-draw: update_and_draw\.p95_ms 30 ms is over the 10 ms limit/);
  // The same 30 ms is fine when the whole canvas is redrawn each frame.
  assert.deepEqual(checkOverlay(overlaySummary({ drawMode: 'full', warmP95: 30 }), limits, 'full').failures, []);
  assert.equal(checkOverlay(overlaySummary({ drawMode: 'full', warmP95: 101 }), limits, 'full').failures.length, 3);
});

test('first draws are judged on their slowest process including view setup', () => {
  const result = checkOverlay(overlaySummary({ firstMax: 2500 }), limits, 'full');
  assert.equal(result.failures.length, 3);
  assert.match(result.failures[0], /full area-cursor fresh-process-first-draw: setup_update_and_draw\.max_ms 2500 ms is over the 2000 ms limit/);
  assert.ok(result.rows.filter(row => row.phase === 'warm-draw').every(row => row.passed));
});

test('a value exactly at the limit passes', () => {
  assert.deepEqual(checkOverlay(overlaySummary({ warmP95: 100, firstMax: 2000 }), limits, 'full').failures, []);
});

test('fails closed when a scenario or phase is missing or repeated', () => {
  const missing = overlaySummary({ tweak: summary => { summary.groups = summary.groups.filter(group => group.scenario !== 'window-hover'); } });
  const result = checkOverlay(missing, limits, 'full');
  assert.equal(result.failures.length, 2);
  assert.match(result.failures[0], /full window-hover fresh-process-first-draw: expected one group in the summary, found 0/);

  const repeated = overlaySummary({ tweak: summary => { summary.groups.push({ ...summary.groups[1] }); } });
  assert.match(checkOverlay(repeated, limits, 'full').failures[0], /area-cursor warm-draw: expected one group in the summary, found 2/);

  for (const summary of [null, {}, { groups: 'nope' }, { groups: [] }, []]) {
    assert.equal(checkOverlay(summary, limits, 'full').failures.length, 6);
  }
});

test('fails closed on missing, negative or non-numeric measurements', () => {
  for (const bad of [undefined, null, -1, 'fast', Number.NaN]) {
    const summary = overlaySummary({ tweak: s => { s.groups[1].update_and_draw.p95_ms = bad; s.groups[0].setup_update_and_draw.max_ms = bad; } });
    const { failures } = checkOverlay(summary, limits, 'full');
    assert.equal(failures.length, 2, `value ${String(bad)}`);
    assert.match(failures.join('\n'), /is missing or not a number/);
  }
  const noStats = overlaySummary({ tweak: s => { delete s.groups[1].update_and_draw; } });
  assert.match(checkOverlay(noStats, limits, 'full').failures[0], /update_and_draw\.p95_ms is missing/);
});

test('a p95 over too few samples does not count', () => {
  const few = checkOverlay(overlaySummary({ warmCount: 19 }), limits, 'full');
  assert.equal(few.failures.length, 3);
  assert.match(few.failures[0], /only 19 samples; at least 20 are needed/);
  assert.deepEqual(checkOverlay(overlaySummary({ warmCount: 20 }), limits, 'full').failures, []);
  assert.equal(checkOverlay(overlaySummary({ firstCount: 0 }), limits, 'full').failures.length, 3);
});

test('rejects an unknown draw mode instead of guessing its limit', () => {
  const missing = overlaySummary({ tweak: s => s.groups.forEach(group => { delete group.draw_mode; }) });
  const summaries = ['', 'partial', null, 'constructor', '<script>alert(1)</script>']
    .map(drawMode => overlaySummary({ drawMode })).concat(missing);
  for (const summary of summaries) {
    const { failures, rows } = checkOverlay(summary, limits, 'x');
    assert.equal(failures.length, 3, `draw_mode ${String(summary.groups[0].draw_mode)}`);
    assert.match(failures[0], /draw_mode must be "full" or "damage"/);
    assert.ok(failures.every(message => !message.includes('<')));
    assert.ok(rows.every(row => row.draw_mode === null));
  }
});

test('accepts a render and encode within the limit with a profile and the right density', () => {
  const result = checkExport(exportReport(), limits);
  assert.deepEqual(result.failures, []);
  assert.equal(result.summary.passed, true);
  assert.equal(result.summary.p95_ms, 400);
  assert.equal(checkExport(exportReport({ p95: 5000 }), limits).failures.length, 0);
});

test('flags a slow export, a non-synthetic frame, a thin sample, a wrong density and a missing profile', () => {
  assert.match(checkExport(exportReport({ p95: 5001 }), limits).failures[0], /p95 5001 ms is over the 5000 ms limit/);
  assert.match(checkExport(exportReport({ source: 'display' }), limits).failures[0], /synthetic frame, never screen pixels/);
  assert.match(checkExport(exportReport({ count: 19, reliable: false }), limits).failures[0], /only 19 samples/);
  assert.match(checkExport(exportReport({ reliable: false }), limits).failures[0], /at least 20 are needed/);
  assert.match(checkExport(exportReport({ dpi: 72 }), limits).failures[0], /density is not 72 x the backing scale/);
  assert.equal(checkExport(exportReport({ dpi: 72, scale: 1 }), limits).failures.length, 0);
  assert.match(checkExport(exportReport({ profile: false }), limits).failures[0], /no colour profile/);
});

test('fails closed on an export report with missing parts', () => {
  for (const report of [null, {}, { frame: { source: 'synthetic' } }]) {
    const { failures, summary } = checkExport(report, limits);
    assert.ok(failures.length >= 3);
    assert.equal(summary.passed, false);
  }
  const noTiming = exportReport({ tweak: r => { r.render_and_encode.p95_ms = 'slow'; } });
  assert.match(checkExport(noTiming, limits).failures[0], /must be non-negative numbers/);
});

test('fails closed on negative, non-finite or missing export timings', () => {
  for (const field of ['p50_ms', 'p95_ms', 'max_ms', 'count']) {
    for (const bad of [-1, Number.NaN, Number.POSITIVE_INFINITY, null, 'slow', undefined]) {
      const report = exportReport({ tweak: r => { r.render_and_encode[field] = bad; } });
      const { failures, summary } = checkExport(report, limits);
      assert.equal(summary.passed, false, `${field} ${String(bad)}`);
      assert.match(failures.join('\n'), /must be non-negative numbers/, `${field} ${String(bad)}`);
    }
  }
  assert.equal(checkExport(exportReport({ tweak: r => { r.render_and_encode.p50_ms = 0; } }), limits).summary.passed, true);
});

test('reads limits only from the environment and names every bad one', () => {
  assert.deepEqual(readLimits(environment), limits);
  assert.deepEqual(readLimits({ ...environment, PERF_EXPORT_P95_MS: ' 2500.5 ' }).exportP95Ms, 2500.5);
  const broken = { ...environment, PERF_EXPORT_P95_MS: '', PERF_OVERLAY_FULL_WARM_P95_MS: '0',
    PERF_OVERLAY_DAMAGE_WARM_P95_MS: '-5' };
  delete broken.PERF_OVERLAY_FIRST_DRAW_MAX_MS;
  assert.throws(() => readLimits(broken), error => {
    for (const name of ['PERF_EXPORT_P95_MS', 'PERF_OVERLAY_FULL_WARM_P95_MS', 'PERF_OVERLAY_DAMAGE_WARM_P95_MS',
      'PERF_OVERLAY_FIRST_DRAW_MAX_MS']) assert.match(error.message, new RegExp(name));
    return true;
  });
  for (const bad of ['abc', 'NaN', 'Infinity', '1e999']) {
    assert.throws(() => readLimits({ ...environment, PERF_EXPORT_P95_MS: bad }), /PERF_EXPORT_P95_MS/, bad);
  }
});

test('parses the command line and rejects what it does not know', () => {
  assert.deepEqual(parseArguments(['--overlay', 'full=a.json', '--overlay', 'damage=b=c.json', '--export', 'e.json',
    '--output', 'o.json', '--markdown', 'm.md']), {
    overlays: [{ label: 'full', path: 'a.json' }, { label: 'damage', path: 'b=c.json' }],
    exportPath: 'e.json', outputPath: 'o.json', markdownPath: 'm.md',
  });
  for (const argv of [[], ['--output', 'o.json'], ['--overlay'], ['--overlay', 'nolabel.json'], ['--overlay', '=a.json'],
    ['--overlay', 'full='], ['--export'], ['--bogus'], ['summary.json']]) {
    assert.throws(() => parseArguments(argv), /Usage:|needs a value|expects|Unknown/, JSON.stringify(argv));
  }
});

function run(argv, files, env = environment) {
  const written = {};
  const out = [];
  const err = [];
  const code = main(argv, {
    env,
    readFile: file => {
      if (!(file in files)) throw new Error('ENOENT');
      return files[file];
    },
    writeFile: (file, text) => { written[file] = text; },
    appendFile: (file, text) => { written[file] = (written[file] ?? '') + text; },
    stdout: text => out.push(text),
    stderr: text => err.push(text),
  });
  return { code, written, out: out.join(''), err: err.join('') };
}

test('exits 0 and writes the combined summary and a Markdown table when everything is inside its limits', () => {
  const files = { 'full.json': JSON.stringify(overlaySummary()), 'export.json': JSON.stringify(exportReport()) };
  const result = run(['--overlay', 'full=full.json', '--export', 'export.json', '--output', 'guard.json',
    '--markdown', 'step.md'], files);
  assert.equal(result.code, 0);
  assert.match(result.out, /All checks are within their limits/);
  assert.match(result.out, /\| full \| area-cursor \| warm-draw \| update_and_draw\.p95_ms \| 600 \| 20 \| 100 \|/);
  assert.ok(!result.out.includes('full (full)'));
  assert.equal(result.written['step.md'], result.out);
  const guard = JSON.parse(result.written['guard.json']);
  assert.deepEqual(Object.keys(guard), ['tool', 'passed', 'limits_ms', 'overlay', 'export', 'failures']);
  assert.equal(guard.passed, true);
  assert.deepEqual(guard.limits_ms, {
    overlay_full_warm_p95: 100, overlay_damage_warm_p95: 10, overlay_first_draw_max: 2000,
    export_render_and_encode_p95: 5000,
  });
  assert.deepEqual(Object.keys(guard.export),
    ['source', 'frame', 'backing_scale', 'warm_iterations', 'samples', 'p50_ms', 'p95_ms', 'max_ms', 'limit_ms', 'png', 'passed']);
});

test('exits 1 and says which measurement is over its limit', () => {
  const files = { 'damage.json': JSON.stringify(overlaySummary({ drawMode: 'damage', warmP95: 40 })) };
  const result = run(['--overlay', 'damage=damage.json', '--output', 'guard.json'], files);
  assert.equal(result.code, 1);
  assert.match(result.out, /Over a limit/);
  assert.match(result.out, /❌/);
  assert.match(result.out, /damage area-selection warm-draw: update_and_draw\.p95_ms 40 ms is over the 10 ms limit/);
  assert.equal(JSON.parse(result.written['guard.json']).passed, false);
  assert.equal(JSON.parse(result.written['guard.json']).export, null);
});

test('exits 2 for unreadable or malformed input and missing limits, without echoing file contents', () => {
  const files = { 'broken.json': '{"window_title": "Secret Plans.pdf"', 'ok.json': JSON.stringify(overlaySummary()) };
  const unreadable = run(['--overlay', 'full=missing.json'], files);
  assert.equal(unreadable.code, 2);
  assert.match(unreadable.err, /Cannot read missing\.json/);
  const malformed = run(['--overlay', 'full=broken.json'], files);
  assert.equal(malformed.code, 2);
  assert.match(malformed.err, /broken\.json is not valid JSON/);
  assert.ok(!malformed.err.includes('Secret'));
  const noLimits = run(['--overlay', 'full=ok.json'], files, {});
  assert.equal(noLimits.code, 2);
  assert.match(noLimits.err, /PERF_OVERLAY_FULL_WARM_P95_MS/);
  assert.equal(run([], files).code, 2);
  assert.deepEqual(Object.keys(unreadable.written), []);
});

test('the summary and report carry timings only, never other fields from the inputs', () => {
  const summary = overlaySummary({
    tweak: s => {
      s.groups[0].window_title = 'Secret Plans.pdf';
      s.groups[0].draw_mode = '<img src=x onerror=alert(1)>';
      s.window_titles = ['Secret Plans.pdf'];
    },
  });
  const report = exportReport({ tweak: r => { r.frame.title = 'Secret Plans.pdf'; r.png.path = '/Users/someone/Secret.png'; r.extra = 'Secret'; } });
  const result = run(['--overlay', 'full=s.json', '--export', 'e.json', '--output', 'guard.json'],
    { 's.json': JSON.stringify(summary), 'e.json': JSON.stringify(report) });
  for (const text of [result.out, result.written['guard.json']]) {
    assert.ok(!text.includes('Secret'));
    assert.ok(!text.includes('/Users/'));
    assert.ok(!text.includes('<img'));
  }
});

test('the report rounds to two decimals, shows the draw mode only when the label does not say it, and keeps the JSON exact', () => {
  const summary = overlaySummary({ warmP95: 19.234833000000002, firstMax: 139.9999 });
  summary.groups[1].update_and_draw.p95_ms = 19.234833000000002;
  const files = { 'a.json': JSON.stringify(summary), 'e.json': JSON.stringify(exportReport({ p95: 364.66000000000003 })) };
  const result = run(['--overlay', 'fast=a.json', '--export', 'e.json', '--output', 'guard.json'], files);
  assert.equal(result.code, 0);
  assert.match(result.out, /\| fast \(full\) \| area-cursor \| warm-draw \| update_and_draw\.p95_ms \| 600 \| 19\.23 \| 100 \|/);
  assert.match(result.out, /\| 2880x1800 synthetic \| 30 \| 291\.73 \| 364\.66 \| 5000 \| 144 \|/);
  assert.ok(!/\d\.\d{3,}/.test(result.out));
  const guard = JSON.parse(result.written['guard.json']);
  assert.equal(guard.overlay[1].value_ms, 19.234833000000002);
  assert.equal(guard.export.p95_ms, 364.66000000000003);
});

test('the command line entry point reads real files and signals failure through its exit code', () => {
  const result = spawnSync(process.execPath, [script, '--overlay', 'full=/nonexistent/summary.json'], {
    encoding: 'utf8', env: { ...process.env, ...environment }, timeout: 20000,
  });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /Cannot read \/nonexistent\/summary\.json/);
  const noLimits = spawnSync(process.execPath, [script, '--export', 'e.json'], {
    encoding: 'utf8', env: { PATH: process.env.PATH }, timeout: 20000,
  });
  assert.equal(noLimits.status, 2);
  assert.match(noLimits.stderr, /PERF_/);
});
