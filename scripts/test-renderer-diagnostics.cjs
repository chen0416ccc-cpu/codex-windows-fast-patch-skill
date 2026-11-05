'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {EventEmitter} = require('node:events');
const {manifest, transform} = require('./patch-desktop-261029.cjs');
const profile = manifest.files.find(p => p.edits.some(e => e.kind === 'startup-renderer-diagnostics'));
const original = fs.readFileSync(path.join(process.argv[2], profile.file), 'utf8');
const source = transform(original, profile, ['fixture']).source;
const start = source.indexOf('installWebContentsDiagnostics(e,t){');
const end = source.indexOf('maybeRecoverFromRendererCrash(e,t){', start);
assert(start > 0 && end > start);
for (const [reason, quitting, expectLog, expectFatal] of [
  ['crashed', false, true, true], ['oom', false, true, true],
  ['killed', false, true, false], ['clean-exit', false, false, false], ['crashed', true, false, false],
]) {
  const logs = [], fatals = [], messages = [];
  const context = {eMU: () => ({warning: (...args) => logs.push(args)})};
  vm.runInNewContext('globalThis.manager={' + source.slice(start, end) + '}', context);
  const manager = context.manager;
  const contents = new EventEmitter(); contents.id = 2;
  const window = {webContents: contents, id: 1};
  Object.assign(manager, {options: {errorReporter: {reportFatal: (...args) => fatals.push(args)}},
    isAppQuitting: quitting, appBadgeCounts: new Map(), appBadgeWindow: null,
    rendererRecoveryAttempts: new Set(), readyWebContentsIds: new Set([2]),
    maybeRecoverFromRendererCrash: () => true, sendMessageToWindow: (_, data) => messages.push(data)});
  manager.installWebContentsDiagnostics(window, 'primary');
  contents.emit('render-process-gone', {}, {reason, exitCode: -1073741819});
  assert.equal(logs.length, Number(expectLog));
  assert.equal(fatals.length, Number(expectFatal));
  assert.equal(messages.length, Number(expectFatal));
  if (expectLog) {
    assert.equal(logs[0][0], 'windows_renderer_process_gone');
    assert.deepEqual(JSON.parse(JSON.stringify(logs[0][1])), {
      safe: {reason, exitCode: -1073741819, windowId: 1, webContentsId: 2, windowAppearance: 'primary'}, sensitive: {},
    });
  }
}
console.log(JSON.stringify({cases: 5, cleanExitSilent: true, recoveryPreserved: true, noUserContent: true}));
