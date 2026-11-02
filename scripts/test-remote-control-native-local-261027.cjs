const fs = require('node:fs');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transform } = require('./patch-remote-control-native-local-261027.cjs');
const SOURCE = process.argv[2];
assert.ok(SOURCE, 'Pass the exact extracted original app-initial asset');
const source = fs.readFileSync(SOURCE, 'utf8');
const candidate = transform(source);
new vm.SourceTextModule(candidate);
function take(from, to) {
  const start = candidate.indexOf(from), end = candidate.indexOf(to, start + from.length);
  assert.ok(start > 0 && end > start);
  return candidate.slice(start, end);
}
const helperAndList = take('async function phoneRemoteNativeLocalScope(', 'async function l$r(');
const preflight = take('async function g$r(', 'function _$r(');
const remoteErrorHandler = take('async function HQr(', 'function UQr(');
let passed = 0;
function harness({ account = { type: 'apiKey' }, status = { status: 'connected', environmentId: 'local-env' }, rpcError = null, mfa = 'required', enabled = true } = {}) {
  const calls = [];
  const scope = { query: { snapshot: kind => ({
    invalidate: async () => { calls.push(['invalidate', kind]); },
    fetch: async () => kind === 'mfa' ? mfa : enabled,
  }) } };
  const context = vm.createContext({
    tg: (s, host) => ({ sendRequest: async (method, params) => {
      calls.push([host, method]); if (rpcError) throw Error(rpcError);
      if (method === 'account/read') return { account };
      if (method === 'remoteControl/status/read') return status;
      throw Error('Unexpected method ' + method);
    } }),
    zQr: async () => { calls.push(['browser-list']); return [{ client_id: 'browser' }]; },
    u$r: async (s, host, env) => { calls.push(['native-list', host, env]); return [{ clientId: 'native' }]; },
    d$r: value => ({ clientId: value.client_id }), w$r: 'mfa', T$r: 'enabled',
  });
  vm.runInContext(helperAndList + preflight + ';globalThis.api={list:c$r,preflight:g$r};', context);
  return { api: context.api, scope, calls };
}
async function test(name, fn) { await fn(); passed++; console.log('PASS ' + name); }
(async () => {
  await test('ChatGPT preserves browser and native list', async () => {
    const h = harness({ account: { type: 'chatgpt' } });
    const data = await h.api.list(h.scope, 'main-env');
    assert.equal(JSON.stringify(data), '[{"clientId":"browser"},{"clientId":"native"}]');
    assert.ok(!h.calls.some(c => c[1] === 'remoteControl/status/read'));
  });
  await test('API main uses native local list only', async () => {
    const h = harness(); await h.api.list(h.scope, 'local-env');
    assert.ok(h.calls.some(c => c.join(':') === 'native-list:local:local-env'));
    assert.ok(!h.calls.some(c => c[0] === 'browser-list'));
  });
  await test('No main login may use isolated native scope', async () => {
    const h = harness({ account: null }); await h.api.list(h.scope, null);
    assert.ok(h.calls.some(c => c[0] === 'native-list'));
  });
  await test('SSH host does not use local isolated routing', async () => {
    const h = harness(); await h.api.list(h.scope, 'ssh-env', { appServerHostId: 'ssh' });
    assert.deepEqual(h.calls, [['native-list', 'ssh', 'ssh-env']]);
  });
  for (const state of ['disabled', 'connecting', 'errored']) {
    await test('No false devices or preflight success while ' + state, async () => {
      const h = harness({ status: { status: state } });
      assert.equal((await h.api.list(h.scope, null)).length, 0);
      await assert.rejects(h.api.preflight(h.scope));
    });
  }
  await test('Missing native environment fails closed', async () => {
    const h = harness({ status: { status: 'connected' } });
    await assert.rejects(h.api.list(h.scope, null)); await assert.rejects(h.api.preflight(h.scope));
  });
  await test('Different environment is not silently replaced', async () => {
    const h = harness(); await assert.rejects(h.api.list(h.scope, 'another-env'));
  });
  await test('Unknown account mode fails closed', async () => {
    const h = harness({ account: { type: 'unsupported' } }); await assert.rejects(h.api.list(h.scope, null));
  });
  await test('RPC policy/auth error is propagated', async () => {
    const h = harness({ rpcError: 'managed requirement denied' });
    await assert.rejects(h.api.list(h.scope, null), /managed requirement denied/);
  });
  for (const enabled of [true, false]) {
    await test('ChatGPT MFA enabled=' + enabled + ' retains official check', async () => {
      const h = harness({ account: { type: 'chatgpt' }, enabled });
      assert.equal(await h.api.preflight(h.scope), !enabled);
      assert.ok(h.calls.some(c => c.join(':') === 'invalidate:mfa'));
    });
  }
  await test('Isolated preflight delegates pairing to native backend', async () => {
    const h = harness(); assert.equal(await h.api.preflight(h.scope), false);
    assert.ok(!h.calls.some(c => c[0] === 'invalidate'));
  });
  await test('Unknown and duplicated bundles are rejected', async () => {
    assert.throws(() => transform('unknown'));
    assert.throws(() => transform(source + source));
    assert.throws(() => transform(candidate));
  });
  assert.ok(!helperAndList.includes('access_token'));
  await test('Remote 401 cannot invalidate global login', async () => {
    class HttpError extends Error { constructor(status) { super('fixture'); this.status = status; } }
    class RemoteAuthError extends Error {}
    class RemoteForbidden extends Error {}
    let invalidations = 0;
    const ctx = vm.createContext({ Yg: HttpError, qQr: RemoteAuthError, YQr: RemoteForbidden,
      JQr: class extends Error {}, XQr: class extends Error {}, UQr: () => false,
      Fpt: () => { invalidations++; } });
    vm.runInContext(remoteErrorHandler + ';globalThis.handler=HQr;', ctx);
    await assert.rejects(ctx.handler(async () => { throw new HttpError(401); }), RemoteAuthError);
    await assert.rejects(ctx.handler(async () => { throw new HttpError(403); }), RemoteForbidden);
    assert.equal(await ctx.handler(async () => 'ok'), 'ok');
    assert.equal(invalidations, 0);
  });
  assert.ok(!helperAndList.includes('fetch('));
  const init = take('function O$r()', 'var k$r,');
  const setup = fs.readFileSync(SOURCE.replace('app-initial-4267e52fe5b0.js', 'codex-mobile-setup-flow-ba21e4103d3b.js'), 'utf8');
  function queryHarness({ account = { type: 'apiKey' }, status = { status: 'connected', environmentId: 'local-env' }, flag = true, upgrade = false, enabled = true } = {}) {
    const calls = [];
    const scope = {};
    const ctx = vm.createContext({ Q: {}, t: fn => fn, Z() {}, rg() {}, ZQr() {}, s$r() {}, m$r() {}, W() {}, Ub() {}, Dg() {}, Yt() {},
      Ft: (q, fn) => fn, Ac: (q, fn) => fn, Tg: 'gate', Hz: 'status', o$r: 'enabled', Rn: 'local',
      tg: (s, host) => ({ sendRequest: async (method) => {
        calls.push([host, method]);
        if (method === 'account/read') return { account };
        if (method === 'remoteControl/status/read') return status;
        if (method === 'remoteControl/pairing/start') return { pairingCode: 'server-fixture' };
        throw Error(method);
      } }),
      IQr: async () => { calls.push(['official-mfa']); return 'required'; }, LQr() {},
      u$r: async () => { calls.push(['native-list']); return [{ clientId: 'test' }]; },
      RQr: async () => { calls.push(['browser-resume']); return false; },
      t$r: async () => { calls.push(['wait-connected']); if (status.status !== 'connected') throw Error('not connected'); },
    });
    vm.runInContext(helperAndList + init + ';O$r();globalThis.factories={mfa:w$r,resume:E$r,pair:D$r};', ctx);
    const get = (atom, id) => atom === 'gate' ? id === '2055603567' ? flag : upgrade : atom === 'status' ? status : enabled;
    return { calls, ctx, factories: ctx.factories, args: { get, scope } };
  }
  await test('Automatic API MFA query does not use browser or claim MFA enabled', async () => {
    const h = queryHarness();
    assert.equal(await h.factories.mfa(h.args).queryFn(), null);
    assert.ok(!h.calls.some(c => c[0] === 'official-mfa'));
  });
  await test('Automatic ChatGPT MFA query retains backend requirement', async () => {
    const h = queryHarness({ account: { type: 'chatgpt' } });
    assert.equal(await h.factories.mfa(h.args).queryFn(), 'required');
    assert.ok(h.calls.some(c => c[0] === 'official-mfa'));
  });
  await test('API resume uses native clients even if legacy display flag is off', async () => {
    const h = queryHarness({ flag: false });
    assert.equal(await h.factories.resume(h.args).queryFn(), true);
    assert.ok(!h.calls.some(c => c[0] === 'browser-resume'));
  });
  await test('Pairing retains rollout upgrade and host enable gates', async () => {
    for (const [flag, upgrade, enabled] of [[false, false, true], [true, true, true], [true, false, false], [true, false, true]]) {
      const h = queryHarness({ flag, upgrade, enabled });
      const q = h.factories.pair({ hostId: 'local', openId: 'test' }, h.args);
      assert.equal(q.enabled, flag && !upgrade && enabled);
      if (q.enabled) {
        assert.equal((await q.queryFn()).pairingCode, 'server-fixture');
        assert.ok(h.calls.findIndex(c => c[0] === 'wait-connected') < h.calls.findIndex(c => c[1] === 'remoteControl/pairing/start'));
      }
    }
  });
  await test('Pair query cannot proceed before actual Connected status', async () => {
    const h = queryHarness({ status: { status: 'connecting' } });
    await assert.rejects(h.factories.pair({ hostId: 'local', openId: 'test' }, h.args).queryFn());
    assert.ok(!h.calls.some(c => c[1] === 'remoteControl/pairing/start'));
  });
  await test('Catalog environment change refreshes local device query key', async () => {
    const start = setup.indexOf('mn=s(oe,'), end = setup.indexOf(',hn=we(', start);
    assert.ok(start > 0 && end > start);
    const ctx = vm.createContext({ s: (q, fn) => fn, oe: {}, Ue: 'catalog-env', qe: 'gate', pn: 30000, At() {} });
    vm.runInContext('var ' + setup.slice(start, end) + ';globalThis.factory=mn;', ctx);
    const make = env => ctx.factory({ get: atom => atom === 'catalog-env' ? env : true, scope: {} });
    assert.notEqual(JSON.stringify(make(null).queryKey), JSON.stringify(make('new-environment').queryKey));
  });
  console.log(JSON.stringify({ passed, failed: 0 }));
})().catch(error => { console.error(error.stack); process.exitCode = 1; });
