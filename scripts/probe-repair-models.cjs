const { spawn } = require('node:child_process');

function summarizeModels(response) {
  if (response?.nextCursor != null) throw new Error('model/list is paginated; refusing a partial repair model list');
  const models = response?.data ?? response?.models;
  if (!Array.isArray(models) || models.length === 0) throw new Error('model/list returned no models');
  const visible = models.filter(model => model.hidden !== true);
  const selected = models.find(model => model.isDefault === true);
  if (!selected || typeof selected.model !== 'string') throw new Error('model/list has no default model');
  const customModels = [...new Set(visible.map(model => model.model))];
  if (!customModels.includes(selected.model)) customModels.unshift(selected.model);
  if (customModels.some(model => typeof model !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$/.test(model))) {
    throw new Error('model/list contains an unsupported model identifier; pass explicit CustomModels');
  }
  return {
    defaultModel: selected.model,
    customModels,
    models: models.map(model => ({
      model: model.model, hidden: model.hidden === true, isDefault: model.isDefault === true,
      serviceTiers: (model.serviceTiers ?? []).map(tier => tier.id),
      reasoningEfforts: (model.supportedReasoningEfforts ?? []).map(effort => effort.reasoningEffort),
    })),
  };
}

async function probeModels(cliPath, timeoutMs = 20000) {
  if (typeof cliPath !== 'string' || !cliPath) throw new Error('A Codex CLI path is required');
  const child = spawn(cliPath, ['app-server', '--stdio'], { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
  let buffer = '', nextId = 0, terminalError, closed = false;
  const pending = new Map();
  const fail = error => {
    terminalError = error;
    for (const entry of pending.values()) { clearTimeout(entry.timer); entry.reject(error); }
    pending.clear();
  };
  child.on('error', fail);
  child.once('close', () => { closed = true; });
  child.on('exit', () => fail(new Error('Codex app-server exited before model/list completed')));
  child.stdin.on('error', fail);
  child.stdout.on('data', chunk => {
    buffer += chunk.toString('utf8');
    if (buffer.length > 16 * 1024 * 1024) { fail(new Error('Codex probe output exceeded its limit')); child.kill(); return; }
    for (;;) {
      const boundary = buffer.indexOf('\n');
      if (boundary < 0) break;
      const line = buffer.slice(0, boundary); buffer = buffer.slice(boundary + 1);
      let message;
      try { message = JSON.parse(line); } catch { continue; }
      const entry = pending.get(message.id);
      if (!entry) continue;
      clearTimeout(entry.timer); pending.delete(message.id);
      message.error ? entry.reject(new Error('Codex probe request failed')) : entry.resolve(message.result);
    }
  });
  function request(method, params) {
    if (terminalError) return Promise.reject(terminalError);
    const id = ++nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(method + ' timed out')); }, timeoutMs);
      pending.set(id, { resolve, reject, timer });
      child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
  }
  try {
    await request('initialize', { clientInfo: { name: 'post-update-readiness', version: '1.0' }, capabilities: { experimentalApi: true } });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'initialized', params: {} }) + '\n');
    return summarizeModels(await request('model/list', { includeHidden: true, limit: 200 }));
  } finally {
    // Wait for release of Windows cwd/pipe handles before callers clean up a
    // probe fixture or dispatch another operation. Never wait indefinitely.
    if (!closed) await new Promise(resolve => {
      const finish = () => { clearTimeout(timer); resolve(); };
      const timer = setTimeout(finish, 2000);
      child.once('close', finish);
      child.kill();
    });
  }
}

module.exports = { summarizeModels, probeModels };
if (require.main === module) {
  probeModels(process.argv[2]).then(result => process.stdout.write(JSON.stringify(result)), error => {
    process.stderr.write(error.message); process.exitCode = 1;
  });
}
