// Prints the benchmark report from PerfProbe result files.
//
//   node report.mjs <results dir>
//
// Files are named <scenario>__<engine>__<run>.json (scripts/bench/run.sh). Each cell is the
// median of the runs, with the lowest and highest in brackets. The verdict lines check the pass
// criteria in docs/ghostty-engine.md.
import fs from 'node:fs';
import path from 'node:path';

const dir = process.argv[2];
if (!dir) { console.error('usage: node report.mjs <results dir>'); process.exit(2); }

const runs = {};   // scenario -> engine -> [result]
const notes = [];
for (const f of fs.readdirSync(dir).filter((f) => f.endsWith('.json')).sort()) {
  const [scenario, engine] = f.replace(/\.json$/, '').split('__');
  const r = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
  if (r.error) { notes.push(`${f}: ${r.error} (left out)`); continue; }
  if (r.build?.assertions) notes.push(`${f}: built with assertions on, not a Release build`);
  if (r.replay && r.replay.zoom !== 1) notes.push(`${f}: zoom ${r.replay.zoom}, the terminal was not drawn 1:1`);
  for (const [k, where] of [['drawnAssumed', r.flow], ['firstOutputAssumed', r.flow], ['presentedAssumed', r.firstFrame]]) {
    if (where?.[k]) notes.push(`${f}: ${k} (no frame was seen in time; the last one was taken)`);
  }
  ((runs[scenario] ??= {})[engine] ??= []).push(r);
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

const engines = ['swiftTerm', 'ghostty'];
const label = { swiftTerm: 'SwiftTerm', ghostty: 'Ghostty' };
const live = runs.live;
delete runs.live;
const scenarios = Object.keys(runs);

// column title, path, and whether it is part of the pass criteria ("gate")
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
  console.log(`| Scenario | Engine | ${columns.map((c) => c[0]).join(' | ')} |`);
  console.log(`| --- | --- | ${columns.map(() => '---').join(' | ')} |`);
  for (const [name, byEngine] of rows) {
    for (const e of engines) {
      const cells = columns.map(([, p, extra]) => {
        const main = cell(stat(byEngine[e], p));
        const also = extra ? stat(byEngine[e], extra) : null;
        return also ? `${main}, main ${num(also.median)}` : main;
      });
      console.log(`| ${name} | ${label[e]} | ${cells.join(' | ')} |`);
    }
  }
}

if (scenarios.length) {
  const sample = Object.values(runs[scenarios[0]])[0][0];
  const n = Math.max(...scenarios.flatMap((s) => engines.map((e) => runs[s][e]?.length ?? 0)));
  console.log(`Replay: ${n} runs per cell, median (min–max). ${sample.device.model}${sample.device.simulator ? ' simulator' : ''}, ` +
    `${sample.device.os}, ${sample.device.screenHz} Hz, grid ${sample.replay.cols}×${sample.replay.rows}, ${sample.replay.fontSize} pt.`);
  table('### Replay', scenarios.map((s) => [s, runs[s]]), flowColumns);
}
if (live) {
  table(`### Live: time to first frame, ms after pane open (${live.ghostty?.length ?? 0} cold launches per engine)`, [['live', live]], [
    ['connecting', 'firstFrame.connectingMs'],
    ['socket live', 'firstFrame.liveMs'],
    ['snapshot received', 'firstFrame.snapshotReceivedMs'],
    ['restored', 'firstFrame.restoredMs'],
    ['first frame', 'firstFrame.presentedMs'],
    ['snapshot bytes', 'firstFrame.snapshotBytes'],
    ['peak MB', 'memory.peakMB'],
  ]);
}

// Pass criteria (docs/ghostty-engine.md): Ghostty is better on first frame, gaps and main-thread
// time in every scenario, and within 10% on memory.
const verdicts = [];
function judge(metric, where, byEngine, p, ok, rule) {
  const s = stat(byEngine.swiftTerm, p), g = stat(byEngine.ghostty, p);
  if (!s || !g) { verdicts.push([metric, where, 'no data', '']); return; }
  verdicts.push([metric, where, ok(g.median, s.median) ? 'pass' : 'FAIL', `Ghostty ${num(g.median)} vs SwiftTerm ${num(s.median)} (${rule})`]);
}
const less = (g, s) => g < s;
const notMore = (g, s) => g <= s;          // 0 against 0 is no hitch on either side
const within10 = (g, s) => g <= s * 1.1;
if (live) judge('first frame', 'live', live, 'firstFrame.presentedMs', less, 'lower');
for (const s of scenarios) {
  judge('main gaps >25 ms', s, runs[s], 'mainLink.gapsOver25', notMore, 'not more');
  // Gaps between frames only mean a stall while output keeps coming: not for `top`, which
  // draws twice a second.
  if (s !== 'top') judge('frame gaps >25 ms', s, runs[s], 'presents.gapsOver25', notMore, 'not more');
  judge('worst main gap', s, runs[s], 'mainLink.worstGapMs', (g, st) => g <= Math.max(st, 25), 'not worse, or under 25 ms');
  judge('main-thread time', s, runs[s], 'mainBusy.totalMs', less, 'lower');
  judge('memory peak', s, runs[s], 'memory.peakMB', within10, 'within 10%');
  judge('memory idle', s, runs[s], 'memory.idleMB', within10, 'within 10%');
}
// Not in the criteria, but what a user sees: how soon output is on screen.
for (const s of scenarios) {
  judge('first output (info)', s, runs[s], 'flow.firstOutputMs', less, 'lower');
  judge('final state drawn (info)', s, runs[s], 'flow.drawnMs', (g, st) => g <= st * 1.02, 'not later, 2% slack');
}

console.log('\n### Pass / fail\n');
const metrics = [...new Set(verdicts.map((v) => v[0]))];
for (const m of metrics) {
  const mine = verdicts.filter((v) => v[0] === m);
  const failed = mine.filter((v) => v[2] === 'FAIL');
  const missing = mine.filter((v) => v[2] === 'no data');
  const state = failed.length ? 'FAIL' : missing.length === mine.length ? 'no data' : 'pass';
  console.log(`- ${m}: **${state}**` + (failed.length ? ': ' + failed.map((v) => `${v[1]}: ${v[3]}`).join('; ') : ''));
}
const gate = verdicts.filter((v) => !v[0].endsWith('(info)'));
const overall = gate.some((v) => v[2] === 'FAIL') ? 'FAIL' : gate.some((v) => v[2] === 'no data') ? 'INCOMPLETE' : 'PASS';
console.log(`\nCriteria (first frame, gaps, main-thread time, memory within 10%): **${overall}**`);
if (notes.length) console.log('\nNotes:\n' + notes.map((n) => `- ${n}`).join('\n'));
