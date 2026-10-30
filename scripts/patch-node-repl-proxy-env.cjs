const fs = require('node:fs');

const marker = 'CODEX_NODE_REPL_PROXY_ENV_V1';
const proxyNames = ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
  'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy'];
const original = /let ([A-Za-z_$][\w$]*)=([`"'])CODEX_WINDOWS_REGISTERED_CORE\2;([A-Za-z_$][\w$]*)=\[\.\.\.new Set\(\[\.\.\.([A-Za-z_$][\w$]*),\1\]\)\];/g;
const patched = /let ([A-Za-z_$][\w$]*)=`CODEX_WINDOWS_REGISTERED_CORE`;([A-Za-z_$][\w$]*)=\[\.\.\.new Set\(\[\.\.\.([A-Za-z_$][\w$]*),\1,\.\.\.(\[[^\]]+\])\.filter\(e=>process\.env\[e\]\)\]\)\];\/\*CODEX_NODE_REPL_PROXY_ENV_V1\*\//g;

function patchSource(source) {
  const before = [...source.matchAll(original)];
  const after = [...source.matchAll(patched)];
  const markers = source.split(marker).length - 1;
  if (markers || after.length) {
    if (markers === 1 && after.length === 1 && before.length === 0 &&
        JSON.stringify(JSON.parse(after[0][4])) === JSON.stringify(proxyNames)) {
      return { source, status: 'already-patched' };
    }
    throw new Error('incomplete or ambiguous Node REPL proxy environment patch');
  }
  if (!source.includes('CODEX_WINDOWS_REGISTERED_CORE')) {
    return { source, status: 'not-applicable' };
  }
  if (before.length !== 1) {
    throw new Error('Node REPL registered-core environment anchor must occur exactly once');
  }
  const [, name, , target, inherited] = before[0];
  const replacement = `let ${name}=\`CODEX_WINDOWS_REGISTERED_CORE\`;${target}=[...new Set([...${inherited},${name},...${JSON.stringify(proxyNames)}.filter(e=>process.env[e])])];/*${marker}*/`;
  return { source: source.replace(original, () => replacement), status: 'patched' };
}

module.exports = { patchSource };
if (require.main === module) {
  try {
    const file = process.argv[2];
    const before = fs.readFileSync(file, 'utf8');
    const result = patchSource(before);
    if (result.source !== before) fs.writeFileSync(file, result.source);
    process.stdout.write(result.status);
  } catch (error) {
    process.stderr.write(error.message + '\n');
    process.exitCode = 2;
  }
}
