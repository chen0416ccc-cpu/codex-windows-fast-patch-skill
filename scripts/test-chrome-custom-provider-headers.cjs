const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const patcher = require('./patch-chrome-custom-provider-headers.cjs');

const input = process.argv[2];
const temporaryRoot = process.argv[3];
if (!input || !temporaryRoot) throw new Error('Usage: node test-chrome-custom-provider-headers.cjs <original-service> <temporary-root>');
fs.mkdirSync(temporaryRoot, {recursive: true});
const root = fs.mkdtempSync(path.join(temporaryRoot, 'header-compat-'));
const source = fs.readFileSync(input);
const plan = patcher.inspect(source);
const profile = patcher.PROFILES.find(candidate => candidate.id === plan.profile);
const helper = patcher.getHelper(profile);
let checks = 0;
const equal = (actual, expected, label) => { assert.deepEqual(actual, expected, label); checks++; };
const throws = (action, pattern) => { assert.throws(action, pattern); checks++; };
equal(plan.state, 'original', 'fixture is the unmodified supported package');
equal(plan.originalSha256, profile.originalSha256, 'profile is selected by the complete source hash');
if (profile.id === '26.917.71314') {
  equal(plan.patchedSha256, '8886deea23c8ececd5156c2ee4300431307bda9b5e8910f8d82b5241cf4f38da', 'accepted live patch bytes remain unchanged');
}
equal(patcher.inspect(Buffer.from(plan.patched)).state, 'patched', 'complete patch recognized');
equal(patcher.inspect(Buffer.from(plan.patched)).profile, profile.id, 'patched profile remains exact');
equal(patcher.inspect(Buffer.from(plan.patched)).patched, plan.patched, 'idempotence');
throws(() => patcher.inspect(Buffer.from(plan.original + '\n')), /Unsupported/);
throws(() => patcher.inspect(Buffer.from(plan.original + `/*${patcher.MARKER}*/`)), /anchor/);
throws(() => patcher.inspect(Buffer.from(plan.patched.replace(patcher.CALL_NEW, patcher.CALL_OLD))), /anchor/);
throws(() => patcher.inspect(Buffer.from(plan.patched + '\n')), /Partial/);
throws(() => patcher.inspect(Buffer.from(plan.patched.replace(helper, helper + helper))), /anchor/);
equal(patcher.inspect(Buffer.from('future official service'), {allowUnsupported: true}).state, 'unsupported', 'source probe explicitly reports unknown builds');
throws(() => patcher.inspect(Buffer.from(plan.patched + '\n'), {allowUnsupported: true}), /Partial/);
for (const other of patcher.PROFILES.filter(candidate => candidate.policy !== profile.policy)) {
  throws(() => patcher.inspect(Buffer.from(plan.patched.replace(helper, patcher.getHelper(other)))), /Partial/);
}

function between(text, start, end) {
  const a = text.indexOf(start), b = text.indexOf(end, a + start.length);
  if (a < 0 || b < 0) throw new Error('Test source slice not found.');
  return text.slice(a, b);
}
const method = between(plan.patched, 'async sendSessionRequest(r,n){', 'matchesCurrentTurn(r){');
const config = {model_provider: 'openai-custom', model_providers: {'openai-custom': {requires_openai_auth: false}}};
const cases = [];
async function run(name, options = {}) {
  const events = [];
  const failure = new Error(options.error || 'Codex auth token is unavailable');
  const context = vm.createContext({
    console: {warn: message => events.push({event: 'marker', message})},
    [profile.policy]: async () => { events.push({event: 'original-policy'}); if (!options.policySucceeds) throw options.rejectString ? failure.message : failure; return options.policyValue ?? false; },
  });
  const compat = vm.runInContext(helper + '\ncodexChromeCustomProviderHeadersV1', context, {timeout: 1000});
  const runtime = {config: {readAll: async () => {
    events.push({event: 'config-read'});
    if (options.configFails) throw new Error('Config read denied');
    return {config: options.config === undefined ? config : options.config};
  }}};
  const clientInfo = {type: options.type || 'extension', family: options.family === undefined ? 'chrome' : options.family};
  if (!options.missingCapability) clientInfo.agentRequestHeaderEnabled = options.capability === undefined ? false : options.capability;
  const client = {
    clientInfo, requestHeaderEnabled: false,
    getSessionParams: () => ({session_id: 'test-session', turn_id: 'test-turn'}),
    readRequestHeaderEnabled: info => compat(runtime, info),
    sendRequest: async (operation, params) => { events.push({event: 'browser-send', operation, params}); return true; },
  };
  const parsed = vm.runInContext('({' + method + '})', context, {timeout: 1000});
  let error = null;
  try { await parsed.sendSessionRequest.call(client, options.operation || 'getTabs', {test: true}); }
  catch (caught) { error = typeof caught === 'string' ? caught : caught.message; }
  const send = events.find(event => event.event === 'browser-send');
  const result = {name, error, sent: Boolean(send), header: send?.params.agent_request_header_enabled ?? null,
    configReads: events.filter(event => event.event === 'config-read').length,
    markers: events.filter(event => event.event === 'marker').length};
  cases.push(result);
  return result;
}

(async () => {
  const success = await run('custom_provider_without_official_auth');
  equal([success.error, success.sent, success.header, success.configReads, success.markers], [null, true, true, 1, 1]);
  const stringError = await run('string_transport_error_supported', {rejectString: true});
  equal([stringError.error, stringError.sent, stringError.header], [null, true, true]);
  const policyFalse = await run('existing_valid_policy_false_unchanged', {policySucceeds: true, policyValue: false});
  equal([policyFalse.sent, policyFalse.header, policyFalse.configReads], [true, false, 0]);
  const policyTrue = await run('existing_valid_policy_true_unchanged', {policySucceeds: true, policyValue: true});
  equal([policyTrue.sent, policyTrue.header, policyTrue.configReads], [true, true, 0]);
  for (const [name, options] of [
    ['official_provider', {config: {model_provider: 'openai', model_providers: {openai: {requires_openai_auth: false}}}}],
    ['auth_required', {config: {model_provider: 'custom', model_providers: {custom: {requires_openai_auth: true}}}}],
    ['auth_requirement_missing', {config: {model_provider: 'custom', model_providers: {custom: {}}}}],
    ['string_false_rejected', {config: {model_provider: 'custom', model_providers: {custom: {requires_openai_auth: 'false'}}}}],
    ['provider_entry_missing', {config: {model_provider: 'custom', model_providers: {}}}],
    ['provider_missing', {config: {}}],
    ['configuration_unreadable', {configFails: true}],
    ['edge_not_modified', {family: 'edge'}],
    ['unsupported_capability', {capability: null}],
  ]) {
    const result = await run(name, options);
    equal([result.error, result.sent], ['Codex auth token is unavailable', false], name);
  }
  for (const message of ['Permission denied', 'User unavailable', 'HTTP 403', 'Browser request-header policy requires caller identity.', 'unsupported Codex auth method: apikey']) {
    const result = await run('other_error_' + message, {error: message});
    equal([result.error, result.sent, result.configReads], [message, false, 0]);
  }
  const inApp = await run('in_app_unmodified', {type: 'iab'});
  equal([inApp.sent, inApp.configReads, inApp.header], [true, 0, null]);
  const discovery = await run('discovery_unmodified', {operation: 'getInfo'});
  equal([discovery.sent, discovery.configReads], [true, 0]);
  const enabled = await run('headers_already_on', {capability: true});
  equal([enabled.sent, enabled.header, enabled.configReads], [true, true, 0]);
  const legacy = await run('legacy_extension_unmodified', {missingCapability: true});
  equal([legacy.sent, legacy.configReads], [true, 0]);
  const fallbackFamily = await run('official_default_chrome_family', {family: null});
  equal([fallbackFamily.sent, fallbackFamily.header], [true, true]);

  const destination = path.join(root, 'browser-service.mjs');
  fs.writeFileSync(destination, source);
  throws(() => patcher.applyFile(input, destination), /backup directory/);
  equal(patcher.hash(fs.readFileSync(destination)), plan.originalSha256, 'missing backup does not change destination');
  const applied = patcher.applyFile(input, destination, path.join(root, 'backups'));
  equal(applied.state, 'patched');
  equal(patcher.hash(fs.readFileSync(applied.backup)), plan.originalSha256, 'original backup is exact');
  equal(patcher.applyFile(input, destination, path.join(root, 'backups')).state, 'already-patched');
  fs.writeFileSync(destination, 'unrelated user data');
  throws(() => patcher.applyFile(input, destination, path.join(root, 'backups')), /unrelated/);
  equal(fs.readFileSync(destination, 'utf8'), 'unrelated user data');
  const fakeProtected = path.join(root, 'WindowsApps');
  fs.mkdirSync(fakeProtected);
  throws(() => patcher.applyFile(input, path.join(fakeProtected, 'browser-service.mjs')), /WindowsApps/);

  const result = {passed: true, checks, cases, profile: profile.id, originalSha256: plan.originalSha256, patchedSha256: plan.patchedSha256, root};
  fs.writeFileSync(path.join(root, 'result.json'), JSON.stringify(result, null, 2));
  console.log(JSON.stringify(result, null, 2));
})().catch(error => {console.error(error); process.exitCode = 1;});
