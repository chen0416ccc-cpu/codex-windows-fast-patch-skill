'use strict';

const assert = require('node:assert/strict');
const {EventEmitter} = require('node:events');
const fs = require('node:fs');
const vm = require('node:vm');
const {installReopenGuard, before, after, transform} = require('./patch-windows-reopen.cjs');

// Git's Windows checkout must generate the same asset as an LF checkout.
const crlfModule = {exports:{}};
const patcherSource = fs.readFileSync(require.resolve('./patch-windows-reopen.cjs'), 'utf8');
vm.runInNewContext(patcherSource.replace(/\r?\n/g, '\r\n'), {
  require, module:crlfModule, Buffer, console, process
});
assert.equal(crlfModule.exports.after, after, 'Checkout line endings must not change the patch');

function scenario(install, platform = 'win32') {
  const app = new EventEmitter();
  const opens = [], relaunches = [], logs = [];
  app.relaunch = function(options) { assert.equal(this, app); relaunches.push(options); return 7; };
  install(app, platform, argv => opens.push(argv), () => logs.push('queued'));
  const second = (argv = ['ChatGPT.exe', '--chatgpt-shell=example'], data = {}) =>
    app.emit('second-instance', {}, argv, 'C:\\', data);
  return {app, opens, relaunches, logs, second};
}

const nativeInstall = (app, _platform, dispatch) => vm.runInNewContext(before, {
  ed: true, r: {app}, e: {queueSecondInstanceArgs: dispatch}
});
const native = scenario(nativeInstall);
native.app.emit('will-quit', {preventDefault(){}});
native.second();
assert.equal(native.relaunches.length, 0, 'Native code loses reopening during cleanup');
assert.equal(native.opens.length, 1, 'Native code dispatches into the quitting instance');

const live = scenario(installReopenGuard);
live.second();
assert.equal(live.opens.length, 1);
live.second(['ChatGPT.exe'], {startupTask: true});
assert.equal(live.opens.length, 1);
live.app.emit('before-quit', {preventDefault(){}});
live.second();
assert.equal(live.opens.length, 2, 'A cancelled quit can still activate');
live.app.emit('will-quit', {preventDefault(){}});
live.second(['ChatGPT.exe', 'codex://thread/test', 'D:\\project with spaces']);
live.second();
assert.equal(live.opens.length, 2);
assert.deepEqual(live.relaunches, [{args: ['codex://thread/test', 'D:\\project with spaces']}]);
assert.equal(live.logs.length, 1);

const scheduled = scenario(installReopenGuard);
assert.equal(scheduled.app.relaunch({args:['--existing-update']}), 7);
scheduled.app.emit('will-quit', {});
scheduled.second();
assert.equal(scheduled.relaunches.length, 1, 'Existing updater relaunch stays unique');
const startup = scenario(installReopenGuard);
startup.app.emit('will-quit', {});
startup.second(['ChatGPT.exe'], {startupTask:true});
assert.equal(startup.relaunches.length, 0);
for (const platform of ['darwin', 'linux']) {
  const other = scenario(installReopenGuard, platform);
  other.app.emit('will-quit', {});
  other.second();
  assert.equal(other.opens.length, 1);
  assert.equal(other.relaunches.length, 0);
}
const emitted = scenario((app, platform, dispatch, log) => vm.runInNewContext(after, {
  ed:true, r:{app}, process:{platform}, e:{queueSecondInstanceArgs:dispatch}, i:{tZQ:()=>({info:log})}
}));
emitted.app.emit('will-quit', {});
emitted.second();
assert.equal(emitted.relaunches.length, 1, 'The injected call site uses the guard');
if (process.argv[2]) {
  const source = fs.readFileSync(process.argv[2], 'utf8');
  const result = transform(source);
  assert.equal(transform(result.source).status, 'already-patched');
  assert.throws(()=>transform(source+'drift'), /Unsupported/);
  assert.throws(()=>transform(result.source+'drift'), /Unsupported/);
  new vm.Script(result.source);
}
console.log(JSON.stringify({nativeRaceReproduced:true,queuedRelaunch:true,duplicateClicks:true,
  existingRelaunch:true,cancelledQuit:true,startupTaskIgnored:true,otherPlatforms:true,injectedCallSite:true}));
