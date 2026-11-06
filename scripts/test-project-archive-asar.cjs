'use strict';

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { rebuildAsar, readHeader, repackAll } = require('./repack-project-archive-asar.cjs');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-asar-layout-'));
const original = path.join(root, 'original.asar');
let checks = 0;
function hash(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }
function createFixture() {
  const shared = Buffer.from('same');
  const other = Buffer.from('other');
  const entry = { size: shared.length, offset: '0', integrity: { algorithm: 'SHA256', hash: hash(shared), blockSize: 4194304, blocks: [hash(shared)] } };
  const header = { files: {
    first: structuredClone(entry), second: structuredClone(entry),
    other: { size: other.length, offset: '4' },
    native: { size: 3, unpacked: true }, alias: { link: 'first' },
  } };
  const json = Buffer.from(JSON.stringify(header));
  const pickle = Buffer.alloc(8 + ((json.length + 3) & ~3));
  pickle.writeUInt32LE(pickle.length - 4, 0);
  pickle.writeUInt32LE(json.length, 4);
  json.copy(pickle, 8);
  const size = Buffer.alloc(8);
  size.writeUInt32LE(4, 0);
  size.writeUInt32LE(pickle.length, 4);
  fs.writeFileSync(original, Buffer.concat([size, pickle, shared, other]));
}
function inspect(file) {
  const fd = fs.openSync(file, 'r');
  try {
    const parsed = readHeader(fd);
    return parsed;
  } finally { fs.closeSync(fd); }
}
function entryBytes(file, parsed, name) {
  const entry = parsed.files.get(name);
  return fs.readFileSync(file).subarray(parsed.dataStart + Number(entry.offset), parsed.dataStart + Number(entry.offset) + entry.size);
}
try {
  createFixture();
  const before = fs.readFileSync(original);
  const output = path.join(root, 'changed.asar');
  const changed = Buffer.from('updated');
  const result = rebuildAsar(original, new Map([['first', changed]]), output);
  const parsed = inspect(output);
  assert.equal(result.files, 5);
  assert.equal(result.unpacked, 1);
  assert.deepEqual(result.changed, ['first']); checks++;
  assert(entryBytes(output, parsed, 'first').equals(changed));
  assert.equal(parsed.files.get('first').integrity.hash, hash(changed)); checks++;
  assert.equal(entryBytes(output, parsed, 'second').toString(), 'same');
  assert.equal(entryBytes(output, parsed, 'other').toString(), 'other'); checks++;
  assert.deepEqual(parsed.files.get('native'), { size: 3, unpacked: true });
  assert.deepEqual(parsed.files.get('alias'), { link: 'first' }); checks++;
  assert(fs.readFileSync(original).equals(before)); checks++;
  const unchanged = path.join(root, 'unchanged.asar');
  rebuildAsar(original, new Map(), unchanged);
  assert(fs.readFileSync(unchanged).equals(before)); checks++;
  const absent = path.join(root, 'must-not-exist.asar');
  assert.throws(() => rebuildAsar(original, new Map([['native', changed]]), absent), /packed file/);
  assert(!fs.existsSync(absent) && !fs.existsSync(absent + '.partial')); checks++;
  assert.throws(() => rebuildAsar(original, new Map([['missing', changed]]), absent), /packed file/);
  assert(!fs.existsSync(absent)); checks++;
  assert.throws(() => rebuildAsar(original, new Map(), original), /differ/);
  assert(fs.readFileSync(original).equals(before)); checks++;
  const extract = path.join(root, 'extract');
  fs.mkdirSync(extract);
  fs.mkdirSync(original + '.unpacked');
  fs.writeFileSync(path.join(original + '.unpacked', 'native'), 'bin-certificate');
  for (const [name, text] of [['first', 'updated'], ['second', 'same'], ['other', 'other'], ['native', 'bin-certificate']]) {
    fs.writeFileSync(path.join(extract, name), text);
  }
  fs.symlinkSync(path.join(extract, 'first'), path.join(extract, 'alias'), 'file');
  const all = path.join(root, 'all.asar');
  repackAll(original, extract, all);
  assert.deepEqual(inspect(all).files.get('native'), {size: 3, unpacked: true});
  assert(entryBytes(all, inspect(all), 'first').equals(changed)); checks++;
  fs.writeFileSync(path.join(extract, 'native'), 'bad');
  assert.throws(() => repackAll(original, extract, absent), /Unpacked file differs/);
  assert(!fs.existsSync(absent)); checks++;
  fs.writeFileSync(path.join(extract, 'native'), 'bin-certificate');
  fs.writeFileSync(path.join(extract, 'extra'), 'unexpected');
  assert.throws(() => repackAll(original, extract, absent), /file set differs/); checks++;
  fs.unlinkSync(path.join(extract, 'extra'));
  fs.unlinkSync(path.join(extract, 'other'));
  assert.throws(() => repackAll(original, extract, absent), /file set differs/); checks++;
  fs.appendFileSync(original, 'trailing');
  assert.throws(() => rebuildAsar(original, new Map(), absent), /trailing bytes/);
  assert(!fs.existsSync(absent)); checks++;
  console.log(JSON.stringify({ checks, preservedUnpackedAndLinks: true, preservedSharedExtents: true }));
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
