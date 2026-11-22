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
  // Predicted echo on a link with a 150 ms round trip (docs/terminal.md, Predicted echo): a
  // recorded typing session played three times into a pane that opens with a recorded stream.
  // - A guessed key is on screen within a frame (17 ms; measured 0.45).
  // - No guess the user saw is taken back, and none vanishes.
  // - A key costs the main thread at most 50 µs more than without predictions (measured 24):
  //   the host's gate, then one wake of the feed queue, where the predictor lives beside the
  //   grid it judges. Only while the gate is on; `predict-fast` holds the off state.
  // - A key costs the feed queue 40 µs (measured 32, plus a quarter): the predictor places the
  //   guess and publishes the overlay under the terminal lock; 28 of the 32 are its own call.
  // No frame-gap budget: frames come when keys do. Main busy is budgeted as a difference below.
  predict: { 'echo.firstVisibleGuessedMedianMs': 17, 'echo.mismatchedDrawn': 0, 'echo.vanished': 0,
             'echo.mainKeyUs.median': 50, 'echo.feedKeyUs.median': 40 },
  // The same pane, script and link with no gate: the baseline for what predictions add.
  'predict-off': {},
  // A fast link (5 ms round trips): the gate is there and stays off, which is every session on
  // Wi-Fi beside its computer. No predictor is ever made, and the host never listens to its
  // stream: the prediction path runs for no key, on either thread. What is left per key is the
  // stream's one check that it has no observer, and per write two clock readings and the
  // gate's running average.
  // A key's whole send on the main thread: 100 µs (measured 60, 59 with no gate). On a fast link
  // nearly every key finds the queue idle, so its write starts in the key's own turn instead of
  // in a task (`TerminalStream.pump(now:)`); before that a send cost 32 µs here and the key
  // waited for the turn to end. Ruled by lead dev, 2026-11-22: the write starts in the key's
  // turn, and its cost on the main thread is accepted up to this limit.
  'predict-fast': { 'echo.predictors': 0, 'echo.mainKeyUs.count': 0, 'echo.feedKeyUs.count': 0,
                    'echo.mainSendUs.median': 100 },
  // The fast link with no gate: `predict-fast`'s baseline, held to the same limit per send.
  'predict-fast-off': { 'echo.mainSendUs.median': 100 },
};

// What one scenario may cost more than another: the difference of the two medians.
// - A session's whole main-thread work with predictions on, over the same session without a
//   gate: 15 ms over the scenario's 25 s (measured 5 to 8). The scenario itself costs about 100 ms
//   either way, most of it the frames its 69 keys draw.
// - A key's send on a fast link with the gate present and off, over the same with no gate: the
//   two must be the same. 1.5 µs is the spread of the baseline's own runs (measured 0.8).
export const differences = {
  'predictions add, main busy ms': { of: 'predict', against: 'predict-off', path: 'mainBusy.totalMs', limit: 15 },
  'a gate that is off adds, µs per key': { of: 'predict-fast', against: 'predict-fast-off', path: 'echo.mainSendUs.median', limit: 1.5 },
};

// The stream's filter (`APCFilter`), on the Mac with no simulator (scripts/bench/filter.sh): how
// long it may take on 10 MB of output, as a ratio to the filter it replaced, with snapshot
// collection off and on. Best of 30 runs each; measured 1.02 and 1.01.
export const filter = { ratioToBefore: 1.15 };

// A title and a waiting badge during a flood of progress reports (scripts/bench/flood.sh, an
// app test in the simulator): the longest either may take to show, in seconds. The meta flush's
// pace is 0.15 s.
export const flood = { lagSeconds: 0.5 };

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
