import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

const { BrowserManager, shouldEnableChromiumSandbox } = await import(process.cwd() + '/browse/src/browser-manager.ts');
const { observeQAWrites, qaWriteVerdict } = await import(process.cwd() + '/test/helpers/qa-functional-observer.ts');

assert.equal(process.platform, 'linux');
assert.equal(process.arch, 'x64');
assert.equal(shouldEnableChromiumSandbox(), true);

interface ProcSnapshot {
  pid: number;
  ppid: number;
  name: string;
  seccomp: string;
  noNewPrivs: string;
  cmdline: string[];
}

function readProcSnapshot(pid: number): ProcSnapshot | null {
  try {
    const statusRaw = fs.readFileSync(`/proc/${pid}/status`, 'utf8');
    const cmdlineRaw = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8');
    const field = (key: string): string => {
      const m = statusRaw.match(new RegExp(`^${key}:\\s*(.+)$`, 'm'));
      return m ? m[1].trim() : '';
    };
    const ppid = Number.parseInt(field('PPid'), 10);
    if (!Number.isInteger(ppid)) return null;
    return {
      pid,
      ppid,
      name: field('Name'),
      seccomp: field('Seccomp'),
      noNewPrivs: field('NoNewPrivs'),
      cmdline: cmdlineRaw.split('\0').filter(Boolean),
    };
  } catch {
    return null;
  }
}

function collectProcessTree(rootPid: number): ProcSnapshot[] {
  const all = new Map<number, ProcSnapshot>();
  for (const entry of fs.readdirSync('/proc')) {
    if (!/^\d+$/.test(entry)) continue;
    const snap = readProcSnapshot(Number.parseInt(entry, 10));
    if (snap) all.set(snap.pid, snap);
  }
  const tree: ProcSnapshot[] = [];
  const queue = [rootPid];
  const seen = new Set<number>();
  while (queue.length > 0) {
    const current = queue.shift()!;
    if (seen.has(current)) continue;
    seen.add(current);
    const snap = all.get(current);
    if (snap) tree.push(snap);
    for (const candidate of all.values()) {
      if (candidate.ppid === current && !seen.has(candidate.pid)) {
        queue.push(candidate.pid);
      }
    }
  }
  return tree;
}

const manager = new BrowserManager();
let browserEvidence: Record<string, unknown> = {};
try {
  await manager.launch();
  const page = manager.getPage();
  await page.setContent('<title>Gstack acceptance</title><h1>Owned Linux fixture</h1>');
  assert.equal(await page.title(), 'Gstack acceptance');
  const screenshotBytes = (await page.screenshot()).length;
  assert.ok(screenshotBytes > 0);

  const procInfo = manager.getChromiumProcInfo();
  assert.ok(procInfo && procInfo.pid > 1, 'Expected launched Chromium PID from BrowserManager');
  const rootExe = fs.realpathSync(`/proc/${procInfo.pid}/exe`);
  assert.match(rootExe, /\/chromium_headless_shell-\d+\/chrome-headless-shell-linux64\/chrome-headless-shell$/);

  const tree = collectProcessTree(procInfo.pid);
  const rootSnap = tree.find((p) => p.pid === procInfo.pid);
  assert.ok(rootSnap, 'Root Chromium process missing from /proc snapshot');
  for (const proc of tree) {
    assert.equal(proc.cmdline.includes('--no-sandbox'), false, `Process ${proc.pid} has --no-sandbox`);
    assert.equal(proc.cmdline.includes('--disable-setuid-sandbox'), false, `Process ${proc.pid} has --disable-setuid-sandbox`);
  }
  const zygotes = tree.filter((p) => p.cmdline.includes('--type=zygote'));
  const renderers = tree.filter((p) => p.cmdline.includes('--type=renderer'));
  assert.ok(zygotes.length > 0, 'Expected at least one --type=zygote process');
  assert.ok(renderers.length > 0, 'Expected at least one --type=renderer process');
  for (const renderer of renderers) {
    assert.equal(renderer.seccomp, '2', `Expected Seccomp: 2 (filter) on renderer ${renderer.pid}, got ${renderer.seccomp}`);
    assert.equal(renderer.noNewPrivs, '1', `Expected NoNewPrivs: 1 on renderer ${renderer.pid}, got ${renderer.noNewPrivs}`);
  }
  browserEvidence = {
    shouldEnableChromiumSandbox: shouldEnableChromiumSandbox(),
    rootPid: procInfo.pid,
    rootStartTime: procInfo.startTime,
    rootExe,
    screenshotBytes,
    zygoteCount: zygotes.length,
    rendererCount: renderers.length,
    processTree: tree,
  };
} finally {
  await manager.close();
}

const inotifyRoot = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'preflight-inotify-')));
fs.chmodSync(inotifyRoot, 0o700);
for (const dir of ['.qa-state', 'qa-reports', 'src', 'test']) {
  fs.mkdirSync(path.join(inotifyRoot, dir), { mode: 0o700 });
}
let inotifyEvidence: Record<string, unknown> = {};
try {
  const observer = await observeQAWrites(inotifyRoot);
  const tmpFile = path.join(inotifyRoot, '.qa-state', 'probe.tmp');
  const finalFile = path.join(inotifyRoot, '.qa-state', 'probe.json');
  fs.writeFileSync(tmpFile, '{"ok":true}\n', { mode: 0o600 });
  fs.renameSync(tmpFile, finalFile);
  const observation = observer.stop();
  const verdict = qaWriteVerdict(observation, 'qa-only');
  assert.equal(observation.complete, true);
  assert.ok(observation.events.length >= 2);
  assert.deepEqual(verdict, []);
  inotifyEvidence = {
    complete: observation.complete,
    eventCount: observation.events.length,
    events: observation.events,
    verdict,
  };
} finally {
  fs.rmSync(inotifyRoot, { recursive: true, force: true });
}

if (process.env.GSTACK_PREFLIGHT_EVIDENCE) {
  fs.writeFileSync(
    process.env.GSTACK_PREFLIGHT_EVIDENCE,
    JSON.stringify({ browser: browserEvidence, inotify: inotifyEvidence }, null, 2) + '\n',
    { mode: 0o600 },
  );
}
console.log('ACTUAL_SANDBOXED_BROWSE_PREFLIGHT_PASS');
