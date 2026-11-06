'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {spawnSync} = require('node:child_process');
const path = require('node:path');
const {layouts, restore, transform} = require('./patch-desktop-261029.cjs');
// Select the pinned 24191 profile whose bundle name matches the input file.
const profile = layouts().map(layout => layout.files.find(entry => entry.file.includes('/24191.')))
  .find(entry => path.basename(entry.file) === path.basename(process.argv[2]));
assert(profile, 'Pass a supported 26.1029 24191 bundle');
const input = fs.readFileSync(process.argv[2], 'utf8');
const original = restore(input, profile);
const source = process.argv.includes('--original') ? original : transform(input, profile, ['fixture-model']).source;

function extract(text, start, end) {
  const offset = text.indexOf(start);
  assert(offset >= 0, `Missing ${start}`);
  const finish = text.indexOf(end, offset);
  assert(finish > offset, `Missing ${end}`);
  return text.slice(offset, finish);
}

class BootstrapError extends Error {
  constructor(failureType, cause) { super('bootstrap', {cause}); this.failureType = failureType; }
}
class HttpError extends Error {
  constructor(status, errorCode) { super('http'); this.status = status; this.errorCode = errorCode; }
}
const failureTypes = {CODEX_POST_LOGIN_STATSIG_BOOTSTRAP_FAILURE_TYPE_REQUEST_FAILED: 'request'};

function clock() {
  let now = 0, id = 0;
  const timers = new Map();
  return {
    performance: {now: () => now},
    setTimeout(callback, delay) { const key = ++id; timers.set(key, {at: now + delay, callback}); return key; },
    clearTimeout(key) { timers.delete(key); },
    async advance(ms) {
      const end = now + ms;
      for (;;) {
        for (let i = 0; i < 20; i++) await Promise.resolve();
        const next = [...timers].filter(([, timer]) => timer.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) break;
        now = next[1].at; timers.delete(next[0]); next[1].callback();
      }
      now = end;
      for (let i = 0; i < 20; i++) await Promise.resolve();
    },
    pending: () => timers.size,
  };
}

async function realRequestTimeout() {
  const time = clock();
  let signal, settled = false, failure;
  const context = {...time, AbortController, Error, tQ: BootstrapError,
    c: {CodexPostLoginStatsigBootstrapFailureType: failureTypes},
    tK: {C: 'Codex'}, H: {Ni: (_, requestSignal) => { signal = requestSignal; return new Promise(() => {}); }},
    n_: {fk: HttpError}, nA: {kh: () => true}};
  vm.runInNewContext(extract(source, 'async function tZ(', 'var tJ=') +
    extract(source, 'async function nx(e,t)', 'function nM(e)') + ';globalThis.run=nx', context);
  context.run({systemName: 'Windows'}, {current: 0}).catch(error => { failure = error; }).finally(() => { settled = true; });
  await time.advance(4999);
  assert.equal(settled, false);
  assert.equal(signal.aborted, false);
  await time.advance(1);
  assert.equal(settled, true);
  assert.equal(signal.aborted, true);
  assert(failure instanceof BootstrapError);
  assert.equal(time.pending(), 0);
}

// Execute the shipped adapter timeout and React hook, with only network/React mocked.
async function sdkFallback(platform, ready = false) {
  const time = clock();
  let networkResolve, passedOptions, released = false, networkFinished = false, calls = 0;
  const cached = {source: 'Cache', data: 'cached-gates'};
  const context = {...time, navigator: {platform},
    r(self, _, __, generator) {
      const iterator = generator.call(self);
      return new Promise((resolve, reject) => {
        function step(method, value) {
          let state;
          try { state = iterator[method](value); } catch (error) { reject(error); return; }
          if (state.done) resolve(state.value);
          else Promise.resolve(state.value).then(value => step('next', value), error => step('throw', error));
        }
        step('next');
      });
    }, o: {Storage: {isReady: () => true}}, i: {Log: {debug() {}}}};
  vm.runInNewContext('globalThis.adapter={' + extract(source, '_getDataAsyncImpl(e,t,n){', '_prefetchDataImpl(') + '}', context);
  const adapter = context.adapter;
  adapter.getDataSync = () => cached;
  adapter._fetchAndPrepFromNetwork = () => new Promise(resolve => { networkResolve = resolve; }).then(value => { networkFinished = true; return value; });
  const client = {loadingStatus: ready ? 'Ready' : 'Uninitialized',
    async initializeAsync(options) {
      calls++; passedOptions = options;
      const result = await adapter._getDataAsyncImpl(cached, {}, options);
      this.values = result ?? cached;
      this.loadingStatus = 'Ready';
    }};
  const hookContext = {navigator: {platform},
    r: {_getInstance: () => client, Log: {error(error) { throw error; }}},
    i: {useMemo: callback => callback(), useState: initial => [initial, value => { released = !value; }]}};
  const hook = extract(source, 'useStatsigInternalClientFactoryAsync=function', '},Y3TU(');
  vm.runInNewContext('globalThis.' + hook, hookContext);
  hookContext.useStatsigInternalClientFactoryAsync(() => client, {sdkKey: 'fixture'});
  if (ready) { assert.equal(calls, 0); return; }
  await time.advance(2000);
  if (platform === 'Win32') {
    assert.equal(passedOptions.timeoutMs, 2000);
    assert.equal(released, true);
    assert.equal(client.values, cached);
    assert.equal(client.loadingStatus, 'Ready');
    assert.equal(networkFinished, false);
  } else {
    assert.equal(passedOptions, undefined);
    assert.equal(released, false);
  }
  networkResolve({source: 'Network'});
  await time.advance(0);
  assert.equal(networkFinished, true);
  assert.equal(released, true);
}

async function retryCase(systemName, responses) {
  let elapsed = 0, attempts = 0;
  const context = {tQ: BootstrapError, Error, performance: {now: () => elapsed},
    c: {CodexPostLoginStatsigBootstrapFailureType: failureTypes}, n_: {fk: HttpError}, nA: {kh: () => true},
    setTimeout: (resolve, ms) => {elapsed += ms; resolve();},
    tZ: async options => {
      const response = responses[Math.min(attempts++, responses.length - 1)];
      if (response === 'timeout') {
        elapsed += options.startupTimeoutMs ?? 10000;
        throw new BootstrapError('request', new Error('timeout'));
      }
      if (response instanceof Error) throw new BootstrapError('request', response);
      return response;
    }};
  vm.runInNewContext(extract(source, 'async function nx(e,t)', 'function nM(e)') + ';globalThis.run=nx', context);
  const count = {current: 0};
  let result, error;
  try { result = await context.run({systemName}, count); } catch (caught) { error = caught; }
  return {elapsed, attempts, result, error};
}

(async () => {
  const offline = await retryCase('Windows', ['timeout']);
  assert(offline.elapsed <= 5000, `Windows startup blocked for ${offline.elapsed} ms`);
  assert(offline.error instanceof BootstrapError);
  const success = {statsigPayload: 'server-values'};
  const online = await retryCase('Windows', [success]);
  assert.equal(online.result, success);
  const refresh = await retryCase('Windows', [new HttpError(401), success]);
  assert.equal(refresh.attempts, 2);
  assert.equal(refresh.result, success);
  const denied = await retryCase('Windows', [new HttpError(401, 'ip_not_authorized')]);
  assert.equal(denied.attempts, 1);
  const other = await retryCase('macOS', ['timeout']);
  assert.equal(other.attempts, 6);
  assert.equal(other.elapsed, 62500);
  await realRequestTimeout();
  await sdkFallback('Win32');
  await sdkFallback('MacIntel');
  await sdkFallback('Win32', true);

  const legacy = profile.edits.filter(edit => !edit.kind.startsWith('startup-')).reduce((text, edit) =>
    text.replace(edit.before, () => edit.after.replace('__MODELS_JSON__', '["fixture-model"]')), original);
  const upgraded = transform(legacy, profile, ['fixture-model']);
  assert.equal(transform(upgraded.source, profile, ['fixture-model']).status, 'already-patched');
  assert.throws(() => transform(upgraded.source + 'drift', profile, ['fixture-model']), /Unsupported/);
  const parsed = spawnSync(process.execPath, ['--check', '--input-type=module'], {input: source, encoding: 'utf8'});
  assert.equal(parsed.status, 0, parsed.stderr?.slice(-1000));
  console.log(JSON.stringify({offlineMs: offline.elapsed, online: true, authRefresh: true, deniedPreserved: true,
    nonWindowsUnchanged: true, legacyUpgrade: true, idempotent: true, requestAborted: true,
    fallbackBounded: true, cachedValuesPreserved: true, backgroundFetchContinues: true}));
})().catch(error => { console.error(error); process.exitCode = 1; });
