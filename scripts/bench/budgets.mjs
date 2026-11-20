// The benchmark's pass criteria: what the median of a scenario's runs may be at most.
// scripts/bench/report.mjs checks them and exits 1 when one is passed.
//
// Taken from the engine's last comparison run (docs/ghostty-engine.md, Measurements: iPhone 17
// simulator, 60 Hz, 5 runs), with headroom for a busy Mac: about twice the measured median
// for times, a quarter more for memory. They are simulator budgets, not device ones. When a
// change moves a number on purpose, move its budget here in the same commit.

// Every scenario.
export const all = {
  'mainLink.gapsOver25': 1,     // main-thread hitches over 25 ms; measured 0, at most 1 in a run
  'mainBusy.worstMs': 8,        // the longest the main thread could not react; measured 0.3 to 1.2
  'memory.peakMB': 40,          // measured 23.5 to 32
  'memory.idleMB': 32,          // measured 23.4 to 26.6
};

// Per scenario. `mainBusy.totalMs` is the main thread's whole work for the run; `flow.drawnMs`
// is first byte to the frame that shows the final state, judged only where the feed is as fast
// as the host takes it. `presents.gapsOver25` is stalls between frames while output keeps
// coming: not for `top`, which draws twice a second by itself.
export const scenarios = {
  seq:        { 'mainBusy.totalMs': 10,  'presents.gapsOver25': 1, 'flow.drawnMs': 60 },    // measured 2.2, 0, 19.7
  'seq-wire': { 'mainBusy.totalMs': 90,  'presents.gapsOver25': 1 },                        // measured 40, 0
  yes:        { 'mainBusy.totalMs': 10,  'presents.gapsOver25': 1, 'flow.drawnMs': 60 },    // measured 1.7, 0, 21.4
  'yes-wire': { 'mainBusy.totalMs': 35,  'presents.gapsOver25': 1 },                        // measured 13.3, 0
  unicode:    { 'mainBusy.totalMs': 15,  'presents.gapsOver25': 1, 'flow.drawnMs': 150 },   // measured 4.4, 0, 38.3
  top:        { 'mainBusy.totalMs': 160 },                                                  // measured 78
  claude:     { 'mainBusy.totalMs': 250, 'presents.gapsOver25': 1 },                        // measured 122, 0
  // Find open: the same numbers as without it (a miss blocks the merge). `cap-find` is `yes`
  // after the scrollback reached its cap.
  'seq-find':     { 'mainBusy.totalMs': 10,  'presents.gapsOver25': 1, 'flow.drawnMs': 60 },
  'unicode-find': { 'mainBusy.totalMs': 15,  'presents.gapsOver25': 1, 'flow.drawnMs': 150 },
  'claude-find':  { 'mainBusy.totalMs': 250, 'presents.gapsOver25': 1 },
  'cap-find':     { 'mainBusy.totalMs': 10,  'presents.gapsOver25': 1, 'flow.drawnMs': 60 },
};

// Pane switches on real panes (run.sh --switch), by simulated round trip in ms. Checked only
// when the switch runs were made. A pane that comes back from the park draws its last screen
// in its first frame: two frames at 60 Hz at most.
// A cold pane at 150 ms: the stream starts beside the fit claim, so at least two round trips
// (300 ms) under the 1267 ms measured before that (3 runs, 1262 to 1280); measured 832.
// A metric with no mounts of its kind in a run is not checked: which panes park and which stay
// warm depends on the switching.
export const switches = {
  switch0:   { 'mounts.parked.firstFrameMs': 34, 'mounts.warm.firstFrameMs': 34 },
  switch150: { 'mounts.parked.firstFrameMs': 34, 'mounts.warm.firstFrameMs': 34, 'mounts.cold.firstFrameMs': 967 },
};
export const switchTitles = {
  'mounts.parked.firstFrameMs': 'parked pane: first frame ms',
  'mounts.warm.firstFrameMs': 'warm pane: first frame ms',
  'mounts.cold.firstFrameMs': 'cold pane: first frame ms',
};
