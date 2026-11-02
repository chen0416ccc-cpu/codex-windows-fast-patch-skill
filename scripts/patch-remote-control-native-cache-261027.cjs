const crypto = require('node:crypto');
const BEFORE = 'r="win32"===process.platform?U(["OpenAI","Codex","bin","codex.exe"]):null';
function transform(source, destination) {
  if (crypto.createHash('sha256').update(source).digest('hex') !== 'a785e3304e4e229cb5779d952475483e306bcf9ca7b34b8f21df15cea55c648a') throw Error('Unknown 26.1027 native resolver hash');
  if (!/^[D-Z]:\/(?:[A-Za-z0-9_-]+\/)+codex\.exe$/.test(destination)) throw Error('Require an explicit ordinary non-C local destination');
  if (source.split(BEFORE).length !== 2) throw Error('Unknown or duplicate native resolver anchor');
  return source.replace(BEFORE, 'r="win32"===process.platform?' + JSON.stringify(destination) + ':null');
}
module.exports = { transform };
