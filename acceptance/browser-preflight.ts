import assert from 'node:assert/strict';
const { BrowserManager, shouldEnableChromiumSandbox } = await import(process.cwd() + '/browse/src/browser-manager.ts');
assert.equal(process.platform, 'linux');
assert.equal(process.arch, 'x64');
assert.equal(shouldEnableChromiumSandbox(), true);
const manager = new BrowserManager();
try {
  await manager.launch();
  const page = manager.getPage();
  await page.setContent('<title>Gstack acceptance</title><h1>Owned Linux fixture</h1>');
  assert.equal(await page.title(), 'Gstack acceptance');
  assert.ok((await page.screenshot()).length > 0);
  console.log('ACTUAL_SANDBOXED_BROWSE_PREFLIGHT_PASS');
} finally { await manager.close(); }
