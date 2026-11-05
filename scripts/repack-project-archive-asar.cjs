'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { selectProfiles, relativePath, transform } = require('./patch-project-archive-state.cjs');

function readExact(fd, size, offset) {
  const bytes = Buffer.alloc(size);
  let done = 0;
  while (done < size) {
    const count = fs.readSync(fd, bytes, done, size - done, offset + done);
    assert(count > 0, 'Truncated ASAR');
    done += count;
  }
  return bytes;
}

function readHeader(fd) {
  const prefix = readExact(fd, 16, 0);
  const pickleSize = prefix.readUInt32LE(4);
  const jsonSize = prefix.readUInt32LE(12);
  assert(prefix.readUInt32LE(0) === 4 && jsonSize > 0 && jsonSize <= 32 * 1024 * 1024);
  assert(pickleSize === 8 + ((jsonSize + 3) & ~3), 'Unsupported ASAR pickle');
  const header = JSON.parse(readExact(fd, jsonSize, 16).toString('utf8'));
  const files = new Map();
  function walk(node, prefix = '') {
    for (const [name, entry] of Object.entries(node.files || {})) {
      const rel = prefix + name;
      if (entry.files) walk(entry, rel + '/');
      else files.set(rel, entry);
    }
  }
  walk(header);
  return { header, files, dataStart: 8 + pickleSize };
}

function integrity(bytes) {
  const blockSize = 4 * 1024 * 1024;
  const hash = data => crypto.createHash('sha256').update(data).digest('hex');
  const blocks = [];
  for (let start = 0; start <= bytes.length; start += blockSize) {
    blocks.push(hash(bytes.subarray(start, start + blockSize)));
  }
  return { algorithm: 'SHA256', hash: hash(bytes), blockSize, blocks };
}

function rebuildAsar(original, changes, output) {
  assert(path.resolve(original) !== path.resolve(output), 'Output must differ from source');
  const sourceFd = fs.openSync(original, 'r');
  const temporary = output + '.partial';
  let outFd;
  try {
    const { header, files, dataStart } = readHeader(sourceFd);
    for (const [rel, bytes] of changes) {
      const entry = files.get(rel);
      assert(entry && !entry.unpacked && entry.link === undefined && Buffer.isBuffer(bytes), 'Change must target a packed file');
    }
    const extents = new Map();
    let unpacked = 0;
    for (const [rel, entry] of files) {
      if (entry.unpacked) { unpacked++; continue; }
      if (entry.link !== undefined) continue;
      const offset = Number(entry.offset);
      assert(Number.isSafeInteger(offset) && offset >= 0 && Number.isSafeInteger(entry.size) && entry.size >= 0);
      const key = `${offset}:${entry.size}`;
      if (!extents.has(key)) extents.set(key, { offset, size: entry.size, items: [] });
      extents.get(key).items.push({ rel, entry });
    }
    const ordered = [...extents.values()].sort((a, b) => a.offset - b.offset || a.size - b.size);
    let sourceEnd = 0;
    for (const extent of ordered) {
      if (!extent.size) continue;
      assert(extent.offset === sourceEnd, 'Source extents must tile without gaps or overlaps');
      sourceEnd += extent.size;
    }
    assert(dataStart + sourceEnd === fs.fstatSync(sourceFd).size, 'Unexpected source trailing bytes');
    const writes = [];
    let cursor = 0;
    for (const extent of ordered) {
      const unchanged = extent.items.filter(item => !changes.has(item.rel));
      if (unchanged.length) {
        unchanged.forEach(item => { item.entry.offset = String(cursor); });
        writes.push({ offset: dataStart + extent.offset, size: extent.size });
        cursor += extent.size;
      }
      for (const item of extent.items.filter(item => changes.has(item.rel))) {
        const bytes = changes.get(item.rel);
        item.entry.offset = String(cursor);
        item.entry.size = bytes.length;
        item.entry.integrity = integrity(bytes);
        writes.push({ bytes, size: bytes.length });
        cursor += bytes.length;
      }
    }
    const json = Buffer.from(JSON.stringify(header), 'utf8');
    const pickle = Buffer.alloc(8 + ((json.length + 3) & ~3));
    pickle.writeUInt32LE(pickle.length - 4, 0);
    pickle.writeUInt32LE(json.length, 4);
    json.copy(pickle, 8);
    const size = Buffer.alloc(8);
    size.writeUInt32LE(4, 0);
    size.writeUInt32LE(pickle.length, 4);
    outFd = fs.openSync(temporary, 'wx');
    function writeAll(bytes) {
      let done = 0;
      while (done < bytes.length) done += fs.writeSync(outFd, bytes, done, bytes.length - done);
    }
    writeAll(size);
    writeAll(pickle);
    const buffer = Buffer.allocUnsafe(1024 * 1024);
    for (const write of writes) {
      if (write.bytes) { writeAll(write.bytes); continue; }
      let done = 0;
      while (done < write.size) {
        const count = fs.readSync(sourceFd, buffer, 0, Math.min(buffer.length, write.size - done), write.offset + done);
        assert(count > 0, 'Truncated source extent');
        writeAll(buffer.subarray(0, count));
        done += count;
      }
    }
    assert(fs.fstatSync(outFd).size === 8 + pickle.length + cursor, 'Output size mismatch');
    fs.fsyncSync(outFd);
    fs.closeSync(outFd);
    outFd = undefined;
    fs.renameSync(temporary, output);
    return { files: files.size, unpacked, originalExtents: extents.size, changed: [...changes.keys()], bytes: fs.statSync(output).size };
  } finally {
    fs.closeSync(sourceFd);
    if (outFd !== undefined) fs.closeSync(outFd);
  }
}

function repack(original, patchedRoot, output) {
  const fd = fs.openSync(original, 'r');
  const changes = new Map();
  try {
    const { files, dataStart } = readHeader(fd);
    for (const profile of selectProfiles(rel => files.has(rel))) {
      const rel = relativePath(profile);
      const entry = files.get(rel);
      assert(entry && !entry.unpacked && entry.size <= 24 * 1024 * 1024, 'Missing or invalid pinned asset');
      const source = readExact(fd, entry.size, dataStart + Number(entry.offset)).toString('utf8');
      const transformed = transform(source, profile).source;
      const bytes = fs.readFileSync(path.join(patchedRoot, rel));
      assert(bytes.equals(Buffer.from(transformed, 'utf8')), 'Patched extract differs from pinned transform');
      if (source !== transformed) changes.set(rel, bytes);
    }
  } finally { fs.closeSync(fd); }
  return rebuildAsar(original, changes, output);
}

function repackAll(original, patchedRoot, output) {
  const fd = fs.openSync(original, 'r');
  const changes = new Map();
  try {
    const { files, dataStart } = readHeader(fd);
    const extracted = new Set();
    function walk(root, prefix = '') {
      for (const item of fs.readdirSync(root, { withFileTypes: true })) {
        const rel = prefix + item.name;
        if (item.isDirectory()) walk(path.join(root, item.name), rel + '/');
        else extracted.add(rel);
      }
    }
    walk(patchedRoot);
    assert(extracted.size === files.size && [...files.keys()].every(rel => extracted.has(rel)), 'Extracted file set differs from original ASAR');
    for (const [rel, entry] of files) {
      if (entry.link !== undefined) {
        assert(fs.realpathSync(path.join(patchedRoot, rel)) === fs.realpathSync(path.join(patchedRoot, entry.link)), 'Extracted link differs');
        continue;
      }
      if (entry.unpacked) {
        const source = fs.readFileSync(path.join(original + '.unpacked', rel));
        const bytes = fs.readFileSync(path.join(patchedRoot, rel));
        // Vendor signing can append a certificate after the recorded ASAR size.
        assert(source.equals(bytes), `Unpacked file differs: ${rel}`);
        continue;
      }
      const source = readExact(fd, entry.size, dataStart + Number(entry.offset));
      const bytes = fs.readFileSync(path.join(patchedRoot, rel));
      if (!source.equals(bytes)) changes.set(rel, bytes);
    }
  } finally { fs.closeSync(fd); }
  return rebuildAsar(original, changes, output);
}

module.exports = { rebuildAsar, readHeader, repack, repackAll };
if (require.main === module) {
  const [original, patchedRoot, output, flag] = process.argv.slice(2);
  assert(original && patchedRoot && output && (!flag || flag === '--all'), 'Usage: repack-project-archive-asar.cjs <original.asar> <patched-root> <output.asar> [--all]');
  console.log(JSON.stringify((flag === '--all' ? repackAll : repack)(original, patchedRoot, output)));
}
