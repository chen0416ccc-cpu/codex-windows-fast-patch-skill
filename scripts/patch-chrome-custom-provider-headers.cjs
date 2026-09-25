const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const PROFILES = [
  { id: '26.917.71314', originalSha256: '2f5dbc3004622917776e033cc179d94fe778ca9ffc7b7375738471947474bcff', policy: 'zD', insertBefore: 'function kX(t){' },
  { id: '26.908.40834', originalSha256: '3b173421bc39677842ac1005be84c9c60c15e4c574598fc5b1324eac05b03ecd', policy: 'cD', insertBefore: 'function wK(e){' },
  { id: '26.908.70816', originalSha256: 'dc969a0d9062bb21ea124c672dd05fdc1034cfe314cf31357a192474426903b3', policy: 'cD', insertBefore: 'function wK(e){' },
];
const MARKER = 'CODEX_CHROME_CUSTOM_PROVIDER_HEADERS_V1';
const CALL_OLD = 'await this.readRequestHeaderEnabled()';
const CALL_NEW = 'await this.readRequestHeaderEnabled(this.clientInfo)';
const BIND_NEW = 'this.turnEndedTracker,clientInfo=>codexChromeCustomProviderHeadersV1(this.runtime,clientInfo))';
function getHelper(profile) {
  return `/*${MARKER}*/
async function codexChromeCustomProviderHeadersV1(runtime, clientInfo) {
  try {
    return await ${profile.policy}();
  } catch (error) {
    const message = typeof error === "string" ? error : error?.message;
    if (message !== "Codex auth token is unavailable" ||
        clientInfo?.type !== "extension" ||
        (clientInfo.family ?? "chrome") !== "chrome" ||
        typeof clientInfo.agentRequestHeaderEnabled !== "boolean") throw error;
    let config;
    try {
      config = (await runtime.config.readAll())?.config;
    } catch {
      throw error;
    }
    const provider = config?.model_provider;
    const providers = config?.model_providers;
    if (typeof provider !== "string" || !provider.trim() || provider === "openai" ||
        !providers || !Object.prototype.hasOwnProperty.call(providers, provider) ||
        providers[provider]?.requires_openai_auth !== false) throw error;
    console.warn("${MARKER}: agent_request_header_enabled=true");
    return true;
  }
}
`;
}

function getOldBinding(profile) { return `this.turnEndedTracker,${profile.policy})`; }

function hash(bytes) { return crypto.createHash('sha256').update(bytes).digest('hex'); }
function replaceOnce(text, before, after) {
  const first = text.indexOf(before);
  if (first < 0 || text.indexOf(before, first + before.length) >= 0) {
    throw new Error(`Expected exactly one patch anchor: ${before}`);
  }
  return text.slice(0, first) + after + text.slice(first + before.length);
}
function patchOriginal(text, profile) {
  if (hash(Buffer.from(text)) !== profile.originalSha256) throw new Error('Unsupported browser-service SHA-256; no files changed.');
  let result = replaceOnce(text, CALL_OLD, CALL_NEW);
  result = replaceOnce(result, getOldBinding(profile), BIND_NEW);
  return replaceOnce(result, profile.insertBefore, getHelper(profile) + profile.insertBefore);
}
function inspect(bytes, {allowUnsupported = false} = {}) {
  const text = bytes.toString('utf8');
  const sha256 = hash(bytes);
  const profile = PROFILES.find(candidate => candidate.originalSha256 === sha256);
  if (profile) {
    const patched = patchOriginal(text, profile);
    return { state: 'original', profile: profile.id, original: text, patched, originalSha256: sha256, patchedSha256: hash(Buffer.from(patched)) };
  }
  if (!text.includes(MARKER)) {
    if (allowUnsupported) return {state: 'unsupported', sha256};
    throw new Error('Unsupported browser-service SHA-256; no files changed.');
  }
  for (const candidate of PROFILES) {
    try {
      let original = replaceOnce(text, getHelper(candidate), '');
      original = replaceOnce(original, CALL_NEW, CALL_OLD);
      original = replaceOnce(original, BIND_NEW, getOldBinding(candidate));
      if (hash(Buffer.from(original)) !== candidate.originalSha256 || patchOriginal(original, candidate) !== text) continue;
      return { state: 'patched', profile: candidate.id, original, patched: text, originalSha256: candidate.originalSha256, patchedSha256: sha256 };
    } catch {
      // A different profile can share the policy name but not the complete file hash.
    }
  }
  throw new Error('Partial, mixed, or modified compatibility patch or anchor; no files changed.');
}
function applyFile(input, output, backupRoot) {
  const inputPath = path.resolve(input);
  const outputPath = path.resolve(output);
  const originalBytes = fs.readFileSync(inputPath);
  const info = inspect(originalBytes);
  const existing = fs.existsSync(outputPath) ? fs.readFileSync(outputPath) : null;
  if (existing && hash(existing) === info.patchedSha256) {
    return {state: 'already-patched', input: inputPath, output: outputPath, sha256: info.patchedSha256};
  }
  if (existing && hash(existing) !== info.originalSha256) throw new Error('Refusing to overwrite an unrelated destination.');
  const resolvedOutput = fs.existsSync(outputPath) ? fs.realpathSync(outputPath) : path.join(fs.realpathSync(path.dirname(outputPath)), path.basename(outputPath));
  if (/[\\/]WindowsApps[\\/]/i.test(resolvedOutput)) throw new Error('Never patch an installed WindowsApps package in place.');
  if (existing && !backupRoot) throw new Error('A backup directory is required before replacing an existing file.');
  const temporary = `${outputPath}.codex-stage-${crypto.randomUUID()}.mjs`;
  let backup = null;
  try {
    fs.writeFileSync(temporary, info.patched, {flag: 'wx'});
    const check = spawnSync(process.execPath, ['--check', temporary], {encoding: 'utf8', windowsHide: true});
    if (check.status !== 0) throw new Error(`Patched module syntax check failed: ${check.stderr || check.error || check.status}`);
    if (existing) {
      fs.mkdirSync(backupRoot, {recursive: true});
      backup = path.join(path.resolve(backupRoot), `${Date.now()}-${crypto.randomUUID()}-browser-service.mjs`);
      fs.writeFileSync(backup, existing, {flag: 'wx'});
      if (hash(fs.readFileSync(backup)) !== info.originalSha256) throw new Error('Original backup verification failed.');
      if (hash(fs.readFileSync(outputPath)) !== hash(existing)) throw new Error('Destination changed during preparation; refusing to overwrite it.');
    }
    fs.renameSync(temporary, outputPath);
    if (hash(fs.readFileSync(outputPath)) !== info.patchedSha256) throw new Error('Post-write verification failed.');
    return {state: 'patched', input: inputPath, output: outputPath, originalSha256: info.originalSha256, sha256: info.patchedSha256, backup};
  } finally {
    if (fs.existsSync(temporary)) fs.unlinkSync(temporary);
  }
}

module.exports = { PROFILES, MARKER, getHelper, CALL_OLD, CALL_NEW, BIND_NEW, inspect, applyFile, hash };
if (require.main === module) {
  try {
    const args = process.argv.slice(2);
    const value = name => { const index = args.indexOf(name); return index < 0 ? null : args[index + 1]; };
    const input = value('--input');
    if (!input) throw new Error('Required: --input <browser-service.mjs>; optionally --output <path> --backup-root <directory>.');
    const output = value('--output');
    if (output && args.includes('--probe-source')) throw new Error('--probe-source is read-only.');
    const result = output ? applyFile(input, output, value('--backup-root')) : (() => {
      const {state, profile, sha256, originalSha256, patchedSha256} = inspect(fs.readFileSync(input), {allowUnsupported: args.includes('--probe-source')});
      return {state, profile, sha256, originalSha256, patchedSha256};
    })();
    console.log(JSON.stringify(result));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
