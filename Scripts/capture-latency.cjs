#!/usr/bin/env node
'use strict';

// Turns the signposts Glint emits (see "Capture, editor and export signposts" in CONTRIBUTING.md) into hotkey latency
// per scenario: the first capture of a process, warm captures, captures after a quiet period, and the first capture
// after a marker you supply, such as a wake from sleep or a display change. It reads the NDJSON that
// `log stream --signpost --style ndjson` prints for the `Capture` and `SelectionOverlay` categories.
//
// It reports durations and counts only: nothing else in a record, such as the process or image path, is copied into
// the report. It measures how long instrumented intervals took. It cannot say why they took that long, and an
// interval that ends at the first overlay draw ends at a CPU-side milestone, not when the frame reaches the screen.

const fs = require('node:fs');

const SUBSYSTEM = 'io.github.mrashrhodes.glint';
const OVERLAY_WINDOW_US = 10_000_000;
const RELIABLE_P95_COUNT = 20;
const RESERVED_SCENARIOS = new Set(['first', 'warm', 'idle']);
const DEFAULTS = Object.freeze({ idleSeconds: 60, penaltyMs: 20, markerWindowSeconds: 600 });

const METRICS = [
  ['event_age_ms', 'key event to hotkey callback'],
  ['main_queue_ms', 'callback to main actor (QueueDelay)'],
  ['dispatch_ms', 'key event to main actor'],
  ['startup_ms', 'main actor to first overlay frame'],
  ['first_frame_ms', 'key event to first overlay frame'],
];

const USAGE = `Usage: node Scripts/capture-latency.cjs [options] TRACE.ndjson [TRACE.ndjson ...]
Reads the NDJSON of \`log stream --signpost --style ndjson\` for Glint's Capture and SelectionOverlay signposts
(- reads standard input) and reports hotkey latency per scenario.
  --idle-seconds N           quiet time before a capture counts as idle (default ${DEFAULTS.idleSeconds})
  --marker NAME=TIME         report the first capture after TIME under NAME, e.g. wake=2026-11-10T18:20:00+01:00;
                             repeat it for every event (TIME also accepts the log's "2026-11-10 18:20:00.5+0100")
  --marker-window-seconds N  how long after a marker its first capture still counts (default ${DEFAULTS.markerWindowSeconds})
  --penalty-ms N             flag a scenario whose p50, or reliable p95, is more than N ms over warm (default ${DEFAULTS.penaltyMs})
  --json                     print the report as JSON instead of a table`;

class UsageError extends Error {}

const round2 = value => Math.round(value * 100) / 100;

const TIMESTAMP = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?\s?(Z|[+-]\d{2}(?::?\d{2})?)$/;

// Microseconds since the epoch, or null when the text is not a timestamp. The log prints local time with a numeric
// offset ("2026-11-10 16:50:58.626671+0100"), which is also what a marker may use.
function parseTimestamp(text) {
  const match = typeof text === 'string' ? TIMESTAMP.exec(text.trim()) : null;
  if (!match) return null;
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number);
  const zone = match[8];
  const sign = zone.startsWith('-') ? -1 : 1;
  const digits = zone === 'Z' ? '' : zone.slice(1).replace(':', '');
  const offsetHours = digits === '' ? 0 : Number(digits.slice(0, 2));
  const offsetMinutes = digits.length > 2 ? Number(digits.slice(2)) : 0;
  if (hour > 23 || minute > 59 || second > 59 || offsetHours > 23 || offsetMinutes > 59) return null;
  const milliseconds = Date.UTC(year, month - 1, day, hour, minute, second);
  const date = new Date(milliseconds);
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return null;
  const microseconds = Number(`${match[7] ?? ''}000000`.slice(0, 6));
  return (milliseconds / 1000 - sign * (offsetHours * 60 + offsetMinutes) * 60) * 1_000_000 + microseconds;
}

function outcomeOf(message) {
  if (message === '') return 'completed';
  return message === 'cancelled' || message === 'failed' ? message : 'other';
}

// The begin and end records of Glint's signposts; everything else the collector prints (its header, other
// subsystems, point events) is ignored and counted.
function parseRecords(texts) {
  const records = [];
  const seen = new Set();
  let ignored = 0;
  for (const text of texts) {
    for (const line of text.split('\n')) {
      if (line.trim() === '') continue;
      let raw;
      try {
        raw = JSON.parse(line);
      } catch {
        ignored += 1;
        continue;
      }
      const atUs = raw && typeof raw === 'object' ? parseTimestamp(raw.timestamp) : null;
      const usable = atUs !== null
        && raw.eventType === 'signpostEvent'
        && raw.subsystem === SUBSYSTEM
        && (raw.signpostType === 'begin' || raw.signpostType === 'end')
        && typeof raw.signpostName === 'string'
        && Number.isFinite(raw.processID)
        && Number.isFinite(raw.signpostID);
      if (!usable) {
        ignored += 1;
        continue;
      }
      const key = `${raw.processID}:${raw.signpostID}:${raw.signpostName}:${raw.signpostType}:${atUs}`;
      if (seen.has(key)) continue;
      seen.add(key);
      records.push({
        pid: raw.processID,
        id: raw.signpostID,
        name: raw.signpostName,
        kind: raw.signpostType,
        category: typeof raw.category === 'string' ? raw.category : '',
        message: typeof raw.eventMessage === 'string' ? raw.eventMessage : '',
        atUs,
        sequence: records.length,
      });
    }
  }
  return { records, ignored };
}

// Begin and end records are paired by process, signpost ID and name. An interval that never ended, or an end with
// no begin (the collector started mid-interval), is counted and dropped. `activity` lists, per process, when any
// Glint signpost was recorded, which is what "quiet" is measured against.
function pairIntervals(records) {
  const ordered = [...records].sort((a, b) => a.atUs - b.atUs || a.sequence - b.sequence);
  const open = new Map();
  const activity = new Map();
  const intervals = [];
  let unfinished = 0;
  let orphanEnds = 0;
  for (const record of ordered) {
    if (!activity.has(record.pid)) activity.set(record.pid, []);
    activity.get(record.pid).push(record.atUs);
    const key = `${record.pid}:${record.id}:${record.name}`;
    if (record.kind === 'begin') {
      if (open.has(key)) unfinished += 1;
      open.set(key, record);
      continue;
    }
    const begin = open.get(key);
    if (!begin) {
      orphanEnds += 1;
      continue;
    }
    open.delete(key);
    intervals.push({
      name: record.name,
      category: begin.category,
      pid: record.pid,
      beginUs: begin.atUs,
      endUs: record.atUs,
      beginMessage: begin.message,
      outcome: outcomeOf(record.message),
    });
  }
  return { intervals, unfinished: unfinished + open.size, orphanEnds, activity };
}

// The latest time in `times` (ascending) that is strictly before `limit`, or null.
function latestBefore(times, limit) {
  let low = 0;
  let high = times.length;
  while (low < high) {
    const middle = (low + high) >> 1;
    if (times[middle] < limit) low = middle + 1;
    else high = middle;
  }
  return low === 0 ? null : times[low - 1];
}

const byBegin = (a, b) => a.beginUs - b.beginUs;

// One capture per QueueDelay interval: a global hotkey's callback to the main actor handling it. `eventAgeMs` on
// its begin is how long the key event had already existed, so the key press itself happened that long before.
function buildCaptures(intervals, activity, options) {
  const queues = intervals.filter(i => i.name === 'QueueDelay' && i.category === 'Capture').sort(byBegin);
  const overlays = intervals.filter(i => i.name === 'OverlayFirstDraw').sort(byBegin);
  const excluded = { invalid_event_age: 0, queue_delay_not_completed: 0 };
  const firstFrame = { no_overlay: 0, overlay_not_completed: 0 };
  const captures = [];
  const nextQueueBegin = new Map();
  const following = new Map();
  for (let index = queues.length - 1; index >= 0; index -= 1) {
    nextQueueBegin.set(queues[index], following.get(queues[index].pid) ?? Infinity);
    following.set(queues[index].pid, queues[index].beginUs);
  }
  for (const queue of queues) {
    if (queue.outcome !== 'completed') {
      excluded.queue_delay_not_completed += 1;
      continue;
    }
    const age = /^eventAgeMs=(\d+(?:\.\d+)?)$/.exec(queue.beginMessage);
    if (!age) {
      excluded.invalid_event_age += 1;
      continue;
    }
    const eventAgeUs = Math.round(Number(age[1]) * 1000);
    const eventUs = queue.beginUs - eventAgeUs;
    const mainQueueUs = queue.endUs - queue.beginUs;
    const capture = {
      eventUs,
      event_age_ms: eventAgeUs / 1000,
      main_queue_ms: mainQueueUs / 1000,
      dispatch_ms: (eventAgeUs + mainQueueUs) / 1000,
    };
    const horizon = Math.min(nextQueueBegin.get(queue), queue.endUs + OVERLAY_WINDOW_US);
    const candidates = overlays.filter(o => o.pid === queue.pid && o.beginUs >= queue.beginUs && o.beginUs < horizon);
    const completed = candidates.filter(o => o.outcome === 'completed');
    if (completed.length > 0) {
      const frameUs = Math.min(...completed.map(o => o.endUs));
      capture.startup_ms = (frameUs - queue.endUs) / 1000;
      capture.first_frame_ms = (frameUs - eventUs) / 1000;
    } else if (candidates.length > 0) {
      firstFrame.overlay_not_completed += 1;
    } else {
      firstFrame.no_overlay += 1;
    }

    const lastActivity = latestBefore(activity.get(queue.pid) ?? [], eventUs);
    if (lastActivity === null) capture.scenario = 'first';
    else capture.scenario = eventUs - lastActivity >= options.idleSeconds * 1_000_000 ? 'idle' : 'warm';
    captures.push(capture);
  }
  captures.sort((a, b) => a.eventUs - b.eventUs);
  return { captures, excluded, firstFrame };
}

// A marker claims the first capture that follows it, within the window. When several markers precede the same
// capture the latest one names it, and the others are reported as unused.
function applyMarkers(captures, markers, windowSeconds) {
  const ordered = [...markers].sort((a, b) => a.atUs - b.atUs);
  const used = new Set();
  let next = 0;
  let pending = [];
  for (const capture of captures) {
    while (next < ordered.length && ordered[next].atUs <= capture.eventUs) pending.push(ordered[next++]);
    pending = pending.filter(marker => capture.eventUs - marker.atUs <= windowSeconds * 1_000_000);
    if (pending.length === 0) continue;
    const marker = pending[pending.length - 1];
    capture.scenario = marker.name;
    used.add(marker);
    pending = [];
  }
  return markers.filter(marker => !used.has(marker)).map(marker => marker.raw);
}

// Nearest-rank percentiles, the method Scripts/benchmark-overlay.sh and `Glint --diagnose --timing` use. Below 20
// samples the p95 is only the maximum, so it is marked unreliable.
function summarize(valuesMs) {
  const sorted = valuesMs.filter(Number.isFinite).sort((a, b) => a - b);
  if (sorted.length === 0) return null;
  const at = percent => sorted[Math.max(1, Math.ceil((percent * sorted.length) / 100)) - 1];
  return {
    count: sorted.length,
    min_ms: round2(sorted[0]),
    p50_ms: round2(at(50)),
    p95_ms: round2(at(95)),
    max_ms: round2(sorted[sorted.length - 1]),
    p95_reliable: sorted.length >= RELIABLE_P95_COUNT,
  };
}

function compareWithWarm(summary, warm, penaltyMs) {
  if (!summary || !warm) return null;
  const p50 = round2(summary.p50_ms - warm.p50_ms);
  const p95 = summary.p95_reliable && warm.p95_reliable ? round2(summary.p95_ms - warm.p95_ms) : null;
  return { p50_ms: p50, p95_ms: p95, investigate: p50 > penaltyMs || (p95 !== null && p95 > penaltyMs) };
}

function analyze(texts, markers = [], settings = {}) {
  const options = { ...DEFAULTS, ...settings };
  const { records, ignored } = parseRecords(texts);
  const { intervals, unfinished, orphanEnds, activity } = pairIntervals(records);
  const { captures, excluded, firstFrame } = buildCaptures(intervals, activity, options);
  const unusedMarkers = applyMarkers(captures, markers, options.markerWindowSeconds);

  const names = ['first', 'warm', 'idle', ...new Set(markers.map(marker => marker.name))];
  const summaries = new Map(names.map(name => {
    const inScenario = captures.filter(capture => capture.scenario === name);
    const metrics = Object.fromEntries(METRICS.map(([key]) => [key, summarize(inScenario.map(capture => capture[key]).filter(v => v !== undefined))]));
    return [name, { scenario: name, captures: inScenario.length, metrics }];
  }));
  const warm = summaries.get('warm');
  const investigate = [];
  const scenarios = [];
  for (const scenario of summaries.values()) {
    if (scenario.captures === 0) continue;
    if (scenario.scenario === 'warm' || warm.captures === 0) {
      scenario.versus_warm = null;
    } else {
      scenario.versus_warm = Object.fromEntries(METRICS.map(([key]) => [key, compareWithWarm(scenario.metrics[key], warm.metrics[key], options.penaltyMs)]));
      for (const [key] of METRICS) {
        if (scenario.versus_warm[key]?.investigate) investigate.push(`${scenario.scenario}/${key}`);
      }
    }
    scenarios.push(scenario);
  }
  return {
    schema_version: 1,
    measurement: 'Hotkey latency from Glint signposts, durations only. These are CPU-side milestones, not on-screen presentation, and they do not show why a capture was slow.',
    options: {
      idle_seconds: options.idleSeconds,
      penalty_ms: options.penaltyMs,
      marker_window_seconds: options.markerWindowSeconds,
      markers: [...new Set(markers.map(marker => marker.name))],
    },
    input: { intervals: intervals.length, unfinished, orphan_ends: orphanEnds, ignored_lines: ignored },
    hotkey_captures: captures.length,
    excluded,
    first_frame: firstFrame,
    scenarios,
    investigate,
    unused_markers: unusedMarkers,
  };
}

const signed = value => `${value > 0 ? '+' : ''}${value}`;

function render(report) {
  const overWarm = value => `${signed(value)}${value > report.options.penalty_ms ? ' (investigate)' : ''}`;
  const rows = [];
  for (const scenario of report.scenarios) {
    for (const [key, label] of METRICS) {
      const summary = scenario.metrics[key];
      if (!summary) continue;
      const versus = scenario.versus_warm?.[key];
      const p50 = versus ? overWarm(versus.p50_ms) : '';
      const p95 = versus && versus.p95_ms !== null ? overWarm(versus.p95_ms) : '';
      rows.push(`| ${scenario.scenario} | ${label} | ${summary.count} | ${summary.p50_ms} | ${summary.p95_ms}${summary.p95_reliable ? '' : ' (max)'} | ${p50} | ${p95} |`);
    }
  }
  const lines = [
    '### Hotkey latency by scenario',
    '',
    '| Scenario | Metric | Samples | p50 (ms) | p95 (ms) | p50 over warm | p95 over warm |',
    '| --- | --- | ---: | ---: | ---: | ---: | ---: |',
    ...rows,
    '',
    `${report.hotkey_captures} hotkey capture(s). ${report.input.intervals} intervals, ${report.input.unfinished} unfinished, ${report.input.orphan_ends} ended without a begin, ${report.input.ignored_lines} other line(s) ignored.`,
  ];
  const problems = Object.entries({ ...report.excluded, ...report.first_frame }).filter(([, count]) => count > 0);
  if (problems.length > 0) lines.push(`Left out: ${problems.map(([name, count]) => `${name.replaceAll('_', ' ')} ${count}`).join(', ')}.`);
  if (report.unused_markers.length > 0) lines.push(`Markers that matched no capture: ${report.unused_markers.join(', ')}.`);
  if (report.investigate.length > 0) {
    lines.push(`Over ${report.options.penalty_ms} ms against warm (the issue's initial diagnostic threshold, not a result): ${report.investigate.join(', ')}.`);
  }
  lines.push(
    'A p95 over fewer than 20 samples is only the maximum. "Key event" is the callback time minus `eventAgeMs`, on Carbon\'s clock.',
    report.measurement,
    '',
  );
  return lines.join('\n');
}

function parseArguments(argv) {
  const options = { files: [], markers: [], settings: {}, json: false };
  const valueOf = (index, flag) => {
    if (index >= argv.length) throw new UsageError(`${flag} needs a value.\n${USAGE}`);
    return argv[index];
  };
  const numberOf = (index, flag, minimum, inclusive) => {
    const value = valueOf(index, flag);
    const number = /^\d+(?:\.\d+)?$/.test(value) ? Number(value) : NaN;
    if (!(inclusive ? number >= minimum : number > minimum)) {
      throw new UsageError(`${flag} needs a number ${inclusive ? 'from' : 'above'} ${minimum}.\n${USAGE}`);
    }
    return number;
  };
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag === '--help' || flag === '-h') {
      options.help = true;
    } else if (flag === '--json') {
      options.json = true;
    } else if (flag === '--idle-seconds') {
      options.settings.idleSeconds = numberOf(index += 1, flag, 0, false);
    } else if (flag === '--marker-window-seconds') {
      options.settings.markerWindowSeconds = numberOf(index += 1, flag, 0, false);
    } else if (flag === '--penalty-ms') {
      options.settings.penaltyMs = numberOf(index += 1, flag, 0, true);
    } else if (flag === '--marker') {
      const value = valueOf(index += 1, flag);
      const split = value.indexOf('=');
      const name = value.slice(0, split);
      const atUs = split > 0 ? parseTimestamp(value.slice(split + 1)) : null;
      if (!/^[a-z][a-z0-9_-]{0,31}$/.test(name) || RESERVED_SCENARIOS.has(name) || atUs === null) {
        throw new UsageError(`--marker expects NAME=TIME with a lowercase name other than first, warm or idle, and a time like 2026-11-10T18:20:00+01:00.\n${USAGE}`);
      }
      options.markers.push({ name, atUs, raw: value });
    } else if (flag === '-' || !flag.startsWith('-')) {
      options.files.push(flag);
    } else {
      throw new UsageError(`Unknown argument ${flag}.\n${USAGE}`);
    }
  }
  if (!options.help && options.files.length === 0) throw new UsageError(`Give at least one trace file, or - for standard input.\n${USAGE}`);
  return options;
}

function main(argv, io = {}) {
  const read = io.readFile ?? (path => fs.readFileSync(path, 'utf8'));
  const readStdin = io.readStdin ?? (() => fs.readFileSync(0, 'utf8'));
  const stdout = io.stdout ?? (text => process.stdout.write(text));
  const stderr = io.stderr ?? (text => process.stderr.write(text));
  try {
    const options = parseArguments(argv);
    if (options.help) {
      stdout(`${USAGE}\n`);
      return 0;
    }
    const texts = options.files.map(file => {
      try {
        return file === '-' ? readStdin() : read(file);
      } catch {
        throw new UsageError(file === '-' ? 'Cannot read standard input.' : `Cannot read ${file}.`);
      }
    });
    const report = analyze(texts, options.markers, options.settings);
    stdout(options.json ? `${JSON.stringify(report, null, 2)}\n` : render(report));
    if (report.hotkey_captures === 0) {
      stderr('No hotkey captures to report: the trace needs the Capture and SelectionOverlay signposts of a capture started with the hotkey (menu and URL captures have no QueueDelay).\n');
      return 1;
    }
    return 0;
  } catch (error) {
    if (!(error instanceof UsageError)) throw error;
    stderr(`${error.message}\n`);
    return 2;
  }
}

module.exports = { parseTimestamp, parseRecords, pairIntervals, buildCaptures, applyMarkers, summarize, analyze, render, parseArguments, main };

if (require.main === module) process.exitCode = main(process.argv.slice(2));
