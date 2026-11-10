'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { test } = require('node:test');
const {
  parseTimestamp, parseRecords, pairIntervals, buildCaptures, applyMarkers, summarize, analyze, render, parseArguments, main,
} = require('./capture-latency.cjs');

const script = path.join(__dirname, 'capture-latency.cjs');
const SUBSYSTEM = 'io.github.mrashrhodes.glint';
const PID = 31337;
// 2026-11-10 16:00:00 in the +0100 offset the log prints.
const START_US = Date.UTC(2026, 10, 10, 15, 0, 0) * 1000;
const PRIVATE_PATH = '/Users/someone/private-project/Glint.app/Contents/MacOS/Glint';

const ms = value => Math.round(value * 1000);
const seconds = value => value * 1_000_000;

// The log's own timestamp format, `us` microseconds after START_US.
function stamp(us) {
  const total = START_US + us;
  const wholeMs = Math.floor(total / 1000);
  const iso = new Date(wholeMs + 3_600_000).toISOString();
  return `${iso.slice(0, 10)} ${iso.slice(11, 19)}.${iso.slice(20, 23)}${String(total - wholeMs * 1000).padStart(3, '0')}+0100`;
}

// One line of `log stream --signpost --style ndjson`, including the image paths a real record carries.
function record({ kind, name, id, at, message = '', category = 'Capture', pid = PID, subsystem = SUBSYSTEM, eventType = 'signpostEvent' }) {
  return JSON.stringify({
    timezoneName: '',
    eventType,
    signpostID: id,
    signpostScope: 'process',
    source: null,
    formatString: message === '' ? '' : '%{public}s',
    userID: 501,
    activityIdentifier: 0,
    subsystem,
    category,
    threadID: 7,
    signpostType: kind,
    backtrace: { frames: [] },
    bootUUID: '',
    processImagePath: PRIVATE_PATH,
    senderImagePath: PRIVATE_PATH,
    timestamp: stamp(at),
    signpostName: name,
    machTimestamp: 1,
    eventMessage: message,
    processImageUUID: 'AAAAAAAA-0000-0000-0000-000000000000',
    traceID: 1,
    processID: pid,
    senderProgramCounter: 1,
    parentActivityIdentifier: 0,
  });
}

function interval(name, id, beginAt, endAt, { begin = '', end = '', category = 'Capture', pid = PID } = {}) {
  return [
    record({ kind: 'begin', name, id, at: beginAt, message: begin, category, pid }),
    record({ kind: 'end', name, id, at: endAt, message: end, category, pid }),
  ];
}

// A hotkey capture. The key was pressed at `key` microseconds, the callback ran `age` ms later, the main actor `queue`
// ms after that, and the overlay drew its first frame `frame` ms after the key press. The capture's last signpost, the
// end of CaptureTotal, is `hold` ms after the key press.
function hotkey(id, key, { age = 1, queue = 2, frame = 30, hold = frame + 10, pid = PID, ageText, queueEnd = '', overlay = true, overlayEnd = '' } = {}) {
  const callback = key + ms(age);
  const mainActor = callback + ms(queue);
  return [
    ...interval('QueueDelay', id, callback, mainActor, { begin: ageText ?? `eventAgeMs=${age.toFixed(3)}`, end: queueEnd, pid }),
    ...interval('CaptureTotal', id, mainActor, key + ms(hold), { begin: 'trigger=hotkey mode=area', end: 'cancelled', pid }),
    ...(overlay
      ? interval('OverlayFirstDraw', id, mainActor + ms(0.5), key + ms(frame), { category: 'SelectionOverlay', end: overlayEnd, pid })
      : []),
  ];
}

const trace = (...parts) => parts.flat().join('\n');
const scenario = (report, name) => report.scenarios.find(entry => entry.scenario === name);
const marker = (name, secondsAfterStart) => ({ name, atUs: START_US + seconds(secondsAfterStart), raw: `${name}@${secondsAfterStart}s` });

// Six hotkey captures in two processes: two first, three warm and one idle, each with a distinct first-frame time.
const SCENARIO_TRACE = trace(
  'Filtering the log data using "subsystem == \\"io.github.mrashrhodes.glint\\" AND category == \\"Capture\\""',
  hotkey(1, 0, { frame: 120 }),
  hotkey(2, seconds(10), { frame: 30 }),
  hotkey(6, seconds(20), { frame: 90, pid: 5151 }),
  // 59.999 s after the previous signpost of this process (the end of capture 2's CaptureTotal): still warm.
  hotkey(3, seconds(10) + ms(40) + ms(59_999), { frame: 32 }),
  // Exactly 60 s after capture 3's last signpost: idle.
  hotkey(4, seconds(10) + ms(40) + ms(59_999) + ms(42) + seconds(60), { frame: 70, age: 4, queue: 30 }),
  hotkey(5, seconds(135), { frame: 31 }),
);

// One process: a first capture, then warm captures 10 s apart, then idle captures 100 s apart.
function session(warmFrames, idleFrames) {
  let key = 0;
  let id = 1;
  const parts = [hotkey(id, key, { frame: 40 })];
  for (const frame of warmFrames) parts.push(hotkey(id += 1, key += seconds(10), { frame }));
  for (const frame of idleFrames) parts.push(hotkey(id += 1, key += seconds(100), { frame }));
  return trace(...parts);
}

const repeat = (count, value) => Array.from({ length: count }, () => value);

test('parseTimestamp reads the log format, ISO offsets and Z as epoch microseconds', () => {
  const instant = Date.UTC(2026, 10, 10, 15, 50, 58) * 1000;
  assert.equal(parseTimestamp('2026-11-10 16:50:58.626671+0100'), instant + 626_671);
  assert.equal(parseTimestamp('2026-11-10T16:50:58+01:00'), instant);
  assert.equal(parseTimestamp('2026-11-10T15:50:58Z'), instant);
  assert.equal(parseTimestamp('2026-11-10 10:50:58-0500'), instant);
  assert.equal(parseTimestamp('2026-11-10 16:50:58+01'), instant);
  assert.equal(parseTimestamp(' 2026-11-10 16:50:58.5 +0100 '), instant + 500_000);
  assert.equal(parseTimestamp('2026-11-10 16:50:58.000001+0100'), instant + 1);
  assert.equal(parseTimestamp('2026-11-10 16:50:58.123456789+0100'), instant + 123_456);

  // The hour repeats when the clocks go back; the numeric offset keeps the two readings one second apart.
  assert.equal(parseTimestamp('2026-10-25 02:00:00+0100') - parseTimestamp('2026-10-25 02:59:59+0200'), seconds(1));
});

test('parseTimestamp rejects text that is not a real time with an offset', () => {
  for (const text of [
    '2026-02-30 10:00:00+0100', '2026-13-01 10:00:00+0100', '2026-00-10 10:00:00+0100', '2026-11-00 10:00:00+0100',
    '2026-11-10 24:00:00+0100', '2026-11-10 10:60:00+0100', '2026-11-10 10:00:60+0100',
    '2026-11-10 10:00:00+2400', '2026-11-10 10:00:00+0160',
    '2026-11-10 10:00:00', '2026-11-10', '10:00:00+0100', 'yesterday', '', undefined, null, 42, {},
  ]) {
    assert.equal(parseTimestamp(text), null, String(text));
  }
});

test('parseRecords keeps only begin and end signposts of the Glint subsystem and copies nothing else', () => {
  const [begin, end] = interval('QueueDelay', 1, 0, 2000, { begin: 'eventAgeMs=1.000' });
  const withChange = change => JSON.stringify({ ...JSON.parse(begin), ...change });
  const { records, ignored } = parseRecords([[
    'Filtering the log data using "subsystem == \\"io.github.mrashrhodes.glint\\""',
    '',
    '   ',
    begin,
    '{"truncated": ',
    '[1, 2]',
    'null',
    end,
    record({ kind: 'begin', name: 'Other', id: 2, at: 0, subsystem: 'com.example.other' }),
    record({ kind: 'event', name: 'Point', id: 3, at: 0 }),
    record({ kind: 'begin', name: 'Log', id: 4, at: 0, eventType: 'logEvent' }),
    withChange({ timestamp: 'not a time' }),
    withChange({ processID: 'abc' }),
    withChange({ signpostID: undefined }),
    withChange({ signpostName: 7 }),
  ].join('\n')]);

  assert.equal(ignored, 11);
  assert.deepEqual(records.map(({ sequence, ...rest }) => rest), [
    { pid: PID, id: 1, name: 'QueueDelay', kind: 'begin', category: 'Capture', message: 'eventAgeMs=1.000', atUs: START_US },
    { pid: PID, id: 1, name: 'QueueDelay', kind: 'end', category: 'Capture', message: '', atUs: START_US + 2000 },
  ]);
  assert.doesNotMatch(JSON.stringify(records), /private-project|\/Users|Glint\.app/);
});

test('parseRecords drops a record that appears in more than one file', () => {
  const text = interval('QueueDelay', 1, 0, 2000, { begin: 'eventAgeMs=1.000' }).join('\n');
  const { records, ignored } = parseRecords([text, text]);
  assert.equal(records.length, 2);
  assert.equal(ignored, 0);
});

test('pairIntervals pairs by process, ID and name and counts what it cannot pair', () => {
  const { records } = parseRecords([[
    ...interval('Render', 1, 0, 100),
    ...interval('EncodePNG', 1, 0, 200),
    ...interval('Render', 1, 0, 300, { pid: 7 }),
    ...interval('QueueDelay', 5, 1000, 1000),
    record({ kind: 'end', name: 'Pasteboard', id: 9, at: 50 }),
    record({ kind: 'begin', name: 'Pasteboard', id: 10, at: 60 }),
    record({ kind: 'begin', name: 'Pasteboard', id: 10, at: 70 }),
    ...interval('Render', 2, 400, 500, { end: 'cancelled' }),
    ...interval('Render', 3, 400, 500, { end: 'failed' }),
    ...interval('Render', 4, 400, 500, { end: 'timeout' }),
  ].join('\n')]);
  const { intervals, unfinished, orphanEnds, activity } = pairIntervals(records);

  const described = intervals.map(i => `${i.name} pid ${i.pid}: ${i.endUs - i.beginUs} us ${i.outcome}`).sort();
  assert.deepEqual(described, [
    `EncodePNG pid ${PID}: 200 us completed`,
    `QueueDelay pid ${PID}: 0 us completed`,
    'Render pid 7: 300 us completed',
    `Render pid ${PID}: 100 us completed`,
    `Render pid ${PID}: 100 us cancelled`,
    `Render pid ${PID}: 100 us failed`,
    `Render pid ${PID}: 100 us other`,
  ].sort());
  assert.equal(orphanEnds, 1);
  assert.equal(unfinished, 2);
  assert.deepEqual(activity.get(PID).map(at => at - START_US), [0, 0, 50, 60, 70, 100, 200, 400, 400, 400, 500, 500, 500, 1000, 1000]);
  assert.deepEqual(activity.get(7).map(at => at - START_US), [0, 300]);
});

test('files given in any order give the same report', () => {
  const early = trace(hotkey(1, 0), hotkey(2, seconds(10)));
  const late = trace(hotkey(3, seconds(300)), hotkey(4, seconds(310)));
  assert.deepEqual(analyze([late, early]), analyze([early, late]));
  assert.deepEqual(analyze([early, early, late]), analyze([early, late]));
});

test('classifies hotkey captures as first, warm or idle per process', () => {
  const report = analyze([SCENARIO_TRACE]);

  assert.equal(report.hotkey_captures, 6);
  assert.deepEqual(report.scenarios.map(entry => [entry.scenario, entry.captures]), [['first', 2], ['warm', 3], ['idle', 1]]);
  assert.deepEqual(scenario(report, 'first').metrics.first_frame_ms,
    { count: 2, min_ms: 90, p50_ms: 90, p95_ms: 120, max_ms: 120, p95_reliable: false });
  assert.deepEqual(scenario(report, 'warm').metrics.first_frame_ms,
    { count: 3, min_ms: 30, p50_ms: 31, p95_ms: 32, max_ms: 32, p95_reliable: false });
  assert.deepEqual(scenario(report, 'idle').metrics.first_frame_ms,
    { count: 1, min_ms: 70, p50_ms: 70, p95_ms: 70, max_ms: 70, p95_reliable: false });
  assert.deepEqual(report.input, { intervals: 18, unfinished: 0, orphan_ends: 0, ignored_lines: 1 });
  assert.deepEqual(report.excluded, { invalid_event_age: 0, queue_delay_not_completed: 0 });
  assert.deepEqual(report.first_frame, { no_overlay: 0, overlay_not_completed: 0 });
});

test('computes event age, main-queue wait, dispatch, startup and first frame from the signposts', () => {
  const report = analyze([trace(hotkey(1, 0, { age: 3.5, queue: 2.25, frame: 41 }))]);
  const { metrics } = scenario(report, 'first');

  assert.equal(metrics.event_age_ms.p50_ms, 3.5);
  assert.equal(metrics.main_queue_ms.p50_ms, 2.25);
  assert.equal(metrics.dispatch_ms.p50_ms, 5.75);
  assert.equal(metrics.startup_ms.p50_ms, 35.25);
  assert.equal(metrics.first_frame_ms.p50_ms, 41);
});

test('measures the idle penalty against warm captures', () => {
  const report = analyze([SCENARIO_TRACE]);

  assert.deepEqual(scenario(report, 'warm').versus_warm, null);
  assert.deepEqual(scenario(report, 'idle').versus_warm, {
    event_age_ms: { p50_ms: 3, p95_ms: null, investigate: false },
    main_queue_ms: { p50_ms: 28, p95_ms: null, investigate: true },
    dispatch_ms: { p50_ms: 31, p95_ms: null, investigate: true },
    startup_ms: { p50_ms: 8, p95_ms: null, investigate: false },
    first_frame_ms: { p50_ms: 39, p95_ms: null, investigate: true },
  });
  assert.deepEqual(report.investigate, ['first/startup_ms', 'first/first_frame_ms', 'idle/main_queue_ms', 'idle/dispatch_ms', 'idle/first_frame_ms']);
});

test('flags a p50 only when it is more than the penalty over warm', () => {
  const warm = repeat(25, 30);
  assert.deepEqual(analyze([session(warm, repeat(3, 50))]).investigate, []);
  assert.deepEqual(analyze([session(warm, repeat(3, 51))]).investigate, ['idle/startup_ms', 'idle/first_frame_ms']);
  assert.deepEqual(analyze([session(warm, repeat(3, 51))], [], { penaltyMs: 25 }).investigate, []);
  assert.deepEqual(analyze([session(warm, repeat(3, 51))], [], { penaltyMs: 0 }).investigate,
    ['first/startup_ms', 'first/first_frame_ms', 'idle/startup_ms', 'idle/first_frame_ms']);
  assert.deepEqual(scenario(analyze([session(warm, repeat(3, 51))]), 'idle').versus_warm.first_frame_ms, { p50_ms: 21, p95_ms: null, investigate: true });
});

test('flags a p95 only when both sides have enough samples for one', () => {
  const tail = [...repeat(18, 30), 80, 80];

  const reliable = analyze([session(repeat(25, 30), tail)]);
  assert.deepEqual(scenario(reliable, 'idle').versus_warm.first_frame_ms, { p50_ms: 0, p95_ms: 50, investigate: true });
  assert.deepEqual(reliable.investigate, ['idle/startup_ms', 'idle/first_frame_ms']);

  const fewIdle = analyze([session(repeat(25, 30), [...repeat(18, 30), 500])]);
  assert.deepEqual(scenario(fewIdle, 'idle').metrics.first_frame_ms.p95_reliable, false);
  assert.deepEqual(scenario(fewIdle, 'idle').versus_warm.first_frame_ms, { p50_ms: 0, p95_ms: null, investigate: false });
  assert.deepEqual(fewIdle.investigate, []);

  const fewWarm = analyze([session(repeat(19, 30), tail)]);
  assert.deepEqual(scenario(fewWarm, 'idle').versus_warm.first_frame_ms, { p50_ms: 0, p95_ms: null, investigate: false });
  assert.deepEqual(fewWarm.investigate, []);
});

test('has nothing to compare against when there are no warm captures', () => {
  const report = analyze([trace(hotkey(1, 0), hotkey(2, seconds(300), { frame: 500 }))]);
  assert.deepEqual(report.scenarios.map(entry => entry.scenario), ['first', 'idle']);
  assert.deepEqual(report.scenarios.map(entry => entry.versus_warm), [null, null]);
  assert.deepEqual(report.investigate, []);
});

test('the idle threshold is configurable', () => {
  const text = trace(hotkey(1, 0), hotkey(2, seconds(45)));
  assert.deepEqual(analyze([text]).scenarios.map(entry => entry.scenario), ['first', 'warm']);
  assert.deepEqual(analyze([text], [], { idleSeconds: 30 }).scenarios.map(entry => entry.scenario), ['first', 'idle']);
});

test('leaves out hotkey captures whose timing cannot be trusted and counts them', () => {
  const lateOverlay = interval('OverlayFirstDraw', 13, seconds(240) + ms(3) + seconds(11), seconds(240) + ms(3) + seconds(11) + ms(5), { category: 'SelectionOverlay' });
  const report = analyze([trace(
    hotkey(1, 0),
    hotkey(2, seconds(20), { queueEnd: 'failed' }),
    hotkey(3, seconds(40), { queueEnd: 'cancelled' }),
    hotkey(4, seconds(60), { queueEnd: 'timeout' }),
    hotkey(5, seconds(80), { ageText: 'eventAgeMs=-0.250' }),
    hotkey(6, seconds(100), { ageText: 'eventAgeMs=nan' }),
    hotkey(7, seconds(120), { ageText: 'eventAgeMs=' }),
    hotkey(8, seconds(140), { ageText: 'ages=3' }),
    hotkey(9, seconds(160), { ageText: 'eventAgeMs=1e3' }),
    hotkey(10, seconds(180), { overlay: false }),
    hotkey(11, seconds(200), { overlayEnd: 'cancelled' }),
    hotkey(12, seconds(220), { overlayEnd: 'failed' }),
    hotkey(13, seconds(240), { overlay: false }),
    lateOverlay,
  )]);

  assert.equal(report.hotkey_captures, 5);
  assert.deepEqual(report.excluded, { invalid_event_age: 5, queue_delay_not_completed: 3 });
  assert.deepEqual(report.first_frame, { no_overlay: 2, overlay_not_completed: 2 });
  assert.equal(scenario(report, 'first').metrics.first_frame_ms.count, 1);
  assert.equal(scenario(report, 'warm').metrics.event_age_ms.count, 4);
  assert.equal(scenario(report, 'warm').metrics.first_frame_ms, null);
  assert.match(render(report), /^Left out: invalid event age 5, queue delay not completed 3, no overlay 2, overlay not completed 2\.$/m);
});

test('matches each overlay to the hotkey capture that opened it', () => {
  const { records } = parseRecords([trace(
    hotkey(1, 0, { overlay: false }),
    hotkey(2, seconds(5), { frame: 30 }),
    hotkey(3, seconds(7), { frame: 55, pid: 9999 }),
    // Two displays draw their own overlay; the first frame is the earlier one.
    hotkey(4, seconds(20), { frame: 45 }),
    interval('OverlayFirstDraw', 99, seconds(20) + ms(3.5), seconds(20) + ms(38), { category: 'SelectionOverlay' }),
    hotkey(5, seconds(40), { frame: 45, overlayEnd: 'cancelled' }),
  )]);
  const { intervals, activity } = pairIntervals(records);
  const { captures, firstFrame } = buildCaptures(intervals, activity, { idleSeconds: 60 });

  assert.deepEqual(captures.map(capture => capture.first_frame_ms), [undefined, 30, 55, 38, undefined]);
  assert.deepEqual(captures.map(capture => capture.startup_ms), [undefined, 27, 52, 35, undefined]);
  assert.deepEqual(firstFrame, { no_overlay: 1, overlay_not_completed: 1 });
});

test('names the first capture after a marker, whatever it would otherwise be', () => {
  const report = analyze([trace(
    hotkey(1, 0, { frame: 120 }),
    hotkey(2, seconds(5), { frame: 30 }),
    hotkey(3, seconds(305), { frame: 150 }),
    hotkey(4, seconds(310), { frame: 31 }),
    hotkey(5, seconds(450), { frame: 80 }),
    hotkey(6, seconds(460), { frame: 32 }),
  )], [marker('wake', 300), marker('display', 400), marker('late', 10_000)]);

  assert.deepEqual(report.scenarios.map(entry => [entry.scenario, entry.captures]), [['first', 1], ['warm', 3], ['wake', 1], ['display', 1]]);
  assert.equal(scenario(report, 'wake').metrics.first_frame_ms.p50_ms, 150);
  assert.equal(scenario(report, 'display').metrics.first_frame_ms.p50_ms, 80);
  assert.equal(scenario(report, 'wake').versus_warm.first_frame_ms.p50_ms, 119);
  assert.deepEqual(report.unused_markers, ['late@10000s']);
  assert.deepEqual(report.options.markers, ['wake', 'display', 'late']);
});

test('applyMarkers gives a marker the first capture after it, inside the window', () => {
  const capture = (at, extraUs = 0) => ({ eventUs: seconds(at) + extraUs, scenario: 'warm' });
  const names = captures => captures.map(entry => entry.scenario);
  const at = (name, secondsAfter) => ({ name, atUs: seconds(secondsAfter), raw: `${name}=${secondsAfter}` });

  let captures = [capture(10), capture(20), capture(30)];
  assert.deepEqual(applyMarkers(captures, [at('wake', 15)], 600), []);
  assert.deepEqual(names(captures), ['warm', 'wake', 'warm']);

  captures = [capture(10), capture(20)];
  assert.deepEqual(applyMarkers(captures, [at('wake', 20)], 600), []);
  assert.deepEqual(names(captures), ['warm', 'wake']);

  captures = [capture(25)];
  assert.deepEqual(applyMarkers(captures, [at('wake', 15)], 10), []);
  assert.deepEqual(names(captures), ['wake']);

  captures = [capture(25, 1000)];
  assert.deepEqual(applyMarkers(captures, [at('wake', 15)], 10), ['wake=15']);
  assert.deepEqual(names(captures), ['warm']);

  captures = [capture(20)];
  assert.deepEqual(applyMarkers(captures, [at('b', 14), at('a', 12)], 600), ['a=12']);
  assert.deepEqual(names(captures), ['b']);

  captures = [capture(105)];
  assert.deepEqual(applyMarkers(captures, [at('new', 100), at('old', 0)], 10), ['old=0']);
  assert.deepEqual(names(captures), ['new']);

  captures = [capture(10)];
  assert.deepEqual(applyMarkers(captures, [at('wake', 11)], 600), ['wake=11']);
  assert.deepEqual(names(captures), ['warm']);
});

test('summarize uses nearest-rank percentiles and marks a p95 over fewer than 20 samples', () => {
  assert.equal(summarize([]), null);
  assert.equal(summarize([Number.NaN, Infinity]), null);
  assert.deepEqual(summarize([42.5]), { count: 1, min_ms: 42.5, p50_ms: 42.5, p95_ms: 42.5, max_ms: 42.5, p95_reliable: false });
  assert.deepEqual(summarize([Number.NaN, 3, Infinity]), { count: 1, min_ms: 3, p50_ms: 3, p95_ms: 3, max_ms: 3, p95_reliable: false });
  assert.deepEqual(summarize(Array.from({ length: 19 }, (_, i) => 19 - i)),
    { count: 19, min_ms: 1, p50_ms: 10, p95_ms: 19, max_ms: 19, p95_reliable: false });
  assert.deepEqual(summarize(Array.from({ length: 20 }, (_, i) => i + 1)),
    { count: 20, min_ms: 1, p50_ms: 10, p95_ms: 19, max_ms: 20, p95_reliable: true });
  assert.deepEqual(summarize(Array.from({ length: 100 }, (_, i) => 100 - i)),
    { count: 100, min_ms: 1, p50_ms: 50, p95_ms: 95, max_ms: 100, p95_reliable: true });
  assert.deepEqual(summarize([2.3456, 2.3444]), { count: 2, min_ms: 2.34, p50_ms: 2.34, p95_ms: 2.35, max_ms: 2.35, p95_reliable: false });
});

test('render prints the table, what was flagged and the caveats', () => {
  const text = render(analyze([SCENARIO_TRACE]));
  const lines = text.split('\n');

  assert.deepEqual(lines.slice(0, 4), [
    '### Hotkey latency by scenario',
    '',
    '| Scenario | Metric | Samples | p50 (ms) | p95 (ms) | p50 over warm | p95 over warm |',
    '| --- | --- | ---: | ---: | ---: | ---: | ---: |',
  ]);
  assert.ok(lines.includes('| first | key event to first overlay frame | 2 | 90 | 120 (max) | +59 (investigate) |  |'));
  assert.ok(lines.includes('| first | main actor to first overlay frame | 2 | 87 | 117 (max) | +59 (investigate) |  |'));
  assert.ok(lines.includes('| warm | key event to first overlay frame | 3 | 31 | 32 (max) |  |  |'));
  assert.ok(lines.includes('| idle | key event to hotkey callback | 1 | 4 | 4 (max) | +3 |  |'));
  assert.ok(lines.includes('| idle | callback to main actor (QueueDelay) | 1 | 30 | 30 (max) | +28 (investigate) |  |'));
  assert.ok(lines.includes('| idle | main actor to first overlay frame | 1 | 36 | 36 (max) | +8 |  |'));
  assert.ok(lines.includes('6 hotkey capture(s). 18 intervals, 0 unfinished, 0 ended without a begin, 1 other line(s) ignored.'));
  assert.ok(lines.some(line => line.startsWith('Over 20 ms against warm (the issue\'s initial diagnostic threshold, not a result): first/startup_ms, first/first_frame_ms, idle/main_queue_ms')));
  assert.ok(lines.some(line => line.startsWith('A p95 over fewer than 20 samples is only the maximum.')));
  assert.ok(lines.some(line => line.startsWith('Hotkey latency from Glint signposts, durations only.')));
  assert.ok(!lines.some(line => line.startsWith('Left out:')));
  assert.ok(!lines.some(line => line.startsWith('Markers that matched no capture')));
});

test('render shows a reliable p95 without the maximum note and lists unused markers', () => {
  const report = analyze([session(repeat(25, 30), [...repeat(18, 30), 80, 80])], [marker('wake', 1_000_000)]);
  const lines = render(report).split('\n');

  assert.ok(lines.includes('| idle | main actor to first overlay frame | 20 | 27 | 77 | 0 | +50 (investigate) |'));
  assert.ok(lines.includes('| idle | key event to first overlay frame | 20 | 30 | 80 | 0 | +50 (investigate) |'));
  assert.ok(lines.includes('Markers that matched no capture: wake@1000000s.'));
});

test('parseArguments reads the options and rejects what it cannot use', () => {
  const parsed = parseArguments([
    '--idle-seconds', '30', '--marker-window-seconds', '120.5', '--penalty-ms', '0',
    '--marker', 'wake=2026-11-10T16:05:00+01:00', '--marker', 'display-change=2026-11-10 16:06:40.5+0100',
    '--json', 'a.ndjson', '-',
  ]);
  assert.deepEqual(parsed.settings, { idleSeconds: 30, markerWindowSeconds: 120.5, penaltyMs: 0 });
  assert.deepEqual(parsed.files, ['a.ndjson', '-']);
  assert.equal(parsed.json, true);
  assert.deepEqual(parsed.markers.map(entry => [entry.name, entry.atUs, entry.raw]), [
    ['wake', START_US + seconds(300), 'wake=2026-11-10T16:05:00+01:00'],
    ['display-change', START_US + seconds(400) + 500_000, 'display-change=2026-11-10 16:06:40.5+0100'],
  ]);
  assert.equal(parseArguments(['--help']).help, true);
  assert.equal(parseArguments(['-h']).help, true);
  assert.equal(parseArguments(['--marker', `${'x'.repeat(32)}=2026-11-10T16:05:00+01:00`, 'a']).markers.length, 1);

  const time = '2026-11-10T16:05:00+01:00';
  const rejected = [
    [[], /Give at least one trace file/],
    [['--bogus', 'a'], /Unknown argument --bogus/],
    [['--idle-seconds'], /--idle-seconds needs a value/],
    [['--idle-seconds', '0', 'a'], /--idle-seconds needs a number above 0/],
    [['--idle-seconds', '-5', 'a'], /--idle-seconds needs a number above 0/],
    [['--idle-seconds', 'soon', 'a'], /--idle-seconds needs a number above 0/],
    [['--idle-seconds', '1e3', 'a'], /--idle-seconds needs a number above 0/],
    [['--marker-window-seconds', '0', 'a'], /--marker-window-seconds needs a number above 0/],
    [['--penalty-ms', '-1', 'a'], /--penalty-ms needs a number from 0/],
    [['--marker'], /--marker needs a value/],
    [['--marker', 'wake', 'a'], /--marker expects NAME=TIME/],
    [['--marker', `=${time}`, 'a'], /--marker expects NAME=TIME/],
    [['--marker', `Wake=${time}`, 'a'], /--marker expects NAME=TIME/],
    [['--marker', `1wake=${time}`, 'a'], /--marker expects NAME=TIME/],
    [['--marker', `${'x'.repeat(33)}=${time}`, 'a'], /--marker expects NAME=TIME/],
    [['--marker', `first=${time}`, 'a'], /--marker expects NAME=TIME/],
    [['--marker', `warm=${time}`, 'a'], /--marker expects NAME=TIME/],
    [['--marker', `idle=${time}`, 'a'], /--marker expects NAME=TIME/],
    [['--marker', 'wake=yesterday', 'a'], /--marker expects NAME=TIME/],
  ];
  for (const [argv, message] of rejected) assert.throws(() => parseArguments(argv), message, argv.join(' '));
});

function run(argv, { files = {}, stdin = '' } = {}) {
  const out = [];
  const err = [];
  const code = main(argv, {
    readFile: file => {
      if (!Object.hasOwn(files, file)) throw new Error(`ENOENT: ${file}`);
      return files[file];
    },
    readStdin: () => stdin,
    stdout: text => out.push(text),
    stderr: text => err.push(text),
  });
  return { code, stdout: out.join(''), stderr: err.join('') };
}

test('main prints the table, or JSON with --json, and exits 0', () => {
  const table = run(['trace.ndjson'], { files: { 'trace.ndjson': SCENARIO_TRACE } });
  assert.equal(table.code, 0);
  assert.equal(table.stderr, '');
  assert.ok(table.stdout.startsWith('### Hotkey latency by scenario\n'));

  const json = run(['--json', 'trace.ndjson'], { files: { 'trace.ndjson': SCENARIO_TRACE } });
  assert.equal(json.code, 0);
  assert.deepEqual(JSON.parse(json.stdout), analyze([SCENARIO_TRACE]));
  assert.equal(JSON.parse(json.stdout).schema_version, 1);
});

test('main reads standard input for - and merges several files', () => {
  const early = trace(hotkey(1, 0), hotkey(2, seconds(10)));
  const late = trace(hotkey(3, seconds(300)), hotkey(4, seconds(310)));
  const expected = JSON.parse(run(['--json', 'both'], { files: { both: `${early}\n${late}` } }).stdout);

  assert.deepEqual(JSON.parse(run(['--json', 'early', 'late'], { files: { early, late } }).stdout), expected);
  assert.deepEqual(JSON.parse(run(['--json', 'early', '-'], { files: { early }, stdin: late }).stdout), expected);
  assert.deepEqual(JSON.parse(run(['--json', '-'], { stdin: `${early}\n${late}` }).stdout), expected);
  assert.equal(expected.hotkey_captures, 4);
});

test('main applies the markers and thresholds it is given', () => {
  const text = trace(hotkey(1, 0), hotkey(2, seconds(5)), hotkey(3, seconds(305), { frame: 150 }));
  const { code, stdout } = run(['--json', '--marker', 'wake=2026-11-10T16:05:00+01:00', '--penalty-ms', '200', 'trace'], { files: { trace: text } });

  const report = JSON.parse(stdout);
  assert.equal(code, 0);
  assert.deepEqual(report.scenarios.map(entry => entry.scenario), ['first', 'warm', 'wake']);
  assert.equal(report.options.penalty_ms, 200);
  assert.deepEqual(report.investigate, []);
  assert.deepEqual(report.unused_markers, []);
});

test('main exits 1 when the trace has no hotkey captures', () => {
  const menuOnly = trace(interval('CaptureTotal', 1, 0, ms(500), { begin: 'trigger=menu mode=area', end: 'cancelled' }));
  for (const trial of [menuOnly, '', 'Filtering the log data using "subsystem"']) {
    const { code, stdout, stderr } = run(['--json', 'trace'], { files: { trace: trial } });
    assert.equal(code, 1);
    assert.equal(JSON.parse(stdout).hotkey_captures, 0);
    assert.match(stderr, /No hotkey captures to report/);
  }
});

test('main exits 2 with a message for bad usage and unreadable input', () => {
  const help = run(['--help']);
  assert.equal(help.code, 0);
  assert.match(help.stdout, /^Usage: node Scripts\/capture-latency\.cjs /);

  const none = run([]);
  assert.equal(none.code, 2);
  assert.equal(none.stdout, '');
  assert.match(none.stderr, /Give at least one trace file/);
  assert.match(none.stderr, /Usage: node Scripts\/capture-latency\.cjs/);

  const missing = run(['missing.ndjson']);
  assert.equal(missing.code, 2);
  assert.equal(missing.stdout, '');
  assert.equal(missing.stderr, 'Cannot read missing.ndjson.\n');

  const out = [];
  const err = [];
  const code = main(['-'], { readStdin: () => { throw new Error('EAGAIN'); }, stdout: text => out.push(text), stderr: text => err.push(text) });
  assert.equal(code, 2);
  assert.deepEqual(err, ['Cannot read standard input.\n']);
  assert.deepEqual(out, []);
});

test('main does not hide an unexpected failure', () => {
  assert.throws(() => main(['trace'], {
    readFile: () => SCENARIO_TRACE,
    stdout: () => { throw new TypeError('boom'); },
    stderr: () => {},
  }), TypeError);
});

test('a report holds durations and counts only, never what the trace says about processes or messages', () => {
  const text = trace(
    hotkey(1, 0, { overlayEnd: 'secret window title' }),
    hotkey(2, seconds(10), { queueEnd: 'secret window title' }),
    hotkey(3, seconds(20)),
  );
  for (const argv of [['trace'], ['--json', 'trace']]) {
    const { stdout, stderr } = run(argv, { files: { trace: text } });
    assert.doesNotMatch(`${stdout}${stderr}`, /private-project|\/Users|Glint\.app|MacOS|secret|window title|31337/);
  }
});

test('run as a command it reads files and standard input and exits with the documented codes', () => {
  const missing = spawnSync(process.execPath, [script, '/nonexistent/glint-trace.ndjson'], { encoding: 'utf8' });
  assert.equal(missing.status, 2);
  assert.equal(missing.stdout, '');
  assert.match(missing.stderr, /Cannot read \/nonexistent\/glint-trace\.ndjson\./);

  const piped = spawnSync(process.execPath, [script, '--json', '-'], { input: SCENARIO_TRACE, encoding: 'utf8' });
  assert.equal(piped.status, 0, piped.stderr);
  assert.deepEqual(JSON.parse(piped.stdout), analyze([SCENARIO_TRACE]));

  const empty = spawnSync(process.execPath, [script, '-'], { input: '', encoding: 'utf8' });
  assert.equal(empty.status, 1);
  assert.match(empty.stderr, /No hotkey captures to report/);

  const usage = spawnSync(process.execPath, [script], { encoding: 'utf8' });
  assert.equal(usage.status, 2);
  assert.match(usage.stderr, /Give at least one trace file/);
});
