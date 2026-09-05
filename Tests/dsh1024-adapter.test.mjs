import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, cp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createServer } from 'node:http';

test('real store routes prepare native operations without modifying the live profile', async () => {
  const root = await mkdtemp(join(tmpdir(), 'harness-store-test-'));
  const previousHome = process.env.DSH_HOME;
  const previousFetch = globalThis.fetch;
  let server;
  try {
    const pkg = join(root, 'dsh1024');
    await cp(resolve('Resources/runtime/default-profile/profiles/web/node_modules/dsh1024'), pkg, { recursive: true });
    await cp(resolve('Resources/dsh1024-launcher'), pkg, { recursive: true });
    process.env.DSH_HOME = join(root, 'home');
    const profile = join(process.env.DSH_HOME, 'profiles/web');
    await mkdir(profile, { recursive: true });
    const manifest = JSON.stringify({ dependencies: { 'fixture-plugin': '1.0.0' } });
    await writeFile(join(profile, 'package.json'), manifest);
    const update = await import(pathToFileURL(join(pkg, 'lib/update.js')));
    globalThis.fetch = () => { throw new Error('self-update must not use the network'); };
    assert.equal((await update.checkForUpdate()).updateAvailable, false);
    globalThis.fetch = previousFetch;
    const { mountMarketRoutes } = await import(pathToFileURL(join(pkg, 'lib/routes.js')));
    const handlers = new Map();
    const dispose = mountMarketRoutes({ register: route => {
      handlers.set(route.path, route.handler); return () => handlers.delete(route.path);
    } }, { profile: 'web', registryUrl: 'https://example.invalid/registry', updateUrl: 'https://example.invalid/update', embedUrl: 'https://deepseek1024.com/embed/store', sidebarEntry: true });
    server = createServer((request, response) => handlers.get(request.url)?.(request, response));
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const origin = `http://127.0.0.1:${server.address().port}`;
    const post = async (path, body) => {
      const response = await fetch(origin + path, { method: 'POST', headers: { origin, 'content-type': 'application/json' }, body: JSON.stringify(body) });
      return { status: response.status, body: await response.json() };
    };
    const install = await post('/dsh1024/install', { id: 'fixture/plugin', command: 'dsh plugin --profile web add fixture-plugin@1.0.0' });
    assert.equal(install.body.managedByLauncher, true);
    assert.deepEqual(install.body.launcherCommand, ['plugin', '--profile', 'web', 'add', 'fixture-plugin@1.0.0']);
    assert.notEqual(install.body.ok, true);
    assert.equal(await readFile(join(profile, 'package.json'), 'utf8'), manifest);
    const self = await post('/dsh1024/self-update', {});
    assert.equal(self.status, 409);
    assert.equal(self.body.ok, false);
    assert.equal((await post('/dsh1024/install', { id: 'fixture/plugin', command: 'dsh plugin --profile web add x; touch /tmp/x' })).status, 400);
    dispose();
  } finally {
    if (server) await new Promise(resolve => server.close(resolve));
    globalThis.fetch = previousFetch;
    if (previousHome === undefined) delete process.env.DSH_HOME; else process.env.DSH_HOME = previousHome;
    await rm(root, { recursive: true, force: true });
  }
});
