'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { readHeader, rebuildAsar } = require('./repack-project-archive-asar.cjs');

const file = '.vite/build/early-bootstrap-339-f66dad1753c54789.js';
const originalHash = '862a1b283e239cda5eb840e39b822b8dfbfffe12427dc765539579ecc526cca0';
const before = 'ed&&r.app.on("second-instance",(t,n,r,i)=>{"object"==typeof i&&null!=i&&"startupTask"in i&&!0===i.startupTask||e.queueSecondInstanceArgs(n)})';
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

function installReopenGuard(app, platform, dispatch, log) {
  let quitting = false;
  let relaunchScheduled = false;
  if (platform === 'win32') {
    const relaunch = app.relaunch;
    app.relaunch = function (...args) {
      const result = Reflect.apply(relaunch, this, args);
      relaunchScheduled = true;
      return result;
    };
    // will-quit runs after close cancellation checks and before async cleanup.
    app.on('will-quit', () => { quitting = true; });
  }
  app.on('second-instance', (_event, argv, _cwd, additionalData) => {
    if (additionalData && additionalData.startupTask === true) return;
    if (quitting) {
      if (!relaunchScheduled) {
        app.relaunch({ args: argv.slice(1) });
        log();
      }
      return;
    }
    dispatch(argv);
  });
}

const after = 'ed&&(' + installReopenGuard.toString().replace(/\r\n/g, '\n') + ')(r.app,process.platform,n=>e.queueSecondInstanceArgs(n),()=>{(0,i.tZQ)().info("windows_reopen_queued_during_quit")})';

function transform(source) {
  if (source.includes(after)) {
    const restored = source.replace(after, before);
    assert.equal(hash(restored), originalHash, 'Unsupported modified Windows reopen asset');
    return {source, status: 'already-patched'};
  }
  assert.equal(hash(source), originalHash, 'Unsupported Windows reopen asset');
  assert.equal(source.split(before).length, 2, 'Expected one second-instance handler');
  return {source: source.replace(before, () => after), status: 'patched'};
}

function patchAsar(input, output) {
  const fd = fs.openSync(input, 'r');
  let result;
  try {
    const {files, dataStart} = readHeader(fd);
    const entry = files.get(file);
    assert(entry && !entry.unpacked && !entry.link, 'Unsupported Windows reopen layout');
    const bytes = Buffer.alloc(entry.size);
    assert.equal(fs.readSync(fd, bytes, 0, bytes.length, dataStart + Number(entry.offset)), bytes.length);
    result = transform(bytes.toString('utf8'));
  } finally { fs.closeSync(fd); }
  assert.notEqual(path.resolve(input), path.resolve(output), 'Preserve the source ASAR');
  const rebuilt = rebuildAsar(input, new Map([[file, Buffer.from(result.source)]]), output);
  return {...rebuilt, status: result.status, assetSha256: hash(result.source)};
}

module.exports = {file, originalHash, before, after, installReopenGuard, transform, patchAsar};
if (require.main === module) {
  const [input, output] = process.argv.slice(2);
  assert(input && output, 'Usage: patch-windows-reopen.cjs <source.asar> <output.asar>');
  console.log(JSON.stringify(patchAsar(input, output)));
}
