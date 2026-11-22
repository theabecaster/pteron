// Prints the benchmark report from PerfProbe result files and checks it against the budgets.
//
//   node report.mjs <results dir>
//
// Files are named <scenario>__<run>.json (scripts/bench/run.sh). Each cell is the median of the
// runs, with the lowest and highest in brackets. The medians are checked against
// scripts/bench/budgets.mjs. Exit status: 0 when every budget holds, 1 when one is passed, a
// run failed, or a scenario the budgets name has no result (unless --partial: then only the
// scenarios that ran are checked).
import fs from 'node:fs';
import path from 'node:path';
import * as budgets from './budgets.mjs';

const args = process.argv.slice(2);
const partial = args.includes('--partial');
const dir = args.find((a) => !a.startsWith('--'));
if (!dir) { console.error('usage: node report.mjs <results dir> [--partial]'); process.exit(2); }

const runs = {};   // scenario -> [result]
const notes = [];
const failedRuns = [];
for (const f of fs.readdirSync(dir).filter((f) => f.endsWith('.json')).sort()) {
  const [scenario] = f.replace(/\.json$/, '').split('__');
  const r = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
  if (r.error) { failedRuns.push(`${f}: ${r.error}`); continue; }
  if (r.build?.assertions) notes.push(`${f}: built with assertions on, not a Release build`);
  if (r.replay && r.replay.zoom !== 1) notes.push(`${f}: zoom ${r.replay.zoom}, the terminal was not drawn 1:1`);
  for (const [k, where] of [['drawnAssumed', r.flow], ['firstOutputAssumed', r.flow], ['presentedAssumed', r.firstFrame]]) {
    if (where?.[k]) notes.push(`${f}: ${k} (no frame was seen in time; the last one was taken)`);
  }
  (runs[scenario] ??= []).push(r);
}

const get = (r, p) => p.split('.').reduce((o, k) => (o == null ? o : o[k]), r);
function stat(list, p) {
  const v = (list ?? []).map((r) => get(r, p)).filter((x) => typeof x === 'number').sort((a, b) => a - b);
  if (!v.length) return null;
  const mid = v.length >> 1;
  return { median: v.length % 2 ? v[mid] : (v[mid - 1] + v[mid]) / 2, min: v[0], max: v[v.length - 1], n: v.length };
}
const num = (x) => (Math.abs(x) >= 100 ? x.toFixed(0) : Math.abs(x) >= 10 ? x.toFixed(1) : x.toFixed(2)).replace(/\.0+$/, '');
const cell = (s) => (s ? `${num(s.median)} (${num(s.min)}–${num(s.max)})` : '–');

const live = runs.live;
delete runs.live;
// Pane switches on real panes (run.sh --switch), by the simulated round trip.
const switches = Object.keys(runs).filter((s) => /^switch\d+$/.test(s)).sort((a, b) => a.slice(6) - b.slice(6));
const switchRuns = Object.fromEntries(switches.map((s) => [s, runs[s]]));
for (const s of switches) delete runs[s];
// Two panes streaming unseen while the one on screen sits still (run.sh --warm).
const warm = runs.warm;
delete runs.warm;
const scenarios = Object.keys(runs);

// column title, path, and a second path shown beside it (labelled `main` unless a label follows)
const flowColumns = [
  ['first output ms', 'flow.firstOutputMs'],
  ['parsed ms', 'flow.parseMs'],
  ['drawn ms', 'flow.drawnMs'],
  ['frames/s', 'presents.perSecond'],
  ['frame gaps >25 ms', 'presents.gapsOver25'],
  ['main gaps >25 ms', 'mainLink.gapsOver25'],
  ['worst main gap ms', 'mainLink.worstGapMs'],
  ['main busy ms', 'mainBusy.totalMs'],
  ['worst main slice ms', 'mainBusy.worstMs'],
  ['CPU ms (main)', 'cpu.processMs', 'cpu.mainMs'],
  ['peak MB', 'memory.peakMB'],
  ['idle MB', 'memory.idleMB'],
];

function table(title, rows, columns) {
  console.log(`\n${title}\n`);
  console.log(`| Scenario | ${columns.map((c) => c[0]).join(' | ')} |`);
  console.log(`| --- | ${columns.map(() => '---').join(' | ')} |`);
  for (const [name, list] of rows) {
    const cells = columns.map(([, p, extra, label]) => {
      const main = cell(stat(list, p));
      const also = extra ? stat(list, extra) : null;
      return also ? `${main}, ${label ?? 'main'} ${num(also.median)}` : main;
    });
    console.log(`| ${name} | ${cells.join(' | ')} |`);
  }
}

if (scenarios.length) {
  const sample = runs[scenarios[0]][0];
  const n = Math.max(...scenarios.map((s) => runs[s].length));
  console.log(`Replay: ${n} runs per cell, median (min–max). ${sample.device.model}${sample.device.simulator ? ' simulator' : ''}, ` +
    `${sample.device.os}, ${sample.device.screenHz} Hz, grid ${sample.replay.cols}×${sample.replay.rows}, ${sample.replay.fontSize} pt.`);
  table('### Replay', scenarios.map((s) => [s, runs[s]]), flowColumns);
}
if (runs.predict) {
  table('### Predicted echo: a recorded typing session on a link with a 150 ms round trip (`predict-off`: the same with no gate)',
    ['predict', 'predict-off'].filter((s) => runs[s]).map((s) => [s, runs[s]]), [
    ['guessed keys', 'echo.predictedKeys'],
    ['guess shown ms', 'echo.predictedMedianMs', 'echo.predictedP95Ms', 'p95'],
    ['guessed keys first seen ms', 'echo.firstVisibleGuessedMedianMs', 'echo.firstVisibleGuessedP95Ms', 'p95'],
    ['main busy ms', 'mainBusy.totalMs'],
    ['main µs per send', 'echo.mainSendUs.median', 'echo.mainSendUs.p95', 'p95'],
    ['echo shown ms', 'echo.shownMedianMs'],
    ['drawn', 'echo.drawn'],
    ['confirmed', 'echo.confirmed'],
    ['taken back', 'echo.mismatchedDrawn'],
    ['wrong, never drawn', 'echo.mismatched'],
    ['vanished', 'echo.vanished'],
    ['main µs per key', 'echo.mainKeyUs.median', 'echo.mainGateUs.median', 'gate'],
    ['feed µs per key', 'echo.feedKeyUs.median', 'echo.feedKeyUs.max', 'max'],
    ['feed µs per slice', 'echo.feedSliceUs.median', 'echo.feedSliceUs.max', 'max'],
  ]);
}
if (live) {
  // No budget: these depend on the network and the server.
  table(`### Live: time to first frame, ms after pane open (${live.length} cold launches)`, [['live', live]], [
    ['connecting', 'firstFrame.connectingMs'],
    ['socket live', 'firstFrame.liveMs'],
    ['snapshot received', 'firstFrame.snapshotReceivedMs'],
    ['restored', 'firstFrame.restoredMs'],
    ['first frame', 'firstFrame.presentedMs'],
    ['snapshot bytes', 'firstFrame.snapshotBytes'],
    ['peak MB', 'memory.peakMB'],
  ]);
}

if (switches.length) {
  // Milliseconds after the pane came on screen; each cell the median of the runs' own medians.
  table(`### Pane switches, fit mode (${switchRuns[switches[0]].length} runs of 10 switches; the number is the simulated round trip in ms)`,
    switches.map((s) => [s, switchRuns[s]]), [
      ['cold: first frame', 'mounts.cold.firstFrameMs'],
      ['cold: current', 'mounts.cold.currentMs'],
      ['cold mounts', 'mounts.cold.count'],
      ['parked: first frame', 'mounts.parked.firstFrameMs'],
      ['parked: current', 'mounts.parked.currentMs'],
      ['parked mounts', 'mounts.parked.count'],
      ['parked: key answered', 'mounts.parked.keyAnsweredMs'],
      ['parked: keys answered', 'mounts.parked.keysAnswered'],
      ['warm: first frame', 'mounts.warm.firstFrameMs'],
      ['warm: current', 'mounts.warm.currentMs'],
      ['warm mounts', 'mounts.warm.count'],
      ['warm: key answered', 'mounts.warm.keyAnsweredMs'],
      ['warm: keys answered', 'mounts.warm.keysAnswered'],
      ['peak MB', 'memory.peakMB'],
    ]);
}

if (warm) {
  table(`### Two warm panes streaming unseen, the pane on screen still for 10 s (${warm.length} runs)`, [['warm', warm]], [
    ['main busy ms', 'idle.mainBusy.totalMs'],
    ['worst main slice ms', 'idle.mainBusy.worstMs'],
    ['CPU %', 'idle.cpu.percent'],
    ['main wake-ups/s', 'idle.wakeups.mainPerSecond'],
    ['energy mJ', 'idle.power.energyMJ'],
    ['frames', 'idle.presents'],
    ['cold mounts', 'mounts.cold.count'],
  ]);
}

// Budgets (scripts/bench/budgets.mjs): the median of a scenario's runs against a fixed limit.
const title = Object.fromEntries(flowColumns.map(([t, p]) => [p, t]));
const verdicts = [];   // [metric, scenario, 'pass' | 'FAIL' | 'no data', detail]
for (const s of Object.keys(budgets.scenarios)) {
  if (!runs[s]) {
    if (!partial) verdicts.push(['runs', s, 'no data', 'no result']);
    continue;
  }
  for (const [p, limit] of Object.entries({ ...budgets.all, ...budgets.scenarios[s] })) {
    const got = stat(runs[s], p);
    if (!got) { verdicts.push([title[p] ?? p, s, 'no data', 'not in the results']); continue; }
    verdicts.push([title[p] ?? p, s, got.median <= limit ? 'pass' : 'FAIL', `${num(got.median)}, budget ${num(limit)}`]);
  }
}
// Pane switches (run.sh --switch): checked only when they were run, since they need a server.
for (const s of switches) {
  for (const [p, limit] of Object.entries(budgets.switches[s] ?? {})) {
    const got = stat(switchRuns[s], p);
    if (!got) continue;
    verdicts.push([budgets.switchTitles[p] ?? p, s, got.median <= limit ? 'pass' : 'FAIL', `${num(got.median)}, budget ${num(limit)}`]);
  }
}
for (const s of scenarios) if (!budgets.scenarios[s]) notes.push(`${s}: no budget in scripts/bench/budgets.mjs, not checked`);

console.log('\n### Budgets\n');
for (const m of [...new Set(verdicts.map((v) => v[0]))]) {
  const mine = verdicts.filter((v) => v[0] === m);
  const bad = mine.filter((v) => v[2] !== 'pass');
  console.log(`- ${m}: **${bad.length ? (bad.some((v) => v[2] === 'FAIL') ? 'FAIL' : 'no data') : 'pass'}**` +
    (bad.length ? ': ' + bad.map((v) => `${v[1]}: ${v[3]}`).join('; ') : ` (${mine.length} checked)`));
}
if (failedRuns.length) console.log(`- runs that failed: **FAIL**: ${failedRuns.join('; ')}`);
const ok = verdicts.length > 0 && verdicts.every((v) => v[2] === 'pass') && !failedRuns.length;
console.log(`\nBudgets (hitches, frame gaps, main-thread time, time to the final frame, memory): **${ok ? 'PASS' : 'FAIL'}**`);
if (notes.length) console.log('\nNotes:\n' + notes.map((n) => `- ${n}`).join('\n'));
process.exit(ok ? 0 : 1);
