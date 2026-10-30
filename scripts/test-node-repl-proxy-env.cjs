const assert = require('node:assert/strict');
const vm = require('node:vm');
const { patchSource } = require('./patch-node-repl-proxy-env.cjs');

const source = 'function build(n,s,d,cli){let p=n;if(s===`win32`&&!d&&cli!=null){let e=`CODEX_WINDOWS_REGISTERED_CORE`;p=[...new Set([...n,e])];}return p}';
const result = patchSource(source);
assert.equal(result.status, 'patched');
assert.equal(patchSource(result.source).status, 'already-patched');
assert.equal(patchSource(result.source).source, result.source);
let cases = 0;
for (const platform of ['win32', 'darwin', 'linux']) {
  for (const wsl of [false, true]) {
    for (const cli of [null, 'codex.exe']) {
      const env = { HTTPS_PROXY: 'http://proxy.invalid:8080', NO_PROXY: 'localhost',
        HTTP_PROXY: '', API_KEY: 'must-not-be-inherited' };
      const context = vm.createContext({ process: { env } });
      vm.runInContext(result.source, context);
      const inherited = ['EXISTING', 'HTTPS_PROXY'];
      const output = Array.from(context.build(inherited, platform, wsl, cli));
      const expected = platform === 'win32' && !wsl && cli !== null
        ? ['EXISTING', 'HTTPS_PROXY', 'CODEX_WINDOWS_REGISTERED_CORE', 'NO_PROXY']
        : inherited;
      assert.deepEqual(output, expected);
      assert.deepEqual(inherited, ['EXISTING', 'HTTPS_PROXY']);
      cases++;
    }
  }
}
assert.equal(patchSource('function legacy(){return {env_vars:[]}}').status, 'not-applicable');
assert.throws(() => patchSource(source + source), /exactly once/);
assert.throws(() => patchSource(source.replace('...n,e', '...n,e,extra')), /exactly once/);
assert.throws(() => patchSource(source + '/*CODEX_NODE_REPL_PROXY_ENV_V1*/'), /incomplete/);
assert.throws(() => patchSource(result.source.replace('HTTPS_PROXY', 'OTHER')), /incomplete/);
console.log(`NODE_REPL_PROXY_ENV_TESTS_PASSED behavior_cases=${cases} guard_cases=5`);

// Webpack's early-bootstrap emits double quotes; retain the exact local binding guard.
for (const quote of ['"', "'"]) {
  const fixture = source.replace('`CODEX_WINDOWS_REGISTERED_CORE`', quote + 'CODEX_WINDOWS_REGISTERED_CORE' + quote);
  const patched = patchSource(fixture);
  assert.equal(patched.status, 'patched');
  assert.equal(patched.source, result.source);
  assert.equal(patchSource(patched.source).status, 'already-patched');
  assert.throws(() => patchSource(fixture + source), /exactly once/);
  assert.throws(() => patchSource(fixture.replace('...n,e', '...n,wrong')), /exactly once/);
}
assert.throws(() => patchSource(source.replace('`CODEX_WINDOWS_REGISTERED_CORE`', '"CODEX_WINDOWS_REGISTERED_CORE`')), /exactly once/);
console.log('NODE_REPL_PROXY_QUOTED_ANCHOR_PASSED quotes=3 mismatch_and_duplicate_guards=5');
