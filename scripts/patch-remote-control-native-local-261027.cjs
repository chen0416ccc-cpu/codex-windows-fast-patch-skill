const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const vm = require('node:vm');

const ORIGINAL_LIST = 'async function c$r(e,t,{appServerHostId:n,includeBrowserClients:r=!0}={}){let[i,a]=await Promise.all([r&&n==null?zQr():[],t==null?[]:u$r(e,n??\u0000local\u0000,t)]),o=new Map;for(let e of i)o.set(e.client_id,d$r(e));for(let e of a)o.set(e.clientId,e);return Array.from(o.values())}'.replaceAll('\u0000', '\u0000');
const ORIGINAL_PREFLIGHT = 'async function g$r(e){let t=e.query.snapshot(w$r);if(await t.invalidate({exact:!0,refetchType:\u0000none\u0000}),await t.fetch()!==\u0000required\u0000)return!1;let n=e.query.snapshot(T$r);return await n.invalidate({exact:!0,refetchType:\u0000none\u0000}),!await n.fetch()}';
const untick = value => value.replaceAll('\u0000', '\u0000').replaceAll('\u0000', String.fromCharCode(96));

const HELPER = 'async function phoneRemoteNativeLocalScope(scope){const client=tg(scope,"local"),account=await client.sendRequest("account/read",{refreshToken:false});if(account?.account?.type==="chatgpt")return null;if(account?.account!=null&&account.account.type!=="apiKey")throw Error("Unsupported main authentication for isolated phone control");const status=await client.sendRequest("remoteControl/status/read",void 0);if(!status||!["disabled","connecting","connected","errored"].includes(status.status))throw Error("Isolated phone control status is unavailable");return status;}';
const LIST = 'async function c$r(e,t,{appServerHostId:n,includeBrowserClients:r=!0}={}){if(n==null){const status=await phoneRemoteNativeLocalScope(e);if(status!==null){if(status.status!=="connected")return[];if(typeof status.environmentId!=="string"||!status.environmentId)throw Error("Isolated phone control environment is unavailable");if(t!=null&&t!==status.environmentId)throw Error("Isolated phone control environment does not match this computer");return u$r(e,"local",status.environmentId);}}let[i,a]=await Promise.all([r&&n==null?zQr():[],t==null?[]:u$r(e,n??"local",t)]),o=new Map;for(let e of i)o.set(e.client_id,d$r(e));for(let e of a)o.set(e.clientId,e);return Array.from(o.values())}';
const PREFLIGHT = 'async function g$r(e){const status=await phoneRemoteNativeLocalScope(e);if(status!==null){if(status.status!=="connected"||typeof status.environmentId!=="string"||!status.environmentId)throw Error("Enable this computer and wait for the isolated remote connection before pairing");return false;}let t=e.query.snapshot(w$r);if(await t.invalidate({exact:!0,refetchType:"none"}),await t.fetch()!=="required")return!1;let n=e.query.snapshot(T$r);return await n.invalidate({exact:!0,refetchType:"none"}),!await n.fetch()}';

function transform(source) {
  if (crypto.createHash('sha256').update(source).digest('hex') !== '23ced6d1a2456e0a669c3dd69cc8abc387a476c8e51fbb528b85da19240c95ac') throw Error('Unknown 26.1027 frontend source hash');
  let output = source;
  if (source.includes('phoneRemoteNativeLocalScope')) throw Error('Candidate already contains local native phone adaptation');
  for (const [before, after] of [[untick(ORIGINAL_LIST), HELPER + LIST], [untick(ORIGINAL_PREFLIGHT), PREFLIGHT]]) {
    if (output.split(before).length !== 2) throw Error('Unknown or duplicated frontend anchor');
    output = output.replace(before, after);
  }
  const before401 = 'e.status===401?(Fpt(),new qQr(' + String.fromCharCode(96) + 'ChatGPT auth is required to load remote control environments.' + String.fromCharCode(96) + '))';
  const after401 = before401.replace('(Fpt(),new qQr(', 'new qQr(').slice(0, -1);
  if (output.split(before401).length !== 2) throw Error('Unknown or duplicated remote 401 anchor');
  output = output.replace(before401, after401);
  const beforeMfa = 'w$r=Ft(Q,()=>({queryKey:[`remote-control-mfa-requirement`],queryFn:IQr,retry:!1,staleTime:v$r}))';
  const afterMfa = 'w$r=Ft(Q,({scope:e})=>({queryKey:[`remote-control-mfa-requirement`],queryFn:async()=>await phoneRemoteNativeLocalScope(e)===null?IQr():null,retry:!1,staleTime:v$r}))';
  if (output.split(beforeMfa).length !== 2) throw Error('Unknown or duplicated scoped MFA query');
  output = output.replace(beforeMfa, afterMfa);
  const beforeResume = 'queryFn:async()=>n?r!=null&&(await u$r(t,Rn,r)).length>0:RQr()';
  const afterResume = 'queryFn:async()=>{const status=await phoneRemoteNativeLocalScope(t);if(status!==null)return status.status==="connected"&&(await c$r(t,status.environmentId)).length>0;return n?r!=null&&(await u$r(t,Rn,r)).length>0:RQr()}';
  if (output.split(beforeResume).length !== 2) throw Error('Unknown or duplicated setup resume query');
  output = output.replace(beforeResume, afterResume);
  return output;
}

module.exports = { transform, HELPER, LIST, PREFLIGHT };
if (require.main === module) {
  if (process.argv.length !== 4) throw Error('Usage: node --experimental-vm-modules patch-remote-control-native-local-261027.cjs <source-asset> <new-output-asset>');
  const SOURCE = path.resolve(process.argv[2]);
  const output = path.resolve(process.argv[3]);
  if (SOURCE.toLowerCase() === output.toLowerCase() || fs.existsSync(output)) throw Error('Output must be a new candidate file, not the source');
  const source = fs.readFileSync(SOURCE, 'utf8');
  const candidate = transform(source);
  new vm.SourceTextModule(candidate);
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, candidate, { flag: 'wx' });
  const hash = value => crypto.createHash('sha256').update(value).digest('hex');
  const report = { source: SOURCE, output, sourceSha256: hash(source), outputSha256: hash(candidate),
    candidateOnly: true, installed: false, generalFetchChanged: false, serverPairingChecksChanged: false };
  console.log(JSON.stringify(report, null, 2));
}
