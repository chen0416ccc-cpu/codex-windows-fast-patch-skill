const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { summarizeModels, probeModels } = require('./probe-repair-models.cjs');

const response = { data: [
  { model: 'provider/new-model', isDefault: true, serviceTiers: [{ id: 'priority' }, { id: 'ultrafast' }], supportedReasoningEfforts: [{ reasoningEffort: 'ultra' }] },
  { model: 'future-v2', hidden: false, serviceTiers: [] },
  { model: 'internal-test', hidden: true },
] };
const summary = summarizeModels(response);
assert.deepEqual(summary.customModels, ['provider/new-model', 'future-v2']);
assert.deepEqual(summary.models[0].serviceTiers, ['priority', 'ultrafast']);
assert.deepEqual(summary.models[1].serviceTiers, []);
assert.deepEqual(summary.models[0].reasoningEfforts, ['ultra']);
assert.equal(summary.defaultModel, 'provider/new-model');
const duplicate = summarizeModels({ data: [...response.data, response.data[1]] });
assert.deepEqual(duplicate.customModels, summary.customModels);
assert.throws(() => summarizeModels({ data: [] }), /no models/);
assert.throws(() => summarizeModels({ data: [{ model: 'one' }] }), /no default/);
assert.throws(() => summarizeModels({ ...response, nextCursor: 'more' }), /partial/);
assert.throws(() => summarizeModels({ data: [{ model: 'bad,model', isDefault: true }] }), /unsupported/);
assert.deepEqual(summarizeModels({ data: [{ model: 'chosen', isDefault: true, hidden: true }] }).customModels, ['chosen']);

(async () => {
  if (process.argv[2]) {
    const live = await probeModels(process.argv[2]);
    assert.ok(live.customModels.includes(live.defaultModel));
    console.log('Live catalog probe passed: models=' + live.customModels.length);
  }
  // A failed spawn must fail promptly and not leave request timers alive.
  await assert.rejects(probeModels('Z:\\nonexistent-update-fixture\\codex.exe', 500), /ENOENT|exited/);
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'model probe fixture-'));
  const previousDirectory = process.cwd();
  const server = `
const fs=require('node:fs');
require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
 const request=JSON.parse(line);if(!request.id)return;
 fs.appendFileSync('methods.log',request.method+'\\n');
 if(fs.existsSync('stall'))return;
 if(fs.existsSync('early-exit'))process.exit(2);
 const result=request.method==='initialize'?{}:${JSON.stringify(response)};
 if(request.method==='model/list'&&fs.existsSync('reject'))process.stdout.write(JSON.stringify({id:request.id,error:{message:'fixture secret must not be printed'}})+'\\n');
 else process.stdout.write(JSON.stringify({id:request.id,result})+'\\n');
});`;
  fs.writeFileSync(path.join(root, 'app-server'), server);
  try {
    process.chdir(root);
    assert.deepEqual((await probeModels(process.execPath)).customModels, summary.customModels);
    assert.equal(fs.readFileSync('methods.log', 'utf8'), 'initialize\nmodel/list\n');
    fs.writeFileSync('stall', '');
    await assert.rejects(probeModels(process.execPath, 100), /timed out/);
    fs.unlinkSync('stall');
    fs.writeFileSync('early-exit', '');
    await assert.rejects(probeModels(process.execPath, 1000), /exited/);
    fs.unlinkSync('early-exit');
    fs.writeFileSync('reject', '');
    await assert.rejects(probeModels(process.execPath), error => error.message === 'Codex probe request failed');
  } finally {
    process.chdir(previousDirectory);
    fs.rmSync(root, { recursive: true, force: true });
  }
  console.log('Repair model inventory guards passed.');
})().catch(error => { console.error(error); process.exitCode = 1; });
