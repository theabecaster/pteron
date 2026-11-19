// Writes the benchmark scenarios: byte streams a program would send to a terminal.
// Deterministic: the same arguments always give the same bytes.
//
//   node gen.mjs <out dir> [--cols 60] [--rows 50] [--only seq,yes,...]
//
// Files (see ReplayCapture in the app for the formats):
//   seq.vt      `seq 1 200000`               plain output, lines end in CR LF as a pty sends them
//   yes.vt      `yes | head -n 200000`
//   unicode.vt  20,000 lines of CJK, emoji (ZWJ, flags, skin tones) and combining marks
//   top.timed   a `top`-like full-screen redraw on the alternate screen, 2 frames/s for 10 s
//   claude.timed  a Claude Code-style redraw loop: synchronized output (mode 2026) around
//               full-screen repaints with box drawing and colours, a spinner line that changes
//               60 times/s for 10 s, and the transcript scrolling twice a second
//
// The `.timed` files carry one record per write with its delay, so a replay keeps the pace.
import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const out = args[0];
if (!out) { console.error('usage: node gen.mjs <out dir> [--cols N] [--rows N] [--only a,b]'); process.exit(2); }
const opt = (name, fallback) => { const i = args.indexOf('--' + name); return i > 0 ? args[i + 1] : fallback; };
const cols = Number(opt('cols', 60)), rows = Number(opt('rows', 50));
const only = opt('only', '').split(',').filter(Boolean);
fs.mkdirSync(out, { recursive: true });

// mulberry32: a small seeded generator, so runs are repeatable.
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const ESC = '\x1b', CSI = ESC + '[';
const at = (row, col) => `${CSI}${row};${col}H`;
const pad = (s, n) => (s.length >= n ? s.slice(0, n) : s + ' '.repeat(n - s.length));

function timed(records) {
  const parts = [Buffer.from('REXTIMED1\n')];
  for (const [delayUs, text] of records) {
    const body = Buffer.from(text, 'utf8');
    const head = Buffer.alloc(8);
    head.writeUInt32LE(delayUs, 0);
    head.writeUInt32LE(body.length, 4);
    parts.push(head, body);
  }
  return Buffer.concat(parts);
}

const scenarios = {
  'seq.vt'() {
    let s = '';
    for (let i = 1; i <= 200000; i++) s += i + '\r\n';
    return Buffer.from(s);
  },

  'yes.vt'() {
    return Buffer.from('y\r\n'.repeat(200000));
  },

  // `seq 1 10000` (the scrollback at its 10,000-line cap) then the `yes` stream: every line
  // after the cap prunes one, for find's refreshes at the cap.
  'cap.vt'() {
    let s = '';
    for (let i = 1; i <= 10000; i++) s += i + '\r\n';
    return Buffer.concat([Buffer.from(s), Buffer.from('y\r\n'.repeat(100000))]);
  },

  'unicode.vt'() {
    const r = rng(7);
    const pick = (list) => list[Math.floor(r() * list.length)];
    const cjk = ['日本語のテキスト', '漢字かな交じり文', '中文字符测试', '한국어 텍스트', '東京都渋谷区', '你好，世界', 'ターミナル', '全角ＡＢＣ１２３'];
    const emoji = ['😀', '🚀', '🎉', '👍🏽', '👩‍💻', '👨‍👩‍👧‍👦', '🇯🇵', '🇪🇸', '🏳️‍🌈', '❤️', '✅', '⚠️', '🧑🏿‍🚀', '🔥'];
    const combining = ['é', 'ñ', 'ü', 'ā̊', 'q̃', 'Z̸̢͝', 'กำ', 'ที่', 'नमस्ते', 'ö̲', 'x⃗', 'å'];
    const latin = ['build', 'ok', 'error:', 'warning', 'src/main.rs', '100%', '=>', 'done'];
    let s = '';
    for (let i = 0; i < 20000; i++) {
      let line = `${i} `;
      const n = 4 + Math.floor(r() * 6);
      for (let k = 0; k < n; k++) {
        const kind = r();
        const word = kind < 0.4 ? pick(cjk) : kind < 0.65 ? pick(emoji) : kind < 0.85 ? pick(combining) : pick(latin);
        line += r() < 0.15 ? `${CSI}3${1 + Math.floor(r() * 7)}m${word}${CSI}0m ` : word + ' ';
      }
      s += line + '\r\n';
    }
    return Buffer.from(s, 'utf8');
  },

  'top.timed'() {
    const r = rng(11);
    const names = ['WindowServer', 'kernel_task', 'Xcode', 'node', 'zsh', 'rex', 'Simulator', 'mds_stores', 'launchd', 'Safari',
      'swift-frontend', 'clang', 'ld', 'git', 'ssh', 'tailscaled', 'coreaudiod', 'Finder', 'Terminal', 'logd'];
    const procs = [];
    for (let i = 0; i < Math.max(rows, 8); i++) {
      procs.push({ pid: 100 + Math.floor(r() * 90000), name: names[i % names.length], cpu: r() * 40, mem: 10 + r() * 900, threads: 1 + Math.floor(r() * 40) });
    }
    const records = [[0, `${CSI}?1049h${CSI}?25l${CSI}2J`]];
    for (let f = 0; f < 20; f++) {
      for (const p of procs) p.cpu = Math.max(0, p.cpu + (r() - 0.5) * 12);
      procs.sort((a, b) => b.cpu - a.cpu);
      const load = (1 + r() * 4).toFixed(2);
      let s = at(1, 1);
      const head = [
        `Processes: ${400 + f} total, ${2 + (f % 5)} running, ${398 - (f % 5)} sleeping, ${2000 + f * 3} threads`,
        `Load Avg: ${load}, ${(2 + r()).toFixed(2)}, ${(2 + r()).toFixed(2)}  CPU usage: ${(5 + r() * 30).toFixed(2)}% user, ${(3 + r() * 10).toFixed(2)}% sys`,
        `PhysMem: ${(20 + r() * 10).toFixed(0)}G used (${(2 + r()).toFixed(1)}G wired), ${(1 + r() * 4).toFixed(0)}G unused.`,
        `Networks: packets: ${1000000 + f * 1234}/1G in, ${900000 + f * 987}/800M out.`,
        '',
      ];
      head.forEach((line, i) => { s += at(i + 1, 1) + `${CSI}1m` + pad(line, cols) + `${CSI}0m`; });
      s += at(6, 1) + `${CSI}7m` + pad('PID    COMMAND          %CPU   MEM    #TH', cols) + `${CSI}0m`;
      for (let row = 7; row <= rows; row++) {
        const p = procs[row - 7];
        const colour = p.cpu > 30 ? 31 : p.cpu > 15 ? 33 : 32;
        const text = `${String(p.pid).padEnd(6)} ${pad(p.name, 16)} `;
        const cpu = p.cpu.toFixed(1).padStart(5);
        const rest = ` ${(p.mem.toFixed(0) + 'M').padStart(6)} ${String(p.threads).padStart(5)}`;
        s += at(row, 1) + text + `${CSI}${colour}m${cpu}${CSI}0m` + pad(rest, Math.max(0, cols - text.length - cpu.length)) + `${CSI}K`;
      }
      records.push([f === 0 ? 0 : 500000, s]);
    }
    records.push([500000, `${CSI}?25h${CSI}?1049l`]);
    return timed(records);
  },

  'claude.timed'() {
    const r = rng(23);
    const spinner = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    const verbs = ['Thinking', 'Reading', 'Searching', 'Editing', 'Running'];
    const words = ['the', 'renderer', 'holds', 'a', 'frame', 'while', 'the', 'parser', 'runs', 'and', 'then', 'presents', 'it', 'at', 'vsync',
      'so', 'no', 'torn', 'rows', 'reach', 'the', 'screen', 'during', 'a', 'repaint'];
    const rgb = (r8, g, b) => `${CSI}38;2;${r8};${g};${b}m`;
    const live = 9;                      // rows of the live region at the bottom
    const transcriptRows = rows - live;  // rows 1…transcriptRows scroll
    const transcript = [];
    const sentence = () => {
      let s = '';
      while (s.length < cols - 12) s += words[Math.floor(r() * words.length)] + ' ';
      return s.trim().slice(0, cols - 4);
    };
    const tool = (i) => `${rgb(120, 200, 120)}●${CSI}0m ${CSI}1mBash${CSI}0m(${rgb(140, 170, 255)}make test-${i}${CSI}0m)`;
    for (let i = 0; i < transcriptRows; i++) transcript.push(i % 7 === 3 ? tool(i) : '  ' + sentence());
    const box = (top) => (top ? '╭' : '╰') + '─'.repeat(cols - 2) + (top ? '╮' : '╯');
    const records = [[0, `${CSI}2J${CSI}H`]];
    let tokens = 1200;
    for (let f = 0; f < 600; f++) {
      let s = `${CSI}?2026h${CSI}?25l`;
      if (f > 0 && f % 30 === 0) {
        // The transcript gains a line: scroll its region up by one, as an agent's output does.
        transcript.shift();
        transcript.push(f % 90 === 0 ? tool(f) : '  ' + sentence());
        s += `${CSI}1;${transcriptRows}r${at(transcriptRows, 1)}\n${CSI}r`;
      }
      s += `${CSI}H`;
      for (let row = 0; row < transcriptRows; row++) s += at(row + 1, 1) + `${CSI}2K` + transcript[row];
      tokens += Math.floor(r() * 9);
      const elapsed = Math.floor(f / 60);
      let row = transcriptRows + 1;
      s += at(row++, 1) + `${CSI}2K`;
      s += at(row++, 1) + `${CSI}2K${rgb(215, 119, 87)}${spinner[f % spinner.length]} ${verbs[Math.floor(f / 120) % verbs.length]}…${CSI}0m ${CSI}2m(${elapsed}s · ↑ ${tokens} tokens · esc to interrupt)${CSI}0m`;
      s += at(row++, 1) + `${CSI}2K`;
      s += at(row++, 1) + `${CSI}2K${rgb(110, 110, 120)}${box(true)}${CSI}0m`;
      s += at(row++, 1) + `${CSI}2K${rgb(110, 110, 120)}│${CSI}0m > ${pad('fix the failing test' + (f % 60 < 30 ? '█' : ' '), cols - 6)} ${rgb(110, 110, 120)}│${CSI}0m`;
      s += at(row++, 1) + `${CSI}2K${rgb(110, 110, 120)}${box(false)}${CSI}0m`;
      s += at(row++, 1) + `${CSI}2K${CSI}2m  ? for shortcuts${' '.repeat(Math.max(1, cols - 44))}${CSI}0m${rgb(255, 200, 80)}◐ medium${CSI}0m · ${CSI}2m/model${CSI}0m`;
      s += at(row++, 1) + `${CSI}2K${CSI}48;5;236m${pad(` ~/src/app  main  ${f} `, cols)}${CSI}0m`;
      s += at(row, 1) + `${CSI}2K`;
      s += `${CSI}?2026l`;
      records.push([f === 0 ? 0 : 16667, s]);
    }
    records.push([16667, `${CSI}?25h${at(rows, 1)}`]);
    return timed(records);
  },
};

for (const [name, make] of Object.entries(scenarios)) {
  if (only.length && !only.includes(name.split('.')[0])) continue;
  const bytes = make();
  fs.writeFileSync(path.join(out, name), bytes);
  console.log(`${name}\t${bytes.length} bytes`);
}
