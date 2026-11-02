const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { transform } = require('./patch-remote-control-native-cache-261027.cjs');
const source = fs.readFileSync(process.argv[2], 'utf8');
const target = 'D:/CodexData/phone-runtime-261027/bin/codex.exe';
const result = transform(source, target);
new vm.Script(result);
assert.throws(() => transform(source, 'C:/CodexData/bin/codex.exe'));
assert.throws(() => transform(source, 'D:/CodexData/../bin/codex.exe'));
assert.throws(() => transform(source + source, target));
const start = result.indexOf('function P(e)'), end = result.indexOf('function A(', start);
assert.ok(start > 0 && end > start);
for (const platform of ['win32', 'linux', 'darwin']) {
  const calls = [];
  const ctx = vm.createContext({ process: { platform }, o: require('node:path').win32,
    g: null, p: new Map(), h: [], F: () => true, U: () => { throw Error('Old C cache used'); },
    v: args => { calls.push(args); return 'fixture-executable'; }, q: () => null, z: () => true });
  vm.runInContext(result.slice(start, end) + ';globalThis.resolve=P;', ctx);
  const value = ctx.resolve('fixture-resources');
  if (platform === 'win32') assert.equal(calls[0].windowsDestinationPath, target);
  if (platform === 'linux') assert.equal(calls[0].windowsDestinationPath, null);
  if (platform === 'darwin') assert.ok(value.includes('CodexCLI.app'));
}
console.log('Native resolver: non-C destination, no global env edits, platform behavior and complete JS parse passed');
