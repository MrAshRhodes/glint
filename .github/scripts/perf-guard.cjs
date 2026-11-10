'use strict';

const fs = require('node:fs');

// Tripwire for gross slowdowns in the two benchmarks CI can run without a screen or any permission: the offscreen
// overlay drawing benchmark (Scripts/benchmark-overlay.sh) and the synthetic render + encode export benchmark
// (ExportTimingTests, enabled by GLINT_EXPORT_BENCHMARK=1). It reads their timing summaries only, never pixels,
// window titles or captures. The limits come from the workflow environment, which is the one place they are set.
// They are deliberately loose: shared runners are noisy, so this catches an order-of-magnitude regression, not drift.

const SCENARIOS = ['area-cursor', 'area-selection', 'window-hover'];
const FIRST_DRAW = 'fresh-process-first-draw';
const WARM_DRAW = 'warm-draw';
// A p95 over fewer samples than this is just the maximum.
const MIN_SAMPLES_FOR_P95 = 20;
const LIMIT_VARIABLES = {
  fullWarmP95Ms: 'PERF_OVERLAY_FULL_WARM_P95_MS',
  damageWarmP95Ms: 'PERF_OVERLAY_DAMAGE_WARM_P95_MS',
  firstDrawMaxMs: 'PERF_OVERLAY_FIRST_DRAW_MAX_MS',
  exportP95Ms: 'PERF_EXPORT_P95_MS',
};
const USAGE = 'Usage: perf-guard.cjs [--overlay <label>=<summary.json>]... [--export <export.json>] '
  + '[--output <guard-summary.json>] [--markdown <file>]';

class UsageError extends Error {}

const isNumber = value => typeof value === 'number' && Number.isFinite(value);
// Untrusted text goes into the Markdown report and the failure list, so keep it short and plain.
const shown = value => String(value ?? '').replace(/[^\w .+-]/g, '?').slice(0, 40);
const knownDrawMode = value => (value === 'full' || value === 'damage' ? value : null);

function readLimits(env) {
  const limits = {};
  const invalid = [];
  for (const [key, variable] of Object.entries(LIMIT_VARIABLES)) {
    const text = env[variable];
    const value = typeof text === 'string' && text.trim() !== '' ? Number(text) : NaN;
    if (isNumber(value) && value > 0) limits[key] = value;
    else invalid.push(variable);
  }
  if (invalid.length > 0) {
    throw new UsageError(`Set ${invalid.join(', ')} to a positive number of milliseconds.`);
  }
  return limits;
}

function warmLimitFor(drawMode, limits) {
  if (drawMode === 'full') return limits.fullWarmP95Ms;
  if (drawMode === 'damage') return limits.damageWarmP95Ms;
  return undefined;
}

function checkOverlay(summary, limits, label) {
  const groups = Array.isArray(summary?.groups) ? summary.groups : [];
  const rows = [];
  const failures = [];
  for (const scenario of SCENARIOS) {
    for (const phase of [FIRST_DRAW, WARM_DRAW]) {
      const where = `${label} ${scenario} ${phase}`;
      const found = groups.filter(group => group?.scenario === scenario && group?.phase === phase);
      if (found.length !== 1) {
        failures.push(`${where}: expected one group in the summary, found ${found.length}.`);
        continue;
      }
      const [group] = found;
      const warm = phase === WARM_DRAW;
      // Drawing the whole canvas each frame and drawing only the damage rectangles have very different costs,
      // so each mode has its own warm limit.
      const warmLimit = warmLimitFor(group.draw_mode, limits);
      if (warm && warmLimit === undefined) {
        failures.push(`${where}: draw_mode must be "full" or "damage", found "${shown(group.draw_mode)}".`);
        continue;
      }
      // First draws are few (one per round), so a percentile would only be their maximum.
      const metric = warm ? 'update_and_draw.p95_ms' : 'setup_update_and_draw.max_ms';
      const stats = warm ? group.update_and_draw : group.setup_update_and_draw;
      const value = warm ? stats?.p95_ms : stats?.max_ms;
      const limit = warm ? warmLimit : limits.firstDrawMaxMs;
      const minimum = warm ? MIN_SAMPLES_FOR_P95 : 1;
      if (!isNumber(value) || value < 0 || !isNumber(stats?.count)) {
        failures.push(`${where}: ${metric} is missing or not a number.`);
        continue;
      }
      if (stats.count < minimum) {
        failures.push(`${where}: only ${stats.count} samples; at least ${minimum} are needed.`);
      }
      const passed = value <= limit;
      if (!passed) failures.push(`${where}: ${metric} ${value} ms is over the ${limit} ms limit.`);
      rows.push({
        source: label, scenario, phase, draw_mode: knownDrawMode(group.draw_mode),
        metric, samples: stats.count, value_ms: value, limit_ms: limit, passed,
      });
    }
  }
  return { rows, failures };
}

function pick(object, keys) {
  if (object === null || typeof object !== 'object') return null;
  return Object.fromEntries(keys.filter(key => key in object).map(key => [key, object[key]]));
}

function checkExport(report, limits, label = 'export') {
  const failures = [];
  const fail = message => failures.push(`${label}: ${message}`);
  const timing = report?.render_and_encode;
  const png = report?.png;
  if (report?.frame?.source !== 'synthetic') fail('the benchmark must render the synthetic frame, never screen pixels.');
  const isDuration = value => isNumber(value) && value >= 0;
  if (![timing?.p50_ms, timing?.p95_ms, timing?.max_ms].every(isDuration) || !isDuration(timing?.count)) {
    fail('render_and_encode p50_ms, p95_ms, max_ms and count must be non-negative numbers.');
  } else {
    if (timing.count < MIN_SAMPLES_FOR_P95 || timing.p95_reliable !== true) {
      fail(`only ${timing.count} samples; at least ${MIN_SAMPLES_FOR_P95} are needed for a p95.`);
    }
    if (timing.p95_ms > limits.exportP95Ms) {
      fail(`render + encode p95 ${timing.p95_ms} ms is over the ${limits.exportP95Ms} ms limit.`);
    }
  }
  if (!isNumber(png?.dpi) || !isNumber(report?.backing_scale)
    || Math.abs(png.dpi - 72 * report.backing_scale) > 0.1) {
    fail('the PNG density is not 72 x the backing scale.');
  }
  if (png?.has_profile !== true) fail('the PNG carries no colour profile.');
  const summary = {
    source: label,
    frame: pick(report?.frame, ['width', 'height', 'source']),
    backing_scale: report?.backing_scale ?? null,
    warm_iterations: report?.warm_iterations ?? null,
    samples: timing?.count ?? null,
    p50_ms: timing?.p50_ms ?? null,
    p95_ms: timing?.p95_ms ?? null,
    max_ms: timing?.max_ms ?? null,
    limit_ms: limits.exportP95Ms,
    png: pick(png, ['bytes', 'dpi', 'has_profile']),
    passed: failures.length === 0,
  };
  return { summary, failures };
}

// The report shows two decimals; the JSON summary keeps the measured values untouched.
const rounded = value => (isNumber(value) ? String(Math.round(value * 100) / 100) : shown(value));

function markdown(guard) {
  const lines = ['### Performance guard', '', guard.passed ? 'All checks are within their limits.' : '**Over a limit.**', ''];
  if (guard.overlay.length > 0) {
    lines.push('| Overlay drawing | Scenario | Phase | Metric | Samples | Value (ms) | Limit (ms) |',
      '| --- | --- | --- | --- | ---: | ---: | ---: |');
    for (const row of guard.overlay) {
      const mark = row.passed ? '' : ' ❌';
      const mode = row.draw_mode && row.draw_mode !== row.source ? ` (${row.draw_mode})` : '';
      lines.push(`| ${row.source}${mode} | ${row.scenario} | ${row.phase} | `
        + `${row.metric} | ${row.samples} | ${rounded(row.value_ms)}${mark} | ${rounded(row.limit_ms)} |`);
    }
    lines.push('');
  }
  if (guard.export) {
    const item = guard.export;
    lines.push('| Export | Frame | Samples | p50 (ms) | p95 (ms) | Limit (ms) | PNG dpi |',
      '| --- | --- | ---: | ---: | ---: | ---: | ---: |',
      `| render + encode | ${shown(item.frame?.width)}x${shown(item.frame?.height)} ${shown(item.frame?.source)} | `
      + `${shown(item.samples)} | ${rounded(item.p50_ms)} | ${rounded(item.p95_ms)}${item.passed ? '' : ' ❌'} | `
      + `${rounded(item.limit_ms)} | ${shown(item.png?.dpi)} |`, '');
  }
  if (guard.failures.length > 0) lines.push(...guard.failures.map(message => `- ${message}`), '');
  lines.push('These are offscreen CPU timings on a shared runner, not input-to-display latency.', '');
  return lines.join('\n');
}

function evaluate({ overlays, exportReport, limits }) {
  const failures = [];
  const overlay = [];
  for (const { label, summary } of overlays) {
    const result = checkOverlay(summary, limits, label);
    overlay.push(...result.rows);
    failures.push(...result.failures);
  }
  let exported = null;
  if (exportReport !== undefined) {
    const result = checkExport(exportReport, limits);
    exported = result.summary;
    failures.push(...result.failures);
  }
  return {
    tool: 'glint-perf-guard',
    passed: failures.length === 0,
    limits_ms: {
      overlay_full_warm_p95: limits.fullWarmP95Ms,
      overlay_damage_warm_p95: limits.damageWarmP95Ms,
      overlay_first_draw_max: limits.firstDrawMaxMs,
      export_render_and_encode_p95: limits.exportP95Ms,
    },
    overlay,
    export: exported,
    failures,
  };
}

function parseArguments(argv) {
  const options = { overlays: [] };
  const valueOf = (index, flag) => {
    if (index >= argv.length) throw new UsageError(`${flag} needs a value.\n${USAGE}`);
    return argv[index];
  };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag === '--overlay') {
      const value = valueOf(index += 1, flag);
      const split = value.indexOf('=');
      if (split <= 0 || split === value.length - 1) throw new UsageError(`--overlay expects <label>=<summary.json>.\n${USAGE}`);
      options.overlays.push({ label: value.slice(0, split), path: value.slice(split + 1) });
    } else if (flag === '--export') {
      options.exportPath = valueOf(index += 1, flag);
    } else if (flag === '--output') {
      options.outputPath = valueOf(index += 1, flag);
    } else if (flag === '--markdown') {
      options.markdownPath = valueOf(index += 1, flag);
    } else {
      throw new UsageError(`Unknown argument ${flag}.\n${USAGE}`);
    }
  }
  if (options.overlays.length === 0 && options.exportPath === undefined) {
    throw new UsageError(`Give at least one --overlay or --export input.\n${USAGE}`);
  }
  return options;
}

function main(argv, io = {}) {
  const env = io.env ?? process.env;
  const read = io.readFile ?? (path => fs.readFileSync(path, 'utf8'));
  const write = io.writeFile ?? ((path, text) => fs.writeFileSync(path, text));
  const append = io.appendFile ?? ((path, text) => fs.appendFileSync(path, text));
  const stdout = io.stdout ?? (text => process.stdout.write(text));
  const stderr = io.stderr ?? (text => process.stderr.write(text));
  const load = path => {
    let text;
    try {
      text = read(path);
    } catch {
      throw new UsageError(`Cannot read ${path}.`);
    }
    try {
      return JSON.parse(text);
    } catch {
      throw new UsageError(`${path} is not valid JSON.`);
    }
  };
  try {
    const options = parseArguments(argv);
    const limits = readLimits(env);
    const guard = evaluate({
      overlays: options.overlays.map(({ label, path }) => ({ label, summary: load(path) })),
      exportReport: options.exportPath === undefined ? undefined : load(options.exportPath),
      limits,
    });
    const report = markdown(guard);
    stdout(report);
    if (options.outputPath) write(options.outputPath, `${JSON.stringify(guard, null, 2)}\n`);
    if (options.markdownPath) append(options.markdownPath, report);
    return guard.passed ? 0 : 1;
  } catch (error) {
    if (!(error instanceof UsageError)) throw error;
    stderr(`${error.message}\n`);
    return 2;
  }
}

module.exports = { readLimits, checkOverlay, checkExport, evaluate, markdown, parseArguments, main };

if (require.main === module) process.exitCode = main(process.argv.slice(2));
