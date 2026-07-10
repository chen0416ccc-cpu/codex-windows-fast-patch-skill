const fs = require("node:fs");
const path = require("node:path");

const root = process.argv[2];
if (!root) {
  throw new Error("usage: node patch_remote_control_asar.cjs <extracted-asar-dir>");
}

function walk(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...walk(full));
    } else if (entry.isFile()) {
      out.push(full);
    }
  }
  return out;
}

function read(file) {
  return fs.readFileSync(file, "utf8");
}

function write(file, text) {
  fs.writeFileSync(file, text);
}

function replaceExact(text, oldText, newText, label) {
  if (!text.includes(oldText)) {
    throw new Error(`${label} anchor not found`);
  }
  return text.replace(oldText, newText);
}

function findJs(label, predicate) {
  const hit = jsFiles.find((file) => {
    const text = read(file);
    return predicate(file, text);
  });
  if (!hit) {
    throw new Error(`could not find ${label}`);
  }
  return hit;
}

function findJsAll(label, predicate) {
  const hits = jsFiles.filter((file) => {
    const text = read(file);
    return predicate(file, text);
  });
  if (hits.length === 0) {
    throw new Error(`could not find ${label}`);
  }
  return hits;
}

const jsFiles = walk(root).filter((file) => file.endsWith(".js"));

const mainFile = findJs("main bundle with remote-control remote-control flow", (_file, text) =>
  (text.includes("desktop_fetch_auth_401") ||
    text.includes("CODEX_API_BASE_URL") ||
    text.includes("remote_control_desktop_fetch_override_used") ||
    text.includes("remote_control_appserver_bh_isolated_auth_fallback") ||
    text.includes("async function z_({action:e,appServerClient:t,desktopOriginator:n") ||
    text.includes("async function nv({action:e,appServerClient:t,desktopApiOptions:n") ||
    text.includes("async function v_({action:e,appServerClient:t") ||
    text.includes("async function N_({action:e,appServerClient:t")) &&
  (text.includes("authorize remote control environments") || text.includes("codex.remote_control.enroll")) &&
  (text.includes("__codexRemoteControlAuthOverrideForPath") ||
    text.includes("async function yv({appServerClient:e,desktopApiOptions:t,deviceKeyClient:n,globalState:r,requestRemoteControlEnrollmentStepUpToken:i})") ||
    text.includes("async function YX") ||
    text.includes("async function RZ") ||
    text.includes("async function ZZ") ||
    text.includes("async function c$") ||
    text.includes("async function I1")) &&
  (text.includes("remote_control_desktop_fetch_override_used") ||
    text.includes("function L_(e){let t=process.env.CODEX_API_BASE_URL") ||
    text.includes("PN({desktopOriginator:this.options.desktopOriginator") ||
    text.includes("eP({desktopOriginator:this.options.desktopOriginator") ||
    text.includes("pP({desktopOriginator:this.options.desktopOriginator") ||
    (text.includes("async function P_({action:e,appServerClient:t,desktopApiOptions:n") &&
      text.includes("async function v_({action:e,appServerClient:t")) ||
    (text.includes("async function aI({appServerClient:e,errorStatus:t,failureMessage:n,refreshToken:r,state:i}") &&
      text.includes("async function N_({action:e,appServerClient:t")))
);

const mobileSetupNoAuthRedirectFiles = jsFiles.filter((file) =>
  (path.basename(file).startsWith("codex-mobile-setup-queries-") &&
    read(file).includes("ChatGPT auth is required to load remote control environments.") &&
    read(file).includes("e.status===401")) ||
  (path.basename(file).startsWith("selectable-remote-connections-signal-") &&
    read(file).includes("ChatGPT auth is required to load remote control environments.") &&
    read(file).includes("window.location.assign")) ||
  (path.basename(file).startsWith("codex-mobile-setup-dialog-") &&
    read(file).includes("ChatGPT auth is required to load remote control environments.")) ||
  (path.basename(file).startsWith("codex-mobile-setup-flow-") &&
    read(file).includes("J&&u(`/login`,{replace:!0})") &&
    read(file).includes("set-local-remote-control-enabled"))
);
if (mobileSetupNoAuthRedirectFiles.length === 0) {
  throw new Error("could not find codex mobile setup no-auth redirect bundle");
}

const mobileSetupMfaInfoFile = findJs("codex mobile setup MFA info bundle", (file, text) =>
  ((path.basename(file).startsWith("codex-mobile-setup-queries-") ||
    path.basename(file).startsWith("selectable-remote-connections-signal-")) &&
    text.includes("/accounts/mfa_info") &&
    text.includes("/wham/remote/control/clients"))
);

const mobileSetupFlowFile = findJs("codex mobile setup flow bundle", (file, text) =>
  path.basename(file).startsWith("codex-mobile-setup-flow-") &&
  text.includes("set-local-remote-control-enabled") &&
  (text.includes("async function z") ||
    text.includes("async function N") ||
    text.includes("async function F") ||
    text.includes("async function je"))
);

const remoteConnectionsSettingsFile = findJs("remote connections settings bundle", (file, text) =>
  path.basename(file).startsWith("remote-connections-settings-") &&
  text.includes("showControlThisMacTab") &&
  text.includes("control-this-mac") &&
  text.includes("remote_control_connections_state")
);

function patchFlowHelpers(text) {
  if (text.includes("remote_control_flow_log_ready")) {
    const oldPathAwareAuthOverrideFunction =
      "function __codexRemoteControlAuthOverrideWithOrder(e,t){for(let n of e)try{let e=require(\"node:fs\"),r=__codexRemoteControlAuthJsonPath(n),i=JSON.parse(e.readFileSync(r,\"utf8\")),a=__codexRemoteControlFindAccessToken(i),o=__codexRemoteControlJwtPayload(a),s=__codexRemoteControlScopes(o),c=s.includes(__codexRemoteControlEnrollScope());if(a)return __codexRemoteControlAuthLog(\"remote_control_auth_isolated_store_priority_check\",{source:n,path:t??null,hasToken:!0,scopeCount:s.length,hasEnrollScope:c}),a;__codexRemoteControlAuthLog(\"remote_control_auth_isolated_store_priority_check\",{source:n,path:t??null,hasToken:!1})}catch(e){__codexRemoteControlAuthLog(\"remote_control_auth_isolated_store_priority_check\",{source:n,path:t??null,hasToken:!1,errorName:e?.name,errorMessage:e?.message,errorCode:e?.code})}return null}";
    const newPathAwareAuthOverrideFunction =
      "function __codexRemoteControlAuthOverrideWithOrder(e,t){for(let n of e)try{let e=require(\"node:fs\"),r=__codexRemoteControlAuthJsonPath(n),i=JSON.parse(e.readFileSync(r,\"utf8\")),a=__codexRemoteControlFindAccessToken(i),o=__codexRemoteControlJwtPayload(a),s=__codexRemoteControlScopes(o),c=s.includes(__codexRemoteControlEnrollScope()),l=typeof o?.exp==\"number\"&&o.exp<=Math.floor(Date.now()/1e3)+30;if(a&&l){__codexRemoteControlAuthLog(\"remote_control_auth_token_expired_skipped\",{source:n,path:t??null,hasToken:!0,scopeCount:s.length,hasEnrollScope:c,expiresAt:o?.exp??null});continue}if(a)return __codexRemoteControlAuthLog(\"remote_control_auth_isolated_store_priority_check\",{source:n,path:t??null,hasToken:!0,scopeCount:s.length,hasEnrollScope:c}),a;__codexRemoteControlAuthLog(\"remote_control_auth_isolated_store_priority_check\",{source:n,path:t??null,hasToken:!1})}catch(e){__codexRemoteControlAuthLog(\"remote_control_auth_isolated_store_priority_check\",{source:n,path:t??null,hasToken:!1,errorName:e?.name,errorMessage:e?.message,errorCode:e?.code})}return null}";
    if (!text.includes("remote_control_auth_token_expired_skipped") && text.includes(oldPathAwareAuthOverrideFunction)) {
      return {
        text: replaceExact(
          text,
          oldPathAwareAuthOverrideFunction,
          newPathAwareAuthOverrideFunction,
          "remote-control path-aware auth override function expired-token guard",
        ),
        status: "patched-expired-token-guard",
      };
    }

    const oldPathAwareAuthOverride =
      "function __codexRemoteControlAuthOverrideWithOrder(e,t){for(let n of e)try{let e=require(\"node:fs\"),r=__codexRemoteControlAuthJsonPath(n),i=JSON.parse(e.readFileSync(r,\"utf8\")),a=__codexRemoteControlFindAccessToken(i),o=__codexRemoteControlJwtPayload(a),s=__codexRemoteControlScopes(o),c=s.includes(__codexRemoteControlEnrollScope());if(a)return __codexRemoteControlAuthLog(\"remote_control_auth_isolated_store_priority_check\",{source:n,path:t??null,hasToken:!0,scopeCount:s.length,hasEnrollScope:c}),a;__codexRemoteControlAuthLog(\"remote_control_auth_isolated_store_priority_check\",{source:n,path:t??null,hasToken:!1})}catch(e){__codexRemoteControlAuthLog(\"remote_control_auth_isolated_store_priority_check\",{source:n,path:t??null,hasToken:!1,errorName:e?.name,errorMessage:e?.message,errorCode:e?.code})}return null}function __codexRemoteControlAuthOverrideForPath(e){let t=String(e??\"\"),n=t.includes(\"/wham/remote/control/clients\")||t.includes(\"/wham/remote/control/environments\")?[\"remote.json\",\"remote-control-oauth.json\"]:[\"remote-control-oauth.json\",\"remote.json\"];return __codexRemoteControlAuthOverrideWithOrder(n,t)}function __codexRemoteControlAuthOverride(){return __codexRemoteControlAuthOverrideForPath(\"\")}";
    const newPathAwareAuthOverride =
      "function __codexRemoteControlAuthOverrideWithOrder(e,t){for(let n of e)try{let e=require(\"node:fs\"),r=__codexRemoteControlAuthJsonPath(n),i=JSON.parse(e.readFileSync(r,\"utf8\")),a=__codexRemoteControlFindAccessToken(i),o=__codexRemoteControlJwtPayload(a),s=__codexRemoteControlScopes(o),c=s.includes(__codexRemoteControlEnrollScope()),l=typeof o?.exp==\"number\"&&o.exp<=Math.floor(Date.now()/1e3)+30;if(a&&l){__codexRemoteControlAuthLog(\"remote_control_auth_token_expired_skipped\",{source:n,path:t??null,hasToken:!0,scopeCount:s.length,hasEnrollScope:c,expiresAt:o?.exp??null});continue}if(a)return __codexRemoteControlAuthLog(\"remote_control_auth_isolated_store_priority_check\",{source:n,path:t??null,hasToken:!0,scopeCount:s.length,hasEnrollScope:c}),a;__codexRemoteControlAuthLog(\"remote_control_auth_isolated_store_priority_check\",{source:n,path:t??null,hasToken:!1})}catch(e){__codexRemoteControlAuthLog(\"remote_control_auth_isolated_store_priority_check\",{source:n,path:t??null,hasToken:!1,errorName:e?.name,errorMessage:e?.message,errorCode:e?.code})}return null}function __codexRemoteControlAuthOverrideForPath(e){let t=String(e??\"\"),n=t.includes(\"/wham/remote/control/clients\")||t.includes(\"/wham/remote/control/environments\")?[\"remote.json\",\"remote-control-oauth.json\"]:[\"remote-control-oauth.json\",\"remote.json\"];return __codexRemoteControlAuthOverrideWithOrder(n,t)}function __codexRemoteControlAuthOverride(){return __codexRemoteControlAuthOverrideForPath(\"\")}";
    if (!text.includes("remote_control_auth_token_expired_skipped") && text.includes(oldPathAwareAuthOverride)) {
      return {
        text: replaceExact(
          text,
          oldPathAwareAuthOverride,
          newPathAwareAuthOverride,
          "remote-control path-aware auth override expired-token guard",
        ),
        status: "patched-expired-token-guard",
      };
    }

    if (!text.includes("function __codexRemoteControlAuthOverrideForPath")) {
      const oldAuthOverride =
        "function __codexRemoteControlAuthOverride(){for(let e of[\"remote-control-oauth.json\",\"remote.json\"])try{let t=require(\"node:fs\"),n=__codexRemoteControlAuthJsonPath(e),r=JSON.parse(t.readFileSync(n,\"utf8\")),i=__codexRemoteControlFindAccessToken(r),a=__codexRemoteControlJwtPayload(i),o=__codexRemoteControlScopes(a),s=o.includes(__codexRemoteControlEnrollScope());if(i)return __codexRemoteControlAuthLog(\"remote_control_auth_isolated_store_priority_check\",{source:e,hasToken:!0,scopeCount:o.length,hasEnrollScope:s}),i;__codexRemoteControlAuthLog(\"remote_control_auth_isolated_store_priority_check\",{source:e,hasToken:!1})}catch(t){__codexRemoteControlAuthLog(\"remote_control_auth_isolated_store_priority_check\",{source:e,hasToken:!1,errorName:t?.name,errorMessage:t?.message,errorCode:t?.code})}return null}";
      const newAuthOverride =
        newPathAwareAuthOverride;
      const next = replaceExact(text, oldAuthOverride, newAuthOverride, "remote-control path-aware auth override helper");
      return { text: next, status: "patched-path-aware-auth-helper" };
    }
    return { text, status: "already-patched" };
  }

  const authHelper = `function __codexRemoteControlEnrollScope(){return typeof GX=="string"?GX:typeof qZ=="string"?qZ:typeof K_=="string"?K_:typeof i$=="string"?i$:typeof M1=="string"?M1:"codex.remote_control.enroll"}function __codexRemoteControlAuthLog(e,t={}){try{typeof __codexRemoteControlFlowLog=="function"?__codexRemoteControlFlowLog(e,{marker:"remote_control_auth_isolated_store_priority_check",...t}):console.warn("remote_control_auth_isolated_store_priority_check",e,t)}catch{}}function __codexRemoteControlAuthJsonPath(e){let t=require("node:os"),n=require("node:path");if(e!=="remote-control-oauth.json"&&e!=="remote.json")throw Error("remote_control_auth_forbidden_file");let r=n.resolve(n.join(t.homedir(),".codex",e)),i=n.resolve(n.join(t.homedir(),".codex","auth.json"));if(r===i)throw Error("remote_control_auth_global_auth_rejected");return r}function __codexRemoteControlFindAccessToken(e,t=0){if(e==null||t>8)return null;if(typeof e=="string"){let t=e.trim();return t.split(".").length>=3?t:null}if(typeof e!="object")return null;for(let n of["access_token","accessToken"]){let r=e[n];if(typeof r=="string"&&r.trim().length>0)return r.trim()}for(let n of["tokens","auth","response","credential","credentials","remote","remote_control","step_up_token_exchange_stored_isolated"]){let r=__codexRemoteControlFindAccessToken(e[n],t+1);if(r)return r}if(e.entries&&typeof e.entries=="object")for(let n of Object.values(e.entries)){let e=__codexRemoteControlFindAccessToken(n,t+1);if(e)return e}for(let n of Object.values(e)){let e=__codexRemoteControlFindAccessToken(n,t+1);if(e)return e}return null}function __codexRemoteControlAuthOverrideWithOrder(e,t){for(let n of e)try{let e=require("node:fs"),r=__codexRemoteControlAuthJsonPath(n),i=JSON.parse(e.readFileSync(r,"utf8")),a=__codexRemoteControlFindAccessToken(i),o=__codexRemoteControlJwtPayload(a),s=__codexRemoteControlScopes(o),c=s.includes(__codexRemoteControlEnrollScope()),l=typeof o?.exp=="number"&&o.exp<=Math.floor(Date.now()/1e3)+30;if(a&&l){__codexRemoteControlAuthLog("remote_control_auth_token_expired_skipped",{source:n,path:t??null,hasToken:!0,scopeCount:s.length,hasEnrollScope:c,expiresAt:o?.exp??null});continue}if(a)return __codexRemoteControlAuthLog("remote_control_auth_isolated_store_priority_check",{source:n,path:t??null,hasToken:!0,scopeCount:s.length,hasEnrollScope:c}),a;__codexRemoteControlAuthLog("remote_control_auth_isolated_store_priority_check",{source:n,path:t??null,hasToken:!1})}catch(e){__codexRemoteControlAuthLog("remote_control_auth_isolated_store_priority_check",{source:n,path:t??null,hasToken:!1,errorName:e?.name,errorMessage:e?.message,errorCode:e?.code})}return null}function __codexRemoteControlAuthOverrideForPath(e){let t=String(e??""),n=/\\/(?:backend-api\\/)?wham\\/remote\\/control\\/clients(?:\\/|$)/.test(t)||/\\/(?:backend-api\\/)?wham\\/remote\\/control\\/environments(?:\\/|$)/.test(t)?["remote.json","remote-control-oauth.json"]:["remote-control-oauth.json","remote.json"];return __codexRemoteControlAuthOverrideWithOrder(n,t)}function __codexRemoteControlAuthOverride(){return __codexRemoteControlAuthOverrideForPath("")}function __codexRemoteControlConnectionAuthOverride(){let e="remote.json";try{let t=require("node:fs"),n=__codexRemoteControlAuthJsonPath(e),r=JSON.parse(t.readFileSync(n,"utf8")),i=__codexRemoteControlFindAccessToken(r),a=__codexRemoteControlJwtPayload(i),o=a?.["https://api.openai.com/auth"]??{},s=__codexRemoteControlScopes(a);if(i)return __codexRemoteControlAuthLog("remote_control_connection_auth_fallback_used",{source:e,hasToken:!0,scopeCount:s.length,hasAccountId:!!(o.chatgpt_account_id??o.account_id),hasAccountUserId:!!(o.chatgpt_account_user_id??o.account_user_id),hasEnrollScope:s.includes(__codexRemoteControlEnrollScope())}),i;__codexRemoteControlAuthLog("remote_control_connection_auth_fallback_used",{source:e,hasToken:!1})}catch(t){__codexRemoteControlAuthLog("remote_control_connection_auth_fallback_used",{source:e,hasToken:!1,errorName:t?.name,errorMessage:t?.message,errorCode:t?.code})}return null}`;
  const helper = authHelper + `function __codexRemoteControlSafeWriteFile(e,t){let n=require("node:os"),r=require("node:path"),i=require("node:fs"),a=r.resolve(String(e)),o=r.resolve(r.join(n.homedir(),".codex","auth.json"));if(a===o)throw Error("remote_control_private_file_target_rejected: software_device_key_private_helper_required");try{let e=i.realpathSync.native?i.realpathSync.native(a):i.realpathSync(a);if(e===o)throw Error("remote_control_private_file_target_rejected: software_device_key_private_helper_required")}catch(e){if(e?.code!=="ENOENT")throw e}try{let e=i.lstatSync(a);if(e.isSymbolicLink())throw Error("remote_control_private_file_target_rejected: symlink")}catch(e){if(e?.code!=="ENOENT")throw e}i.mkdirSync(r.dirname(a),{recursive:!0});i.writeFileSync(a,t,{encoding:"utf8",mode:384});try{i.chmodSync(a,384)}catch{}}function __codexRemoteControlFlowLog(e,t={}){try{let n=require("node:os"),r=require("node:path"),i=require("node:fs"),a=r.join(n.homedir(),".codex","remote-control-flow.log"),o={time:new Date().toISOString(),pid:process.pid,marker:"remote_control_flow_log_ready",stage:e,...t};for(let e of["access_token","refresh_token","id_token","step_up_token","authorization_code","code","codeVerifier","code_verifier","Authorization","authorization","bearer"])delete o[e];i.mkdirSync(r.dirname(a),{recursive:!0});i.appendFileSync(a,JSON.stringify(o)+"\\n","utf8")}catch(e){try{console.warn("remote_control_flow_log_failed",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code})}catch{}}}function __codexRemoteControlStepUpStorePath(){let e=require("node:os"),t=require("node:path");return t.join(e.homedir(),".codex","remote-control-oauth.json")}function __codexRemoteControlReadStepUpStore(){try{let e=require("node:fs");return JSON.parse(e.readFileSync(__codexRemoteControlStepUpStorePath(),"utf8"))}catch{return{schema:"codex-remote-control-oauth-isolated-v1",entries:{}}}}function __codexRemoteControlJwtPayload(e){let t=String(e||"").split(".");if(t.length<2||!t[1])return null;try{return JSON.parse(Buffer.from(t[1],"base64url").toString("utf8"))}catch{return null}}function __codexRemoteControlScopes(e){let t=new Set;for(let n of e?.scope?.split?.(/\\s+/)??[])n&&t.add(n);for(let n of Array.isArray(e?.scp)?e.scp:[])n&&t.add(n);return[...t]}function __codexRemoteControlReadFreshStepUpToken(e){try{let t=__codexRemoteControlReadStepUpStore(),n=t.tokens?.access_token??t.access_token??t.entries?.step_up_token_exchange_stored_isolated?.response?.access_token??t.step_up_token_exchange_stored_isolated?.response?.access_token;if(typeof n!="string"||n.trim().length===0)return __codexRemoteControlFlowLog("remote_control_step_up_cached_missing",{}),null;n=n.trim();let r=__codexRemoteControlJwtPayload(n);if(r==null)return __codexRemoteControlFlowLog("remote_control_step_up_cached_invalid_jwt",{}),null;let i=Math.floor(Date.now()/1e3),a=Date.now(),o=r["https://api.openai.com/auth"]??{},s=o.chatgpt_account_id??o.account_id,c=o.chatgpt_account_user_id??o.account_user_id,l=__codexRemoteControlScopes(r),u=l.includes(__codexRemoteControlEnrollScope()),d=typeof r.exp=="number"&&r.exp>i+30,f=typeof r.iat=="number"&&i-r.iat<240,p=typeof r.pwd_auth_time=="number"&&a-r.pwd_auth_time<240000,m=e==null||s==null||s===e;if(d&&f&&p&&u&&m)return __codexRemoteControlFlowLog("remote_control_step_up_cached_reused",{source:"remote-control-oauth.json",scopeCount:l.length,hasAccountId:!!s,hasAccountUserId:!!c,expiresAt:r.exp}),n;return __codexRemoteControlFlowLog("remote_control_step_up_cached_rejected",{source:"remote-control-oauth.json",hasRequiredScope:u,accountMatches:m,expiresOk:d,issuedFresh:f,passwordFresh:p,scopeCount:l.length,hasAccountId:!!s,hasAccountUserId:!!c}),null}catch(t){return __codexRemoteControlFlowLog("remote_control_step_up_cached_read_failed",{errorName:t?.name,errorMessage:t?.message,errorCode:t?.code}),null}}function __codexRemoteControlStoreStepUpTokenResponse(e,t={}){try{let n=__codexRemoteControlReadStepUpStore();n.schema="codex-remote-control-oauth-isolated-v1";n.updatedAt=new Date().toISOString();n.entries??={};n.entries.step_up_token_exchange_stored_isolated={time:new Date().toISOString(),pid:process.pid,...t,response:e};__codexRemoteControlSafeWriteFile(__codexRemoteControlStepUpStorePath(),JSON.stringify(n,null,2)+"\\n");__codexRemoteControlFlowLog("remote_control_oauth_store_write",{store:"remote-control-oauth.json",responseKeys:e&&typeof e=="object"?Object.keys(e).slice(0,20):[]})}catch(e){__codexRemoteControlFlowLog("remote_control_oauth_store_write_failed",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code})}}`;
  const anchor = [
    "var zX=`app_EMoamEEZ73f0CkXaXp7hrann`",
    "var OZ=`app_EMoamEEZ73f0CkXaXp7hrann`",
    "var VZ=`app_EMoamEEZ73f0CkXaXp7hrann`",
    "var QQ=`app_EMoamEEZ73f0CkXaXp7hrann`",
    "var E1=`app_EMoamEEZ73f0CkXaXp7hrann`",
    "function L_(e){let t=process.env.CODEX_API_BASE_URL",
  ].find((candidate) => text.includes(candidate));
  if (!anchor) {
    throw new Error("remote-control flow helper insertion anchor not found");
  }
  return { text: text.replace(anchor, `${helper}${anchor}`), status: "patched" };
}

function patchDesktopFetch(text) {
  const marker = "remote_control_desktop_fetch_override_used";
  const newPathMarker = "remote_control_desktop_fetch_new_auth_path_used";
  if (text.includes(marker) && (!text.includes("async function KF({appServerClient:e") || text.includes(newPathMarker))) {
    return { text, status: "already-patched" };
  }
  if (text.includes("async function z_({action:e,appServerClient:t,desktopOriginator:n,headers:r={},refreshToken:i=!1})")) {
    const oldZ_ =
      "async function z_({action:e,appServerClient:t,desktopOriginator:n,headers:r={},refreshToken:i=!1}){let o=await t.getAuthToken({refreshToken:i});if(!o){let t=a.W();throw Error(t===`ChatGPT`?`Sign in to ChatGPT to ${e}.`:`Sign in to ChatGPT in ${t} to ${e}.`)}let s={...r};return B_(s,o,{desktopOriginator:n}),s}";
    const newZ_ =
      "async function z_({action:e,appServerClient:t,desktopOriginator:n,headers:r={},refreshToken:i=!1}){let o=await t.getAuthToken({refreshToken:i});if(!o)try{o=typeof __codexRemoteControlConnectionAuthOverride==\"function\"?__codexRemoteControlConnectionAuthOverride():null,o&&typeof __codexRemoteControlFlowLog==\"function\"&&(__codexRemoteControlFlowLog(\"remote_control_appserver_bh_isolated_auth_fallback\",{action:e,refreshToken:i}),__codexRemoteControlFlowLog(\"remote_control_desktop_fetch_override_used\",{path:\"/codex/remote/control\",action:e}))}catch(t){try{typeof __codexRemoteControlFlowLog==\"function\"&&__codexRemoteControlFlowLog(\"remote_control_appserver_bh_isolated_auth_fallback_failed\",{action:e,errorName:t?.name,errorMessage:t?.message,errorCode:t?.code})}catch{}}if(!o){let t=a.W();throw Error(t===`ChatGPT`?`Sign in to ChatGPT to ${e}.`:`Sign in to ChatGPT in ${t} to ${e}.`)}let s={...r};return B_(s,o,{desktopOriginator:n}),s}";
    return {
      text: replaceExact(text, oldZ_, newZ_, "desktop_fetch 26.707 auth fallback"),
      status: "patched-26.707-auth-path",
    };
  }
  if (
    text.includes("async function P_({action:e,appServerClient:t,desktopApiOptions:n") &&
    text.includes("async function v_({action:e,appServerClient:t")
  ) {
    const oldKf =
      "async function KF({appServerClient:e,errorStatus:t,failureMessage:n,refreshToken:r,state:i}){if(!i.attachAuth)return i;if(!r){let t=e.getCachedAuthToken?.();if(t!==void 0)return{...i,tokenSource:`cached`,token:t}}try{let t=await e.getAuthToken({refreshToken:r});return{...i,tokenSource:r?`refreshed`:`loaded`,token:t}}catch(e){throw new WF(n,t,e)}}";
    const newKf =
      "async function KF({appServerClient:e,errorStatus:t,failureMessage:n,refreshToken:r,state:i,resolvedUrl:a}){if(!i.attachAuth)return i;let o=(()=>{try{return new URL(a).pathname}catch{return String(a??``)}})(),s=/\\/(?:backend-api\\/)?wham\\/remote\\/control\\//.test(o)||o===`/backend-api/accounts/mfa_info`||o===`/accounts/mfa_info`;if(s){let e=typeof __codexRemoteControlAuthOverrideForPath==\"function\"?__codexRemoteControlAuthOverrideForPath(o):typeof __codexRemoteControlAuthOverride==\"function\"?__codexRemoteControlAuthOverride():null;if(e)return typeof __codexRemoteControlFlowLog==\"function\"&&__codexRemoteControlFlowLog(\"remote_control_desktop_fetch_new_auth_path_used\",{path:o,refreshToken:r}),{...i,tokenSource:`remote-control-isolated`,token:e}}if(!r){let t=e.getCachedAuthToken?.();if(t!==void 0)return{...i,tokenSource:`cached`,token:t}}try{let t=await e.getAuthToken({refreshToken:r});return{...i,tokenSource:r?`refreshed`:`loaded`,token:t}}catch(e){throw new WF(n,t,e)}}";
    const oldInitialAuth =
      "u=await KF({appServerClient:this.getAppServerConnection(z),errorStatus:432,failureMessage:`Failed to retrieve authentication token`,refreshToken:!1,state:u})";
    const newInitialAuth =
      "u=await KF({appServerClient:this.getAppServerConnection(z),errorStatus:432,failureMessage:`Failed to retrieve authentication token`,refreshToken:!1,state:u,resolvedUrl:o})";
    const oldRetryAuth =
      "u=await KF({appServerClient:this.getAppServerConnection(z),errorStatus:401,failureMessage:`Failed to refresh authentication token`,refreshToken:!0,state:u})";
    const newRetryAuth =
      "u=await KF({appServerClient:this.getAppServerConnection(z),errorStatus:401,failureMessage:`Failed to refresh authentication token`,refreshToken:!0,state:u,resolvedUrl:o})";
    let next = replaceExact(text, oldKf, newKf, "desktop_fetch 26.616 auth fallback");
    next = replaceExact(next, oldInitialAuth, newInitialAuth, "desktop_fetch 26.616 initial auth call");
    next = replaceExact(next, oldRetryAuth, newRetryAuth, "desktop_fetch 26.616 retry auth call");
    if (!next.includes(newPathMarker)) {
      throw new Error("desktop_fetch 26.616 auth path marker missing after patch");
    }
    return { text: next, status: "patched-26.616-auth-path" };
  }
  if (
    text.includes("async function aI({appServerClient:e,errorStatus:t,failureMessage:n,refreshToken:r,state:i}") &&
    text.includes("async function N_({action:e,appServerClient:t")
  ) {
    const oldAI =
      "async function aI({appServerClient:e,errorStatus:t,failureMessage:n,refreshToken:r,state:i}){if(!i.attachAuth)return i;if(!r){let t=e.getCachedAuthToken?.();if(t!==void 0)return{...i,tokenSource:`cached`,token:t}}try{let t=await e.getAuthToken({refreshToken:r});return{...i,tokenSource:r?`refreshed`:`loaded`,token:t}}catch(e){throw new rI(n,t,e)}}";
    const newAI =
      "async function aI({appServerClient:e,errorStatus:t,failureMessage:n,refreshToken:r,state:i,resolvedUrl:a}){if(!i.attachAuth)return i;let o=(()=>{try{return new URL(a).pathname}catch{return String(a??``)}})(),s=/\\/(?:backend-api\\/)?wham\\/remote\\/control\\//.test(o)||o===`/backend-api/accounts/mfa_info`||o===`/accounts/mfa_info`;if(s){let e=typeof __codexRemoteControlAuthOverrideForPath==\"function\"?__codexRemoteControlAuthOverrideForPath(o):typeof __codexRemoteControlAuthOverride==\"function\"?__codexRemoteControlAuthOverride():null;if(e)return typeof __codexRemoteControlFlowLog==\"function\"&&__codexRemoteControlFlowLog(\"remote_control_desktop_fetch_new_auth_path_used\",{path:o,refreshToken:r}),{...i,tokenSource:`remote-control-isolated`,token:e}}if(!r){let t=e.getCachedAuthToken?.();if(t!==void 0)return{...i,tokenSource:`cached`,token:t}}try{let t=await e.getAuthToken({refreshToken:r});return{...i,tokenSource:r?`refreshed`:`loaded`,token:t}}catch(e){throw new rI(n,t,e)}}";
    const oldInitialAuth =
      "u=await aI({appServerClient:this.getAppServerConnection(B),errorStatus:432,failureMessage:`Failed to retrieve authentication token`,refreshToken:!1,state:u})";
    const newInitialAuth =
      "u=await aI({appServerClient:this.getAppServerConnection(B),errorStatus:432,failureMessage:`Failed to retrieve authentication token`,refreshToken:!1,state:u,resolvedUrl:o})";
    const oldRetryAuth =
      "u=await aI({appServerClient:this.getAppServerConnection(B),errorStatus:401,failureMessage:`Failed to refresh authentication token`,refreshToken:!0,state:u})";
    const newRetryAuth =
      "u=await aI({appServerClient:this.getAppServerConnection(B),errorStatus:401,failureMessage:`Failed to refresh authentication token`,refreshToken:!0,state:u,resolvedUrl:o})";
    let next = replaceExact(text, oldAI, newAI, "desktop_fetch 26.623 auth fallback");
    next = replaceExact(next, oldInitialAuth, newInitialAuth, "desktop_fetch 26.623 initial auth call");
    next = replaceExact(next, oldRetryAuth, newRetryAuth, "desktop_fetch 26.623 retry auth call");
    if (!next.includes(newPathMarker)) {
      throw new Error("desktop_fetch 26.623 auth path marker missing after patch");
    }
    return { text: next, status: "patched-26.623-auth-path" };
  }
  const oldAnchor =
    "PN({desktopOriginator:this.options.desktopOriginator,headers:t,state:e}),s&&c!=null&&this.setHeader(t,IN,c);let l=await r.net.fetch(a,{method:i,headers:t,body:d(),signal:o});";
  const newAnchor =
    "PN({desktopOriginator:this.options.desktopOriginator,headers:t,state:e}),(()=>{try{let __rcPath=(()=>{try{return new URL(a).pathname}catch{return String(a)}})(),__rcMatch=/\\/(?:backend-api\\/)?wham\\/remote\\/control\\//.test(__rcPath)||__rcPath===`/backend-api/accounts/mfa_info`||__rcPath===`/accounts/mfa_info`;if(__rcMatch){let __rcToken=typeof __codexRemoteControlAuthOverride==\"function\"?__codexRemoteControlAuthOverride():null;if(__rcToken){Vh(t,__rcToken,{desktopOriginator:this.options.desktopOriginator,includeSurfaceHeaders:!1});try{typeof __codexRemoteControlFlowLog==\"function\"&&__codexRemoteControlFlowLog(\"remote_control_desktop_fetch_override_used\",{path:__rcPath})}catch{}}}}catch{}})(),s&&c!=null&&this.setHeader(t,IN,c);let l=await r.net.fetch(a,{method:i,headers:t,body:d(),signal:o});";
  const oldAnchor2611 =
    "eP({desktopOriginator:this.options.desktopOriginator,headers:t,state:e}),s&&dg(t,{desktopOriginator:this.options.desktopOriginator}),c&&l!=null&&this.setHeader(t,nP,l);let u=await a.net.fetch(i,{method:r,headers:t,body:f(),signal:o});";
  const newAnchor2611 =
    "eP({desktopOriginator:this.options.desktopOriginator,headers:t,state:e}),(()=>{try{let __rcPath=(()=>{try{return new URL(i).pathname}catch{return String(i)}})(),__rcMatch=/\\/(?:backend-api\\/)?wham\\/remote\\/control\\//.test(__rcPath)||__rcPath===`/backend-api/accounts/mfa_info`||__rcPath===`/accounts/mfa_info`;if(__rcMatch){let __rcToken=typeof __codexRemoteControlAuthOverride==\"function\"?__codexRemoteControlAuthOverride():null;if(__rcToken){ug(t,__rcToken,{desktopOriginator:this.options.desktopOriginator,includeSurfaceHeaders:!1});try{typeof __codexRemoteControlFlowLog==\"function\"&&__codexRemoteControlFlowLog(\"remote_control_desktop_fetch_override_used\",{path:__rcPath})}catch{}}}}catch{}})(),s&&dg(t,{desktopOriginator:this.options.desktopOriginator}),c&&l!=null&&this.setHeader(t,nP,l);let u=await a.net.fetch(i,{method:r,headers:t,body:f(),signal:o});";
  const oldAnchor8604 =
    "pP({desktopOriginator:this.options.desktopOriginator,headers:t,state:e}),s&&wg(t,{desktopOriginator:this.options.desktopOriginator}),c&&l!=null&&this.setHeader(t,hP,l);let u=await a.net.fetch(i,{method:r,headers:t,body:f(),signal:o});";
  const newAnchor8604 =
    "pP({desktopOriginator:this.options.desktopOriginator,headers:t,state:e}),(()=>{try{let __rcPath=(()=>{try{return new URL(i).pathname}catch{return String(i)}})(),__rcMatch=/\\/(?:backend-api\\/)?wham\\/remote\\/control\\//.test(__rcPath)||__rcPath===`/backend-api/accounts/mfa_info`||__rcPath===`/accounts/mfa_info`;if(__rcMatch){let __rcToken=typeof __codexRemoteControlAuthOverride==\"function\"?__codexRemoteControlAuthOverride():null;if(__rcToken){Cg(t,__rcToken,{desktopOriginator:this.options.desktopOriginator,includeSurfaceHeaders:!1});try{typeof __codexRemoteControlFlowLog==\"function\"&&__codexRemoteControlFlowLog(\"remote_control_desktop_fetch_override_used\",{path:__rcPath})}catch{}}}}catch{}})(),s&&wg(t,{desktopOriginator:this.options.desktopOriginator}),c&&l!=null&&this.setHeader(t,hP,l);let u=await a.net.fetch(i,{method:r,headers:t,body:f(),signal:o});";
  const next = text.includes(oldAnchor)
    ? replaceExact(text, oldAnchor, newAnchor, "desktop_fetch Authorization")
    : text.includes(oldAnchor2611)
      ? replaceExact(text, oldAnchor2611, newAnchor2611, "desktop_fetch Authorization")
      : replaceExact(text, oldAnchor8604, newAnchor8604, "desktop_fetch Authorization");
  if (!next.includes(marker)) {
    throw new Error("desktop_fetch marker missing after patch");
  }
  return { text: next, status: "patched" };
}

function patchAppServerAuthFallback(text) {
  const marker = "remote_control_appserver_bh_isolated_auth_fallback";
  const helperMarker = "remote_control_connection_auth_fallback_used";
  let status = "already-patched";
  let next = text;
  if (!next.includes(helperMarker)) {
    const helperAnchor = "function __codexRemoteControlAuthOverride(){";
    const helper =
      "function __codexRemoteControlConnectionAuthOverride(){let e=`remote.json`;try{let t=require(\"node:fs\"),n=__codexRemoteControlAuthJsonPath(e),r=JSON.parse(t.readFileSync(n,\"utf8\")),i=__codexRemoteControlFindAccessToken(r),a=__codexRemoteControlJwtPayload(i),o=a?.[\"https://api.openai.com/auth\"]??{},s=__codexRemoteControlScopes(a);if(i)return __codexRemoteControlAuthLog(\"remote_control_connection_auth_fallback_used\",{source:e,hasToken:!0,scopeCount:s.length,hasAccountId:!!(o.chatgpt_account_id??o.account_id),hasAccountUserId:!!(o.chatgpt_account_user_id??o.account_user_id),hasEnrollScope:s.includes(__codexRemoteControlEnrollScope())}),i;__codexRemoteControlAuthLog(\"remote_control_connection_auth_fallback_used\",{source:e,hasToken:!1})}catch(t){__codexRemoteControlAuthLog(\"remote_control_connection_auth_fallback_used\",{source:e,hasToken:!1,errorName:t?.name,errorMessage:t?.message,errorCode:t?.code})}return null}";
    next = replaceExact(next, helperAnchor, helper + helperAnchor, "remote-control app-server auth fallback helper");
    status = "patched";
  }
  if (!next.includes(marker)) {
    const oldBh =
      "async function Bh({action:e,appServerClient:t,desktopOriginator:n,headers:r={},refreshToken:i=!1}){let a=await t.getAuthToken({refreshToken:i});if(!a)throw Error(`Sign in to ChatGPT in Codex Desktop to ${e}.`);let o={...r};return Vh(o,a,{desktopOriginator:n}),o}";
    const newBh =
      "async function Bh({action:e,appServerClient:t,desktopOriginator:n,headers:r={},refreshToken:i=!1}){let a=await t.getAuthToken({refreshToken:i});if(!a)try{a=typeof __codexRemoteControlConnectionAuthOverride==\"function\"?__codexRemoteControlConnectionAuthOverride():null,a&&typeof __codexRemoteControlFlowLog==\"function\"&&__codexRemoteControlFlowLog(\"remote_control_appserver_bh_isolated_auth_fallback\",{action:e,refreshToken:i})}catch(t){try{typeof __codexRemoteControlFlowLog==\"function\"&&__codexRemoteControlFlowLog(\"remote_control_appserver_bh_isolated_auth_fallback_failed\",{action:e,errorName:t?.name,errorMessage:t?.message,errorCode:t?.code})}catch{}}if(!a)throw Error(`Sign in to ChatGPT in Codex Desktop to ${e}.`);let o={...r};return Vh(o,a,{desktopOriginator:n}),o}";
    const oldLg =
      "async function lg({action:e,appServerClient:t,desktopOriginator:n,headers:r={},refreshToken:i=!1}){let a=await t.getAuthToken({refreshToken:i});if(!a)throw Error(`Sign in to ChatGPT in Codex Desktop to ${e}.`);let o={...r};return ug(o,a,{desktopOriginator:n}),o}";
    const newLg =
      "async function lg({action:e,appServerClient:t,desktopOriginator:n,headers:r={},refreshToken:i=!1}){let a=await t.getAuthToken({refreshToken:i});if(!a)try{a=typeof __codexRemoteControlConnectionAuthOverride==\"function\"?__codexRemoteControlConnectionAuthOverride():null,a&&typeof __codexRemoteControlFlowLog==\"function\"&&__codexRemoteControlFlowLog(\"remote_control_appserver_bh_isolated_auth_fallback\",{action:e,refreshToken:i})}catch(t){try{typeof __codexRemoteControlFlowLog==\"function\"&&__codexRemoteControlFlowLog(\"remote_control_appserver_bh_isolated_auth_fallback_failed\",{action:e,errorName:t?.name,errorMessage:t?.message,errorCode:t?.code})}catch{}}if(!a)throw Error(`Sign in to ChatGPT in Codex Desktop to ${e}.`);let o={...r};return ug(o,a,{desktopOriginator:n}),o}";
    const oldSg =
      "async function Sg({action:e,appServerClient:t,desktopOriginator:n,headers:r={},refreshToken:i=!1}){let a=await t.getAuthToken({refreshToken:i});if(!a)throw Error(`Sign in to ChatGPT in Codex Desktop to ${e}.`);let o={...r};return Cg(o,a,{desktopOriginator:n}),o}";
    const newSg =
      "async function Sg({action:e,appServerClient:t,desktopOriginator:n,headers:r={},refreshToken:i=!1}){let a=await t.getAuthToken({refreshToken:i});if(!a)try{a=typeof __codexRemoteControlConnectionAuthOverride==\"function\"?__codexRemoteControlConnectionAuthOverride():null,a&&typeof __codexRemoteControlFlowLog==\"function\"&&__codexRemoteControlFlowLog(\"remote_control_appserver_bh_isolated_auth_fallback\",{action:e,refreshToken:i})}catch(t){try{typeof __codexRemoteControlFlowLog==\"function\"&&__codexRemoteControlFlowLog(\"remote_control_appserver_bh_isolated_auth_fallback_failed\",{action:e,errorName:t?.name,errorMessage:t?.message,errorCode:t?.code})}catch{}}if(!a)throw Error(`Sign in to ChatGPT in Codex Desktop to ${e}.`);let o={...r};return Cg(o,a,{desktopOriginator:n}),o}";
    const oldV_ =
      "async function v_({action:e,appServerClient:t,desktopOriginator:n,headers:i={},refreshToken:a=!1}){let o=await t.getAuthToken({refreshToken:a});if(!o){let t=r.tt();throw Error(t===`ChatGPT`?`Sign in to ChatGPT to ${e}.`:`Sign in to ChatGPT in ${t} to ${e}.`)}let s={...i};return y_(s,o,{desktopOriginator:n}),s}";
    const newV_ =
      "async function v_({action:e,appServerClient:t,desktopOriginator:n,headers:i={},refreshToken:a=!1}){let o=await t.getAuthToken({refreshToken:a});if(!o)try{o=typeof __codexRemoteControlConnectionAuthOverride==\"function\"?__codexRemoteControlConnectionAuthOverride():null,o&&typeof __codexRemoteControlFlowLog==\"function\"&&(__codexRemoteControlFlowLog(\"remote_control_appserver_bh_isolated_auth_fallback\",{action:e,refreshToken:a}),__codexRemoteControlFlowLog(\"remote_control_desktop_fetch_override_used\",{path:\"/codex/remote/control\",action:e}))}catch(t){try{typeof __codexRemoteControlFlowLog==\"function\"&&__codexRemoteControlFlowLog(\"remote_control_appserver_bh_isolated_auth_fallback_failed\",{action:e,errorName:t?.name,errorMessage:t?.message,errorCode:t?.code})}catch{}}if(!o){let t=r.tt();throw Error(t===`ChatGPT`?`Sign in to ChatGPT to ${e}.`:`Sign in to ChatGPT in ${t} to ${e}.`)}let s={...i};return y_(s,o,{desktopOriginator:n}),s}";
    const oldN_2623 =
      "async function N_({action:e,appServerClient:t,desktopOriginator:n,headers:i={},refreshToken:a=!1}){let o=await t.getAuthToken({refreshToken:a});if(!o){let t=r.nt();throw Error(t===`ChatGPT`?`Sign in to ChatGPT to ${e}.`:`Sign in to ChatGPT in ${t} to ${e}.`)}let s={...i};return P_(s,o,{desktopOriginator:n}),s}";
    const newN_2623 =
      "async function N_({action:e,appServerClient:t,desktopOriginator:n,headers:i={},refreshToken:a=!1}){let o=await t.getAuthToken({refreshToken:a});if(!o)try{o=typeof __codexRemoteControlConnectionAuthOverride==\"function\"?__codexRemoteControlConnectionAuthOverride():null,o&&typeof __codexRemoteControlFlowLog==\"function\"&&(__codexRemoteControlFlowLog(\"remote_control_appserver_bh_isolated_auth_fallback\",{action:e,refreshToken:a}),__codexRemoteControlFlowLog(\"remote_control_desktop_fetch_override_used\",{path:\"/codex/remote/control\",action:e}))}catch(t){try{typeof __codexRemoteControlFlowLog==\"function\"&&__codexRemoteControlFlowLog(\"remote_control_appserver_bh_isolated_auth_fallback_failed\",{action:e,errorName:t?.name,errorMessage:t?.message,errorCode:t?.code})}catch{}}if(!o){let t=r.nt();throw Error(t===`ChatGPT`?`Sign in to ChatGPT to ${e}.`:`Sign in to ChatGPT in ${t} to ${e}.`)}let s={...i};return P_(s,o,{desktopOriginator:n}),s}";
    next = next.includes(oldBh)
      ? replaceExact(next, oldBh, newBh, "remote-control app-server auth fallback Bh")
      : next.includes(oldLg)
        ? replaceExact(next, oldLg, newLg, "remote-control app-server auth fallback lg")
        : next.includes(oldSg)
          ? replaceExact(next, oldSg, newSg, "remote-control app-server auth fallback Sg")
          : next.includes(oldV_)
            ? replaceExact(next, oldV_, newV_, "remote-control app-server auth fallback v_")
            : replaceExact(next, oldN_2623, newN_2623, "remote-control app-server auth fallback N_");
    status = "patched";
  }
  if (!next.includes(marker) || !next.includes(helperMarker)) {
    throw new Error("remote-control app-server auth fallback marker missing after patch");
  }
  return { text: next, status };
}

function patchStepUpFlow(text) {
  const yxMarker = "__codexRemoteControlCachedStepUp";
  const tzMarker = "remote_control_step_up_token_exchange_started";
  const oldYx = "async function YX({accountId:e,desktopApiOptions:t,fetchToken:n=(e,t)=>r.net.fetch(e,t),openExternalUrl:i=e=>r.shell.openExternal(e),timeoutMs:a=WX}){let o=ZX(),s=$X(),c=eZ(32),l=await nZ({state:c,timeoutMs:a});try{return await i(XX({issuer:o,clientId:zX,redirectUri:l.redirectUri,codeChallenge:s.codeChallenge,state:c,originator:t.desktopOriginator,accountId:e})),(await tZ({code:await l.authorizationCode,codeVerifier:s.codeVerifier,clientId:zX,issuer:o,redirectUri:l.redirectUri,fetchToken:n})).access_token}finally{l.close()}}";
  const newYx = "async function YX({accountId:e,desktopApiOptions:t,fetchToken:n=(e,t)=>r.net.fetch(e,t),openExternalUrl:i=e=>r.shell.openExternal(e),timeoutMs:a=WX}){let __codexRemoteControlCachedStepUp=typeof __codexRemoteControlReadFreshStepUpToken==\"function\"?__codexRemoteControlReadFreshStepUpToken(e):null;if(__codexRemoteControlCachedStepUp)return __codexRemoteControlCachedStepUp;let o=ZX(),s=$X(),c=eZ(32),l=await nZ({state:c,timeoutMs:a});try{__codexRemoteControlFlowLog(\"remote_control_step_up_browser_open\",{issuer:o,redirectUri:l.redirectUri,accountId:e??null});await i(XX({issuer:o,clientId:zX,redirectUri:l.redirectUri,codeChallenge:s.codeChallenge,state:c,originator:t.desktopOriginator,accountId:e}));__codexRemoteControlFlowLog(\"remote_control_step_up_wait_callback\",{redirectUri:l.redirectUri});let __codexRemoteControlCode=await l.authorizationCode;__codexRemoteControlFlowLog(\"remote_control_step_up_callback_received\",{codeLength:typeof __codexRemoteControlCode==\"string\"?__codexRemoteControlCode.length:null});return (await tZ({code:__codexRemoteControlCode,codeVerifier:s.codeVerifier,clientId:zX,issuer:o,redirectUri:l.redirectUri,fetchToken:n})).access_token}catch(e){__codexRemoteControlFlowLog(\"remote_control_step_up_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code,stack:e?.stack});throw e}finally{l.close();__codexRemoteControlFlowLog(\"remote_control_step_up_listener_closed\",{})}}";
  const oldRz = "async function RZ({accountId:e,desktopApiOptions:t,fetchToken:n=(e,t)=>a.net.fetch(e,t),openExternalUrl:r=e=>a.shell.openExternal(e),timeoutMs:i=NZ}){let o=BZ(),s=HZ(),c=UZ(32),l=await GZ({state:c,timeoutMs:i});try{return await r(zZ({issuer:o,clientId:OZ,redirectUri:l.redirectUri,codeChallenge:s.codeChallenge,state:c,originator:t.desktopOriginator,accountId:e})),(await WZ({code:await l.authorizationCode,codeVerifier:s.codeVerifier,clientId:OZ,issuer:o,redirectUri:l.redirectUri,fetchToken:n})).access_token}finally{l.close()}}";
  const newRz = "async function RZ({accountId:e,desktopApiOptions:t,fetchToken:n=(e,t)=>a.net.fetch(e,t),openExternalUrl:r=e=>a.shell.openExternal(e),timeoutMs:i=NZ}){let __codexRemoteControlCachedStepUp=typeof __codexRemoteControlReadFreshStepUpToken==\"function\"?__codexRemoteControlReadFreshStepUpToken(e):null;if(__codexRemoteControlCachedStepUp)return __codexRemoteControlCachedStepUp;let o=BZ(),s=HZ(),c=UZ(32),l=await GZ({state:c,timeoutMs:i});try{__codexRemoteControlFlowLog(\"remote_control_step_up_browser_open\",{issuer:o,redirectUri:l.redirectUri,accountId:e??null});await r(zZ({issuer:o,clientId:OZ,redirectUri:l.redirectUri,codeChallenge:s.codeChallenge,state:c,originator:t.desktopOriginator,accountId:e}));__codexRemoteControlFlowLog(\"remote_control_step_up_wait_callback\",{redirectUri:l.redirectUri});let __codexRemoteControlCode=await l.authorizationCode;__codexRemoteControlFlowLog(\"remote_control_step_up_callback_received\",{codeLength:typeof __codexRemoteControlCode==\"string\"?__codexRemoteControlCode.length:null});return (await WZ({code:__codexRemoteControlCode,codeVerifier:s.codeVerifier,clientId:OZ,issuer:o,redirectUri:l.redirectUri,fetchToken:n})).access_token}catch(e){__codexRemoteControlFlowLog(\"remote_control_step_up_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code,stack:e?.stack});throw e}finally{l.close();__codexRemoteControlFlowLog(\"remote_control_step_up_listener_closed\",{})}}";
  const oldZz = "async function ZZ({accountId:e,desktopApiOptions:t,fetchToken:n=(e,t)=>a.net.fetch(e,t),openExternalUrl:r=e=>a.shell.openExternal(e),timeoutMs:i=KZ}){let o=$Z(),s=tQ(),c=nQ(32),l=await iQ({state:c,timeoutMs:i});try{return await r(QZ({issuer:o,clientId:VZ,redirectUri:l.redirectUri,codeChallenge:s.codeChallenge,state:c,originator:t.desktopOriginator,accountId:e})),(await rQ({code:await l.authorizationCode,codeVerifier:s.codeVerifier,clientId:VZ,issuer:o,redirectUri:l.redirectUri,fetchToken:n})).access_token}finally{l.close()}}";
  const newZz = "async function ZZ({accountId:e,desktopApiOptions:t,fetchToken:n=(e,t)=>a.net.fetch(e,t),openExternalUrl:r=e=>a.shell.openExternal(e),timeoutMs:i=KZ}){let __codexRemoteControlCachedStepUp=typeof __codexRemoteControlReadFreshStepUpToken==\"function\"?__codexRemoteControlReadFreshStepUpToken(e):null;if(__codexRemoteControlCachedStepUp)return __codexRemoteControlCachedStepUp;let o=$Z(),s=tQ(),c=nQ(32),l=await iQ({state:c,timeoutMs:i});try{__codexRemoteControlFlowLog(\"remote_control_step_up_browser_open\",{issuer:o,redirectUri:l.redirectUri,accountId:e??null});await r(QZ({issuer:o,clientId:VZ,redirectUri:l.redirectUri,codeChallenge:s.codeChallenge,state:c,originator:t.desktopOriginator,accountId:e}));__codexRemoteControlFlowLog(\"remote_control_step_up_wait_callback\",{redirectUri:l.redirectUri});let __codexRemoteControlCode=await l.authorizationCode;__codexRemoteControlFlowLog(\"remote_control_step_up_callback_received\",{codeLength:typeof __codexRemoteControlCode==\"string\"?__codexRemoteControlCode.length:null});return (await rQ({code:__codexRemoteControlCode,codeVerifier:s.codeVerifier,clientId:VZ,issuer:o,redirectUri:l.redirectUri,fetchToken:n})).access_token}catch(e){__codexRemoteControlFlowLog(\"remote_control_step_up_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code,stack:e?.stack});throw e}finally{l.close();__codexRemoteControlFlowLog(\"remote_control_step_up_listener_closed\",{})}}";

  const oldTz = "async function tZ({code:e,codeVerifier:t,clientId:n,issuer:r,redirectUri:i,fetchToken:a}){let o=await a(new URL(`/oauth/token`,QX(r)).toString(),{method:`POST`,headers:{\"Content-Type\":`application/x-www-form-urlencoded`},body:new URLSearchParams({grant_type:`authorization_code`,code:e,redirect_uri:i,client_id:n,code_verifier:t}).toString()});if(!o.ok)throw Error(`Remote control step-up token exchange failed with status ${o.status}.`);return JX.parse(await o.json())}";
  const newTz = "async function tZ({code:e,codeVerifier:t,clientId:n,issuer:r,redirectUri:i,fetchToken:a}){__codexRemoteControlFlowLog(\"remote_control_step_up_token_exchange_started\",{issuer:r,redirectUri:i});let o=await a(new URL(`/oauth/token`,QX(r)).toString(),{method:`POST`,headers:{\"Content-Type\":`application/x-www-form-urlencoded`},body:new URLSearchParams({grant_type:`authorization_code`,code:e,redirect_uri:i,client_id:n,code_verifier:t}).toString()});if(!o.ok){let e=\"\";try{e=await o.text()}catch{}__codexRemoteControlFlowLog(\"remote_control_step_up_token_exchange_failed\",{status:o.status,bodySnippet:e.slice(0,500)});throw Error(\"Remote control step-up token exchange failed with status \"+o.status+\".\")}let s=await o.json(),c=JX.parse(s);try{__codexRemoteControlStoreStepUpTokenResponse(c,{source:String(i).includes(\"/deviceauth/callback\")?\"device_code\":\"pkce\",issuer:r,redirectUri:i})}catch(e){__codexRemoteControlFlowLog(\"remote_control_step_up_store_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code})}__codexRemoteControlFlowLog(\"remote_control_step_up_token_exchange_done\",{status:o.status,responseKeys:c&&typeof c==\"object\"?Object.keys(c).slice(0,20):[]});return c}";
  const oldWz = "async function WZ({code:e,codeVerifier:t,clientId:n,issuer:r,redirectUri:i,fetchToken:a}){let o=await a(new URL(`/oauth/token`,VZ(r)).toString(),{method:`POST`,headers:{\"Content-Type\":`application/x-www-form-urlencoded`},body:new URLSearchParams({grant_type:`authorization_code`,code:e,redirect_uri:i,client_id:n,code_verifier:t}).toString()});if(!o.ok)throw Error(`Remote control step-up token exchange failed with status ${o.status}.`);return LZ.parse(await o.json())}";
  const newWz = "async function WZ({code:e,codeVerifier:t,clientId:n,issuer:r,redirectUri:i,fetchToken:a}){__codexRemoteControlFlowLog(\"remote_control_step_up_token_exchange_started\",{issuer:r,redirectUri:i});let o=await a(new URL(`/oauth/token`,VZ(r)).toString(),{method:`POST`,headers:{\"Content-Type\":`application/x-www-form-urlencoded`},body:new URLSearchParams({grant_type:`authorization_code`,code:e,redirect_uri:i,client_id:n,code_verifier:t}).toString()});if(!o.ok){let e=\"\";try{e=await o.text()}catch{}__codexRemoteControlFlowLog(\"remote_control_step_up_token_exchange_failed\",{status:o.status,bodySnippet:e.slice(0,500)});throw Error(\"Remote control step-up token exchange failed with status \"+o.status+\".\")}let s=await o.json(),c=LZ.parse(s);try{__codexRemoteControlStoreStepUpTokenResponse(c,{source:String(i).includes(\"/deviceauth/callback\")?\"device_code\":\"pkce\",issuer:r,redirectUri:i})}catch(e){__codexRemoteControlFlowLog(\"remote_control_step_up_store_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code})}__codexRemoteControlFlowLog(\"remote_control_step_up_token_exchange_done\",{status:o.status,responseKeys:c&&typeof c==\"object\"?Object.keys(c).slice(0,20):[]});return c}";
  const oldRq = "async function rQ({code:e,codeVerifier:t,clientId:n,issuer:r,redirectUri:i,fetchToken:a}){let o=await a(new URL(`/oauth/token`,eQ(r)).toString(),{method:`POST`,headers:{\"Content-Type\":`application/x-www-form-urlencoded`},body:new URLSearchParams({grant_type:`authorization_code`,code:e,redirect_uri:i,client_id:n,code_verifier:t}).toString()});if(!o.ok)throw Error(`Remote control step-up token exchange failed with status ${o.status}.`);return XZ.parse(await o.json())}";
  const newRq = "async function rQ({code:e,codeVerifier:t,clientId:n,issuer:r,redirectUri:i,fetchToken:a}){__codexRemoteControlFlowLog(\"remote_control_step_up_token_exchange_started\",{issuer:r,redirectUri:i});let o=await a(new URL(`/oauth/token`,eQ(r)).toString(),{method:`POST`,headers:{\"Content-Type\":`application/x-www-form-urlencoded`},body:new URLSearchParams({grant_type:`authorization_code`,code:e,redirect_uri:i,client_id:n,code_verifier:t}).toString()});if(!o.ok){let e=\"\";try{e=await o.text()}catch{}__codexRemoteControlFlowLog(\"remote_control_step_up_token_exchange_failed\",{status:o.status,bodySnippet:e.slice(0,500)});throw Error(\"Remote control step-up token exchange failed with status \"+o.status+\".\")}let s=await o.json(),c=XZ.parse(s);try{__codexRemoteControlStoreStepUpTokenResponse(c,{source:String(i).includes(\"/deviceauth/callback\")?\"device_code\":\"pkce\",issuer:r,redirectUri:i})}catch(e){__codexRemoteControlFlowLog(\"remote_control_step_up_store_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code})}__codexRemoteControlFlowLog(\"remote_control_step_up_token_exchange_done\",{status:o.status,responseKeys:c&&typeof c==\"object\"?Object.keys(c).slice(0,20):[]});return c}";
  const oldC$ = "async function c$({accountId:e,desktopApiOptions:t,fetchToken:n=(e,t)=>a.net.fetch(e,t),openExternalUrl:r=e=>a.shell.openExternal(e),timeoutMs:i=r$}){let o=u$(),s=f$(),c=p$(32),l=await h$({state:c,timeoutMs:i});try{return await r(l$({issuer:o,clientId:QQ,redirectUri:l.redirectUri,codeChallenge:s.codeChallenge,state:c,originator:t.desktopOriginator,accountId:e})),(await m$({code:await l.authorizationCode,codeVerifier:s.codeVerifier,clientId:QQ,issuer:o,redirectUri:l.redirectUri,fetchToken:n})).access_token}finally{l.close()}}";
  const newC$ = "async function c$({accountId:e,desktopApiOptions:t,fetchToken:n=(e,t)=>a.net.fetch(e,t),openExternalUrl:r=e=>a.shell.openExternal(e),timeoutMs:i=r$}){let __codexRemoteControlCachedStepUp=typeof __codexRemoteControlReadFreshStepUpToken==\"function\"?__codexRemoteControlReadFreshStepUpToken(e):null;if(__codexRemoteControlCachedStepUp)return __codexRemoteControlCachedStepUp;let o=u$(),s=f$(),c=p$(32),l=await h$({state:c,timeoutMs:i});try{__codexRemoteControlFlowLog(\"remote_control_step_up_browser_open\",{issuer:o,redirectUri:l.redirectUri,accountId:e??null});await r(l$({issuer:o,clientId:QQ,redirectUri:l.redirectUri,codeChallenge:s.codeChallenge,state:c,originator:t.desktopOriginator,accountId:e}));__codexRemoteControlFlowLog(\"remote_control_step_up_wait_callback\",{redirectUri:l.redirectUri});let __codexRemoteControlCode=await l.authorizationCode;__codexRemoteControlFlowLog(\"remote_control_step_up_callback_received\",{codeLength:typeof __codexRemoteControlCode==\"string\"?__codexRemoteControlCode.length:null});return (await m$({code:__codexRemoteControlCode,codeVerifier:s.codeVerifier,clientId:QQ,issuer:o,redirectUri:l.redirectUri,fetchToken:n})).access_token}catch(e){__codexRemoteControlFlowLog(\"remote_control_step_up_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code,stack:e?.stack});throw e}finally{l.close();__codexRemoteControlFlowLog(\"remote_control_step_up_listener_closed\",{})}}";
  const oldM$ = "async function m$({code:e,codeVerifier:t,clientId:n,issuer:r,redirectUri:i,fetchToken:a}){let o=await a(new URL(`/oauth/token`,d$(r)).toString(),{method:`POST`,headers:{\"Content-Type\":`application/x-www-form-urlencoded`},body:new URLSearchParams({grant_type:`authorization_code`,code:e,redirect_uri:i,client_id:n,code_verifier:t}).toString()});if(!o.ok)throw Error(`Remote control step-up token exchange failed with status ${o.status}.`);return s$.parse(await o.json())}";
  const newM$ = "async function m$({code:e,codeVerifier:t,clientId:n,issuer:r,redirectUri:i,fetchToken:a}){__codexRemoteControlFlowLog(\"remote_control_step_up_token_exchange_started\",{issuer:r,redirectUri:i});let o=await a(new URL(`/oauth/token`,d$(r)).toString(),{method:`POST`,headers:{\"Content-Type\":`application/x-www-form-urlencoded`},body:new URLSearchParams({grant_type:`authorization_code`,code:e,redirect_uri:i,client_id:n,code_verifier:t}).toString()});if(!o.ok){let e=\"\";try{e=await o.text()}catch{}__codexRemoteControlFlowLog(\"remote_control_step_up_token_exchange_failed\",{status:o.status,bodySnippet:e.slice(0,500)});throw Error(\"Remote control step-up token exchange failed with status \"+o.status+\".\")}let c=await o.json(),l=s$.parse(c);try{__codexRemoteControlStoreStepUpTokenResponse(l,{source:String(i).includes(\"/deviceauth/callback\")?\"device_code\":\"pkce\",issuer:r,redirectUri:i})}catch(e){__codexRemoteControlFlowLog(\"remote_control_step_up_store_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code})}__codexRemoteControlFlowLog(\"remote_control_step_up_token_exchange_done\",{status:o.status,responseKeys:l&&typeof l==\"object\"?Object.keys(l).slice(0,20):[]});return l}";
  const oldI1 = "async function I1({accountId:e,desktopApiOptions:t,fetchToken:n=(e,t)=>a.net.fetch(e,t),openExternalUrl:r=e=>YA({request:{url:e,initiator:`open_in_browser_bridge`,openTarget:`external-browser`}}),timeoutMs:i=j1}){let o=R1(),s=B1(),c=V1(32),l=await U1({state:c,timeoutMs:i});l.authorizationCode.catch(()=>{});try{if(await r(L1({issuer:o,clientId:E1,redirectUri:l.redirectUri,codeChallenge:s.codeChallenge,state:c,originator:t.desktopOriginator,accountId:e}))===!1)throw Error(`Failed to open remote control login in the default browser.`);return(await H1({code:await l.authorizationCode,codeVerifier:s.codeVerifier,clientId:E1,issuer:o,redirectUri:l.redirectUri,fetchToken:n})).access_token}finally{l.close()}}";
  const newI1 = "async function I1({accountId:e,desktopApiOptions:t,fetchToken:n=(e,t)=>a.net.fetch(e,t),openExternalUrl:r=e=>YA({request:{url:e,initiator:`open_in_browser_bridge`,openTarget:`external-browser`}}),timeoutMs:i=j1}){let __codexRemoteControlCachedStepUp=typeof __codexRemoteControlReadFreshStepUpToken==\"function\"?__codexRemoteControlReadFreshStepUpToken(e):null;if(__codexRemoteControlCachedStepUp)return __codexRemoteControlCachedStepUp;let o=R1(),s=B1(),c=V1(32),l=await U1({state:c,timeoutMs:i});l.authorizationCode.catch(()=>{});try{__codexRemoteControlFlowLog(\"remote_control_step_up_browser_open\",{issuer:o,redirectUri:l.redirectUri,accountId:e??null});if(await r(L1({issuer:o,clientId:E1,redirectUri:l.redirectUri,codeChallenge:s.codeChallenge,state:c,originator:t.desktopOriginator,accountId:e}))===!1)throw Error(`Failed to open remote control login in the default browser.`);__codexRemoteControlFlowLog(\"remote_control_step_up_wait_callback\",{redirectUri:l.redirectUri});let __codexRemoteControlCode=await l.authorizationCode;__codexRemoteControlFlowLog(\"remote_control_step_up_callback_received\",{codeLength:typeof __codexRemoteControlCode==\"string\"?__codexRemoteControlCode.length:null});return(await H1({code:__codexRemoteControlCode,codeVerifier:s.codeVerifier,clientId:E1,issuer:o,redirectUri:l.redirectUri,fetchToken:n})).access_token}catch(e){__codexRemoteControlFlowLog(\"remote_control_step_up_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code,stack:e?.stack});throw e}finally{l.close();__codexRemoteControlFlowLog(\"remote_control_step_up_listener_closed\",{})}}";
  const oldH1 = "async function H1({code:e,codeVerifier:t,clientId:n,issuer:r,redirectUri:i,fetchToken:a}){let o=await a(new URL(`/oauth/token`,z1(r)).toString(),{method:`POST`,headers:{\"Content-Type\":`application/x-www-form-urlencoded`},body:new URLSearchParams({grant_type:`authorization_code`,code:e,redirect_uri:i,client_id:n,code_verifier:t}).toString()});if(!o.ok)throw Error(`Remote control step-up token exchange failed with status ${o.status}.`);return F1.parse(await o.json())}";
  const newH1 = "async function H1({code:e,codeVerifier:t,clientId:n,issuer:r,redirectUri:i,fetchToken:a}){__codexRemoteControlFlowLog(\"remote_control_step_up_token_exchange_started\",{issuer:r,redirectUri:i});let o=await a(new URL(`/oauth/token`,z1(r)).toString(),{method:`POST`,headers:{\"Content-Type\":`application/x-www-form-urlencoded`},body:new URLSearchParams({grant_type:`authorization_code`,code:e,redirect_uri:i,client_id:n,code_verifier:t}).toString()});if(!o.ok){let e=\"\";try{e=await o.text()}catch{}__codexRemoteControlFlowLog(\"remote_control_step_up_token_exchange_failed\",{status:o.status,bodySnippet:e.slice(0,500)});throw Error(\"Remote control step-up token exchange failed with status \"+o.status+\".\")}let s=await o.json(),c=F1.parse(s);try{__codexRemoteControlStoreStepUpTokenResponse(c,{source:String(i).includes(\"/deviceauth/callback\")?\"device_code\":\"pkce\",issuer:r,redirectUri:i})}catch(e){__codexRemoteControlFlowLog(\"remote_control_step_up_store_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code})}__codexRemoteControlFlowLog(\"remote_control_step_up_token_exchange_done\",{status:o.status,responseKeys:c&&typeof c==\"object\"?Object.keys(c).slice(0,20):[]});return c}";

  let status = "already-patched";
  let next = text;
  if (!next.includes(yxMarker)) {
    next = next.includes(oldYx)
      ? replaceExact(next, oldYx, newYx, "remote-control step-up YX")
      : next.includes(oldRz)
        ? replaceExact(next, oldRz, newRz, "remote-control step-up RZ")
        : next.includes(oldZz)
          ? replaceExact(next, oldZz, newZz, "remote-control step-up ZZ")
          : next.includes(oldC$)
            ? replaceExact(next, oldC$, newC$, "remote-control step-up c$")
            : replaceExact(next, oldI1, newI1, "remote-control step-up I1");
    status = "patched";
  }
  if (!next.includes(tzMarker)) {
    next = next.includes(oldTz)
      ? replaceExact(next, oldTz, newTz, "remote-control step-up token exchange")
      : next.includes(oldWz)
        ? replaceExact(next, oldWz, newWz, "remote-control step-up token exchange")
        : next.includes(oldRq)
          ? replaceExact(next, oldRq, newRq, "remote-control step-up token exchange")
          : next.includes(oldM$)
            ? replaceExact(next, oldM$, newM$, "remote-control step-up token exchange")
            : replaceExact(next, oldH1, newH1, "remote-control step-up token exchange");
    status = "patched";
  }
  return { text: next, status };
}

function patchRemoteControlHttp(text) {
  const marker = "remote_control_http_response";
  if (text.includes(marker)) {
    return { text, status: "already-patched" };
  }
  const oldNg = "async function ng({action:e,appServerClient:t,desktopApiOptions:n,path:i,method:a,headers:o={},body:s,mapNotFoundToFeatureUnavailable:c=!0}){let l=zh(n,i),u=await rg({action:e,appServerClient:t,desktopApiOptions:n,headers:o}),d=await r.net.fetch(l,{method:a,headers:u,body:s});if(d.status===401&&(u=await rg({action:e,appServerClient:t,desktopApiOptions:n,headers:o,refreshToken:!0}),d=await r.net.fetch(l,{method:a,headers:u,body:s})),d.status===404&&c)throw new Xh;if(d.status===403)throw new Qh(await ug(d));if(d.status===401)throw new Zh(ig(e));if(!d.ok)throw Error(`Remote control request failed (${d.status}): ${await ug(d)}`);return d}";
  const newNg = "async function ng({action:e,appServerClient:t,desktopApiOptions:n,path:i,method:a,headers:o={},body:s,mapNotFoundToFeatureUnavailable:c=!0}){let l=zh(n,i),u=await rg({action:e,appServerClient:t,desktopApiOptions:n,headers:o}),d=await r.net.fetch(l,{method:a,headers:u,body:s});__codexRemoteControlFlowLog(\"remote_control_http_response\",{path:i,method:a,status:d.status,ok:d.ok,refreshed:!1});if(d.status===401){u=await rg({action:e,appServerClient:t,desktopApiOptions:n,headers:o,refreshToken:!0});d=await r.net.fetch(l,{method:a,headers:u,body:s});__codexRemoteControlFlowLog(\"remote_control_http_response\",{path:i,method:a,status:d.status,ok:d.ok,refreshed:!0})}if(!d.ok){let e=\"\";try{let t=d.clone?d.clone():d;e=await t.text()}catch(e){e=\"<<body read failed: \"+(e?.message??e)+\">>\"}__codexRemoteControlFlowLog(\"remote_control_http_failure_body\",{path:i,status:d.status,bodySnippet:e.slice(0,500)})}if(d.status===404&&c)throw new Xh;if(d.status===403)throw new Qh(await ug(d));if(d.status===401)throw new Zh(ig(e));if(!d.ok)throw Error(\"Remote control request failed (\"+d.status+\"): \"+await ug(d));return d}";
  const oldTg = "async function Tg({action:e,appServerClient:t,desktopApiOptions:n,path:r,method:i,headers:o={},body:s,mapNotFoundToFeatureUnavailable:c=!0}){let l=cg(n,r),u=await Eg({action:e,appServerClient:t,desktopApiOptions:n,headers:o}),d=await a.net.fetch(l,{method:i,headers:u,body:s});if(d.status===401&&(u=await Eg({action:e,appServerClient:t,desktopApiOptions:n,headers:o,refreshToken:!0}),d=await a.net.fetch(l,{method:i,headers:u,body:s})),d.status===404&&c)throw new yg;if(d.status===403)throw new xg(await Ng(d));if(d.status===401)throw new bg(Dg(e));if(!d.ok)throw Error(`Remote control request failed (${d.status}): ${await Ng(d)}`);return d}";
  const newTg = "async function Tg({action:e,appServerClient:t,desktopApiOptions:n,path:r,method:i,headers:o={},body:s,mapNotFoundToFeatureUnavailable:c=!0}){let l=cg(n,r),u=await Eg({action:e,appServerClient:t,desktopApiOptions:n,headers:o}),d=await a.net.fetch(l,{method:i,headers:u,body:s});__codexRemoteControlFlowLog(\"remote_control_http_response\",{path:r,method:i,status:d.status,ok:d.ok,refreshed:!1});if(d.status===401){u=await Eg({action:e,appServerClient:t,desktopApiOptions:n,headers:o,refreshToken:!0});d=await a.net.fetch(l,{method:i,headers:u,body:s});__codexRemoteControlFlowLog(\"remote_control_http_response\",{path:r,method:i,status:d.status,ok:d.ok,refreshed:!0})}if(!d.ok){let e=\"\";try{let t=d.clone?d.clone():d;e=await t.text()}catch(e){e=\"<<body read failed: \"+(e?.message??e)+\">>\"}__codexRemoteControlFlowLog(\"remote_control_http_failure_body\",{path:r,status:d.status,bodySnippet:e.slice(0,500)})}if(d.status===404&&c)throw new yg;if(d.status===403)throw new xg(await Ng(d));if(d.status===401)throw new bg(Dg(e));if(!d.ok)throw Error(\"Remote control request failed (\"+d.status+\"): \"+await Ng(d));return d}";
  const oldRg = "async function Rg({action:e,appServerClient:t,desktopApiOptions:n,path:r,method:i,headers:o={},body:s,mapNotFoundToFeatureUnavailable:c=!0}){let l=xg(n,r),u=await zg({action:e,appServerClient:t,desktopApiOptions:n,headers:o}),d=await a.net.fetch(l,{method:i,headers:u,body:s});if(d.status===401&&(u=await zg({action:e,appServerClient:t,desktopApiOptions:n,headers:o,refreshToken:!0}),d=await a.net.fetch(l,{method:i,headers:u,body:s})),d.status===404&&c)throw new Mg;if(d.status===403)throw new Pg(await Kg(d));if(d.status===401)throw new Ng(Bg(e));if(!d.ok)throw Error(`Remote control request failed (${d.status}): ${await Kg(d)}`);return d}";
  const newRg = "async function Rg({action:e,appServerClient:t,desktopApiOptions:n,path:r,method:i,headers:o={},body:s,mapNotFoundToFeatureUnavailable:c=!0}){let l=xg(n,r),u=await zg({action:e,appServerClient:t,desktopApiOptions:n,headers:o}),d=await a.net.fetch(l,{method:i,headers:u,body:s});__codexRemoteControlFlowLog(\"remote_control_http_response\",{path:r,method:i,status:d.status,ok:d.ok,refreshed:!1});if(d.status===401){u=await zg({action:e,appServerClient:t,desktopApiOptions:n,headers:o,refreshToken:!0});d=await a.net.fetch(l,{method:i,headers:u,body:s});__codexRemoteControlFlowLog(\"remote_control_http_response\",{path:r,method:i,status:d.status,ok:d.ok,refreshed:!0})}if(!d.ok){let e=\"\";try{let t=d.clone?d.clone():d;e=await t.text()}catch(e){e=\"<<body read failed: \"+(e?.message??e)+\">>\"}__codexRemoteControlFlowLog(\"remote_control_http_failure_body\",{path:r,status:d.status,bodySnippet:e.slice(0,500)})}if(d.status===404&&c)throw new Mg;if(d.status===403)throw new Pg(await Kg(d));if(d.status===401)throw new Ng(Bg(e));if(!d.ok)throw Error(\"Remote control request failed (\"+d.status+\"): \"+await Kg(d));return d}";
  const oldP_ = "async function P_({action:e,appServerClient:t,desktopApiOptions:n,path:r,method:i,headers:o={},body:s,mapNotFoundToFeatureUnavailable:c=!0}){let l=__(n,r),u=await F_({action:e,appServerClient:t,desktopApiOptions:n,headers:o}),d=await a.net.fetch(l,{method:i,headers:u,body:s});if(d.status===401&&(u=await F_({action:e,appServerClient:t,desktopApiOptions:n,headers:o,refreshToken:!0}),d=await a.net.fetch(l,{method:i,headers:u,body:s})),d.status===404&&c)throw new O_;if(d.status===403)throw new A_(await H_(d));if(d.status===401)throw new k_(I_(e));if(!d.ok)throw Error(`Remote control request failed (${d.status}): ${await H_(d)}`);return d}";
  const newP_ = "async function P_({action:e,appServerClient:t,desktopApiOptions:n,path:r,method:i,headers:o={},body:s,mapNotFoundToFeatureUnavailable:c=!0}){let l=__(n,r),u=await F_({action:e,appServerClient:t,desktopApiOptions:n,headers:o}),d=await a.net.fetch(l,{method:i,headers:u,body:s});__codexRemoteControlFlowLog(\"remote_control_http_response\",{path:r,method:i,status:d.status,ok:d.ok,refreshed:!1});if(d.status===401){u=await F_({action:e,appServerClient:t,desktopApiOptions:n,headers:o,refreshToken:!0});d=await a.net.fetch(l,{method:i,headers:u,body:s});__codexRemoteControlFlowLog(\"remote_control_http_response\",{path:r,method:i,status:d.status,ok:d.ok,refreshed:!0})}if(!d.ok){let e=\"\";try{let t=d.clone?d.clone():d;e=await t.text()}catch(e){e=\"<<body read failed: \"+(e?.message??e)+\">>\"}__codexRemoteControlFlowLog(\"remote_control_http_failure_body\",{path:r,status:d.status,bodySnippet:e.slice(0,500)})}if(d.status===404&&c)throw new O_;if(d.status===403)throw new A_(await H_(d));if(d.status===401)throw new k_(I_(e));if(!d.ok)throw Error(\"Remote control request failed (\"+d.status+\"): \"+await H_(d));return d}";
  const oldY_ = "async function Y_({action:e,appServerClient:t,desktopApiOptions:n,path:r,method:i,headers:o={},body:s,mapNotFoundToFeatureUnavailable:c=!0}){let l=M_(n,r),u=await X_({action:e,appServerClient:t,desktopApiOptions:n,headers:o}),d=await a.net.fetch(l,{method:i,headers:u,body:s});if(d.status===401&&(u=await X_({action:e,appServerClient:t,desktopApiOptions:n,headers:o,refreshToken:!0}),d=await a.net.fetch(l,{method:i,headers:u,body:s})),d.status===404&&c)throw new U_;if(d.status===403)throw new G_(await rv(d));if(d.status===401)throw new W_(Z_(e));if(!d.ok)throw Error(`Remote control request failed (${d.status}): ${await rv(d)}`);return d}";
  const newY_ = "async function Y_({action:e,appServerClient:t,desktopApiOptions:n,path:r,method:i,headers:o={},body:s,mapNotFoundToFeatureUnavailable:c=!0}){let l=M_(n,r),u=await X_({action:e,appServerClient:t,desktopApiOptions:n,headers:o}),d=await a.net.fetch(l,{method:i,headers:u,body:s});__codexRemoteControlFlowLog(\"remote_control_http_response\",{path:r,method:i,status:d.status,ok:d.ok,refreshed:!1});if(d.status===401){u=await X_({action:e,appServerClient:t,desktopApiOptions:n,headers:o,refreshToken:!0});d=await a.net.fetch(l,{method:i,headers:u,body:s});__codexRemoteControlFlowLog(\"remote_control_http_response\",{path:r,method:i,status:d.status,ok:d.ok,refreshed:!0})}if(!d.ok){let e=\"\";try{let t=d.clone?d.clone():d;e=await t.text()}catch(e){e=\"<<body read failed: \"+(e?.message??e)+\">>\"}__codexRemoteControlFlowLog(\"remote_control_http_failure_body\",{path:r,status:d.status,bodySnippet:e.slice(0,500)})}if(d.status===404&&c)throw new U_;if(d.status===403)throw new G_(await rv(d));if(d.status===401)throw new W_(Z_(e));if(!d.ok)throw Error(\"Remote control request failed (\"+d.status+\"): \"+await rv(d));return d}";
  return {
    text: text.includes(oldNg)
      ? replaceExact(text, oldNg, newNg, "remote-control HTTP diagnostics")
      : text.includes(oldTg)
        ? replaceExact(text, oldTg, newTg, "remote-control HTTP diagnostics")
        : text.includes(oldRg)
          ? replaceExact(text, oldRg, newRg, "remote-control HTTP diagnostics")
          : text.includes(oldP_)
            ? replaceExact(text, oldP_, newP_, "remote-control HTTP diagnostics")
            : replaceExact(text, oldY_, newY_, "remote-control HTTP diagnostics"),
    status: "patched",
  };
}

function patchRemoteControlAuthorize(text) {
  const marker = "remote_control_qm_start";
  if (text.includes(marker)) {
    return { text, status: "already-patched" };
  }
  const oldBg = "async function bg({appServerClient:e,desktopApiOptions:t,deviceKeyClient:n,globalState:r,requestRemoteControlEnrollmentStepUpToken:i}){await Tg({appServerClient:e,deviceKeyClient:n,desktopApiOptions:t,enrollmentKey:Sg(t),globalState:r,headers:await wg({action:`authorize remote control environments`,appServerClient:e,desktopApiOptions:t}),requestRemoteControlEnrollmentStepUpToken:i})}";
  const newBg = "async function bg({appServerClient:e,desktopApiOptions:t,deviceKeyClient:n,globalState:r,requestRemoteControlEnrollmentStepUpToken:i}){__codexRemoteControlFlowLog(\"remote_control_qm_start\",{hasStepUp:typeof i==\"function\"});try{let a=await wg({action:`authorize remote control environments`,appServerClient:e,desktopApiOptions:t});__codexRemoteControlFlowLog(\"remote_control_qm_headers_ready\",{headerKeys:Object.keys(a).filter(e=>e.toLowerCase()!==\"authorization\").sort(),hasAuthorization:Object.keys(a).some(e=>e.toLowerCase()===\"authorization\"),hasChatGptAccountId:Object.keys(a).some(e=>e.toLowerCase()===\"chatgpt-account-id\"||e.toLowerCase()===\"chatgpt-account-id\")});await Tg({appServerClient:e,deviceKeyClient:n,desktopApiOptions:t,enrollmentKey:Sg(t),globalState:r,headers:a,requestRemoteControlEnrollmentStepUpToken:i});__codexRemoteControlFlowLog(\"remote_control_qm_completed\",{})}catch(e){__codexRemoteControlFlowLog(\"remote_control_qm_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code,stack:e?.stack});throw e}}";
  const oldUg = "async function Ug({appServerClient:e,desktopApiOptions:t,deviceKeyClient:n,globalState:r,requestRemoteControlEnrollmentStepUpToken:i}){await Jg({appServerClient:e,deviceKeyClient:n,desktopApiOptions:t,enrollmentKey:Gg(t),globalState:r,headers:await qg({action:`authorize remote control environments`,appServerClient:e,desktopApiOptions:t}),requestRemoteControlEnrollmentStepUpToken:i})}";
  const newUg = "async function Ug({appServerClient:e,desktopApiOptions:t,deviceKeyClient:n,globalState:r,requestRemoteControlEnrollmentStepUpToken:i}){__codexRemoteControlFlowLog(\"remote_control_qm_start\",{hasStepUp:typeof i==\"function\"});try{let a=await qg({action:`authorize remote control environments`,appServerClient:e,desktopApiOptions:t});__codexRemoteControlFlowLog(\"remote_control_qm_headers_ready\",{headerKeys:Object.keys(a).filter(e=>e.toLowerCase()!==\"authorization\").sort(),hasAuthorization:Object.keys(a).some(e=>e.toLowerCase()===\"authorization\"),hasChatGptAccountId:Object.keys(a).some(e=>e.toLowerCase()===\"chatgpt-account-id\")});await Jg({appServerClient:e,deviceKeyClient:n,desktopApiOptions:t,enrollmentKey:Gg(t),globalState:r,headers:a,requestRemoteControlEnrollmentStepUpToken:i});__codexRemoteControlFlowLog(\"remote_control_qm_completed\",{})}catch(e){__codexRemoteControlFlowLog(\"remote_control_qm_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code,stack:e?.stack});throw e}}";
  const oldN_ = "async function n_({appServerClient:e,desktopApiOptions:t,deviceKeyClient:n,globalState:r,requestRemoteControlEnrollmentStepUpToken:i}){await s_({appServerClient:e,deviceKeyClient:n,desktopApiOptions:t,enrollmentKey:i_(t),globalState:r,headers:await o_({action:`authorize remote control environments`,appServerClient:e,desktopApiOptions:t}),requestRemoteControlEnrollmentStepUpToken:i})}";
  const newN_ = "async function n_({appServerClient:e,desktopApiOptions:t,deviceKeyClient:n,globalState:r,requestRemoteControlEnrollmentStepUpToken:i}){__codexRemoteControlFlowLog(\"remote_control_qm_start\",{hasStepUp:typeof i==\"function\"});try{let a=await o_({action:`authorize remote control environments`,appServerClient:e,desktopApiOptions:t});__codexRemoteControlFlowLog(\"remote_control_qm_headers_ready\",{headerKeys:Object.keys(a).filter(e=>e.toLowerCase()!==\"authorization\").sort(),hasAuthorization:Object.keys(a).some(e=>e.toLowerCase()===\"authorization\"),hasChatGptAccountId:Object.keys(a).some(e=>e.toLowerCase()===\"chatgpt-account-id\")});await s_({appServerClient:e,deviceKeyClient:n,desktopApiOptions:t,enrollmentKey:i_(t),globalState:r,headers:a,requestRemoteControlEnrollmentStepUpToken:i});__codexRemoteControlFlowLog(\"remote_control_qm_completed\",{})}catch(e){__codexRemoteControlFlowLog(\"remote_control_qm_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code,stack:e?.stack});throw e}}";
  const oldQ_ = "async function Q_({appServerClient:e,desktopApiOptions:t,deviceKeyClient:n,globalState:r,requestRemoteControlEnrollmentStepUpToken:i}){await rv({appServerClient:e,deviceKeyClient:n,desktopApiOptions:t,enrollmentKey:ev(t),globalState:r,headers:await nv({action:`authorize remote control environments`,appServerClient:e,desktopApiOptions:t}),requestRemoteControlEnrollmentStepUpToken:i})}";
  const newQ_ = "async function Q_({appServerClient:e,desktopApiOptions:t,deviceKeyClient:n,globalState:r,requestRemoteControlEnrollmentStepUpToken:i}){__codexRemoteControlFlowLog(\"remote_control_qm_start\",{hasStepUp:typeof i==\"function\"});try{let a=await nv({action:`authorize remote control environments`,appServerClient:e,desktopApiOptions:t});__codexRemoteControlFlowLog(\"remote_control_qm_headers_ready\",{headerKeys:Object.keys(a).filter(e=>e.toLowerCase()!==\"authorization\").sort(),hasAuthorization:Object.keys(a).some(e=>e.toLowerCase()===\"authorization\"),hasChatGptAccountId:Object.keys(a).some(e=>e.toLowerCase()===\"chatgpt-account-id\")});await rv({appServerClient:e,deviceKeyClient:n,desktopApiOptions:t,enrollmentKey:ev(t),globalState:r,headers:a,requestRemoteControlEnrollmentStepUpToken:i});__codexRemoteControlFlowLog(\"remote_control_qm_completed\",{})}catch(e){__codexRemoteControlFlowLog(\"remote_control_qm_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code,stack:e?.stack});throw e}}";
  const oldPv = "async function pv({appServerClient:e,desktopApiOptions:t,deviceKeyClient:n,globalState:r,requestRemoteControlEnrollmentStepUpToken:i}){await vv({appServerClient:e,deviceKeyClient:n,desktopApiOptions:t,enrollmentKey:hv(t),globalState:r,headers:await _v({action:`authorize remote control environments`,appServerClient:e,desktopApiOptions:t}),requestRemoteControlEnrollmentStepUpToken:i})}";
  const newPv = "async function pv({appServerClient:e,desktopApiOptions:t,deviceKeyClient:n,globalState:r,requestRemoteControlEnrollmentStepUpToken:i}){__codexRemoteControlFlowLog(\"remote_control_qm_start\",{hasStepUp:typeof i==\"function\"});try{let a=await _v({action:`authorize remote control environments`,appServerClient:e,desktopApiOptions:t});__codexRemoteControlFlowLog(\"remote_control_qm_headers_ready\",{headerKeys:Object.keys(a).filter(e=>e.toLowerCase()!==\"authorization\").sort(),hasAuthorization:Object.keys(a).some(e=>e.toLowerCase()===\"authorization\"),hasChatGptAccountId:Object.keys(a).some(e=>e.toLowerCase()===\"chatgpt-account-id\")});await vv({appServerClient:e,deviceKeyClient:n,desktopApiOptions:t,enrollmentKey:hv(t),globalState:r,headers:a,requestRemoteControlEnrollmentStepUpToken:i});__codexRemoteControlFlowLog(\"remote_control_qm_completed\",{})}catch(e){__codexRemoteControlFlowLog(\"remote_control_qm_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code,stack:e?.stack});throw e}}";
  return {
    text: text.includes(oldBg)
      ? replaceExact(text, oldBg, newBg, "remote-control authorize flow")
      : text.includes(oldUg)
        ? replaceExact(text, oldUg, newUg, "remote-control authorize flow")
        : text.includes(oldN_)
          ? replaceExact(text, oldN_, newN_, "remote-control authorize flow")
          : text.includes(oldQ_)
            ? replaceExact(text, oldQ_, newQ_, "remote-control authorize flow")
            : replaceExact(text, oldPv, newPv, "remote-control authorize flow"),
    status: "patched",
  };
}

function patchDeviceKeyCreationLogs(text) {
  const marker = "remote_control_create_device_key_start";
  if (text.includes(marker)) {
    return { text, status: "already-patched" };
  }
  const oldCreate = "async function $g({accountUserId:e,clientId:t,deviceKeyClient:n}){let r=await n.createDeviceKey(`allow_os_protected_nonextractable`);return{accountUserId:e,algorithm:r.algorithm,clientId:t,keyId:r.keyId,protectionClass:r.protectionClass,publicKeySpkiDerBase64:r.publicKeySpkiDerBase64}}";
  const newCreate = "async function $g({accountUserId:e,clientId:t,deviceKeyClient:n}){__codexRemoteControlFlowLog(\"remote_control_create_device_key_start\",{});try{let r=await n.createDeviceKey(`allow_os_protected_nonextractable`);return __codexRemoteControlFlowLog(\"remote_control_create_device_key_done\",{algorithm:r.algorithm,protectionClass:r.protectionClass}),{accountUserId:e,algorithm:r.algorithm,clientId:t,keyId:r.keyId,protectionClass:r.protectionClass,publicKeySpkiDerBase64:r.publicKeySpkiDerBase64}}catch(e){__codexRemoteControlFlowLog(\"remote_control_create_device_key_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code});throw e}}";
  const oldCreate2611 = "async function S_({accountUserId:e,clientId:t,deviceKeyClient:n}){let r=await n.createDeviceKey(`allow_os_protected_nonextractable`);return{accountUserId:e,algorithm:r.algorithm,clientId:t,keyId:r.keyId,protectionClass:r.protectionClass,publicKeySpkiDerBase64:r.publicKeySpkiDerBase64}}";
  const newCreate2611 = "async function S_({accountUserId:e,clientId:t,deviceKeyClient:n}){__codexRemoteControlFlowLog(\"remote_control_create_device_key_start\",{});try{let r=await n.createDeviceKey(`allow_os_protected_nonextractable`);return __codexRemoteControlFlowLog(\"remote_control_create_device_key_done\",{algorithm:r.algorithm,protectionClass:r.protectionClass}),{accountUserId:e,algorithm:r.algorithm,clientId:t,keyId:r.keyId,protectionClass:r.protectionClass,publicKeySpkiDerBase64:r.publicKeySpkiDerBase64}}catch(e){__codexRemoteControlFlowLog(\"remote_control_create_device_key_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code});throw e}}";
  const oldCreate8604 = "async function F_({accountUserId:e,clientId:t,deviceKeyClient:n}){let r=await n.createDeviceKey(`allow_os_protected_nonextractable`);return{accountUserId:e,algorithm:r.algorithm,clientId:t,keyId:r.keyId,protectionClass:r.protectionClass,publicKeySpkiDerBase64:r.publicKeySpkiDerBase64}}";
  const newCreate8604 = "async function F_({accountUserId:e,clientId:t,deviceKeyClient:n}){__codexRemoteControlFlowLog(\"remote_control_create_device_key_start\",{});try{let r=await n.createDeviceKey(`allow_os_protected_nonextractable`);return __codexRemoteControlFlowLog(\"remote_control_create_device_key_done\",{algorithm:r.algorithm,protectionClass:r.protectionClass}),{accountUserId:e,algorithm:r.algorithm,clientId:t,keyId:r.keyId,protectionClass:r.protectionClass,publicKeySpkiDerBase64:r.publicKeySpkiDerBase64}}catch(e){__codexRemoteControlFlowLog(\"remote_control_create_device_key_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code});throw e}}";
  const oldCreate2616 = "async function jv({accountUserId:e,clientId:t,deviceKeyClient:n}){let r=await n.createDeviceKey(`allow_os_protected_nonextractable`);return{accountUserId:e,algorithm:r.algorithm,clientId:t,keyId:r.keyId,protectionClass:r.protectionClass,publicKeySpkiDerBase64:r.publicKeySpkiDerBase64}}";
  const newCreate2616 = "async function jv({accountUserId:e,clientId:t,deviceKeyClient:n}){__codexRemoteControlFlowLog(\"remote_control_create_device_key_start\",{});try{let r=await n.createDeviceKey(`allow_os_protected_nonextractable`);return __codexRemoteControlFlowLog(\"remote_control_create_device_key_done\",{algorithm:r.algorithm,protectionClass:r.protectionClass}),{accountUserId:e,algorithm:r.algorithm,clientId:t,keyId:r.keyId,protectionClass:r.protectionClass,publicKeySpkiDerBase64:r.publicKeySpkiDerBase64}}catch(e){__codexRemoteControlFlowLog(\"remote_control_create_device_key_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code});throw e}}";
  const oldCreate2623 = "async function Kv({accountUserId:e,clientId:t,deviceKeyClient:n}){let r=await n.createDeviceKey(`allow_os_protected_nonextractable`);return{accountUserId:e,algorithm:r.algorithm,clientId:t,keyId:r.keyId,protectionClass:r.protectionClass,publicKeySpkiDerBase64:r.publicKeySpkiDerBase64}}";
  const newCreate2623 = "async function Kv({accountUserId:e,clientId:t,deviceKeyClient:n}){__codexRemoteControlFlowLog(\"remote_control_create_device_key_start\",{});try{let r=await n.createDeviceKey(`allow_os_protected_nonextractable`);return __codexRemoteControlFlowLog(\"remote_control_create_device_key_done\",{algorithm:r.algorithm,protectionClass:r.protectionClass}),{accountUserId:e,algorithm:r.algorithm,clientId:t,keyId:r.keyId,protectionClass:r.protectionClass,publicKeySpkiDerBase64:r.publicKeySpkiDerBase64}}catch(e){__codexRemoteControlFlowLog(\"remote_control_create_device_key_failed\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code});throw e}}";
  return {
    text: text.includes(oldCreate)
      ? replaceExact(text, oldCreate, newCreate, "remote-control device key creation logs")
      : text.includes(oldCreate2611)
        ? replaceExact(text, oldCreate2611, newCreate2611, "remote-control device key creation logs")
        : text.includes(oldCreate8604)
          ? replaceExact(text, oldCreate8604, newCreate8604, "remote-control device key creation logs")
          : text.includes(oldCreate2616)
            ? replaceExact(text, oldCreate2616, newCreate2616, "remote-control device key creation logs")
            : replaceExact(text, oldCreate2623, newCreate2623, "remote-control device key creation logs"),
    status: "patched",
  };
}

function patchSoftwareDeviceKeyFallback(text) {
  const marker = "software_device_key_async_fallback";
  if (text.includes(marker)) {
    return { text, status: "already-patched" };
  }
  const oldWz = "function wZ({resourcesPath:e}){let t=null,n=()=>{if(process.platform!==`darwin`)throw Error(`Remote control device keys are only available on macOS`);if(e==null)throw Error(`Remote control device keys require resourcesPath`);return t??=bZ((0,a.join)(e,`native`,xZ)),t};return{createDeviceKey:e=>n().createDeviceKey(e??`hardware_only`),deleteDeviceKey:e=>n().deleteDeviceKey(e),getDeviceKeyPublic:e=>n().getDeviceKeyPublic(e),signDeviceKey:async(e,t)=>{let r=TZ(t);return{...await n().signDeviceKey(e,r),signedPayloadBase64:r.toString(`base64`)}}}}";
  const newWz = "function __codexSoftwareRemoteControlDeviceKeyClient(){let e=null,t=()=>{let t=require(\"node:os\"),n=require(\"node:path\"),r=require(\"node:fs\"),i=process.env.CODEX_REMOTE_CONTROL_SOFTWARE_DEVICE_KEYS_JSON?.trim()||n.join(t.homedir(),\".codex\",\"remote-control-device-keys.json\");return e??={path:i,fs:r,pathModule:n,crypto:require(\"node:crypto\")},e},n=()=>{let{path:e,fs:n}=t();try{return JSON.parse(n.readFileSync(e,\"utf8\"))}catch(e){if(e?.code===\"ENOENT\")return{keys:{}};throw e}},r=e=>{let{path:n}=t();__codexRemoteControlSafeWriteFile(n,JSON.stringify(e,null,2)+\"\\n\")},i=e=>{try{let t=n();return t.keys?.[e]??null}catch{return null}},a=e=>{let t=n();t.keys?.[e]&&delete t.keys[e];r(t)},o=e=>{let{crypto:t}=globalThis.__codexSoftwareRemoteControlDeviceKeyClientState??(globalThis.__codexSoftwareRemoteControlDeviceKeyClientState={crypto:require(\"node:crypto\")}),i=n(),a=t.generateKeyPairSync(\"ec\",{namedCurve:\"prime256v1\",publicKeyEncoding:{type:\"spki\",format:\"der\"},privateKeyEncoding:{type:\"pkcs8\",format:\"pem\"}}),o=\"sw_\"+t.randomUUID().replace(/-/g,\"\"),s={algorithm:\"ecdsa_p256_sha256\",keyId:o,protectionClass:\"os_protected_nonextractable\",publicKeySpkiDerBase64:a.publicKey.toString(\"base64\"),privateKeyPkcs8Pem:a.privateKey,createdAt:new Date().toISOString(),policy:e};return i.keys??={},i.keys[o]=s,r(i),{algorithm:s.algorithm,keyId:s.keyId,protectionClass:s.protectionClass,publicKeySpkiDerBase64:s.publicKeySpkiDerBase64}},s=(e,n)=>{let r=i(e);if(r==null)throw Error(\"software remote-control device key not found\");let{crypto:a}=t(),o=a.sign(\"sha256\",n,{key:r.privateKeyPkcs8Pem,dsaEncoding:\"der\"});return{algorithm:r.algorithm,signatureDerBase64:o.toString(\"base64\")}},c=e=>i(e)!=null;return{hasDeviceKey:c,createDeviceKey:o,deleteDeviceKey:a,getDeviceKeyPublic:e=>{let t=i(e);if(t==null)throw Error(\"software remote-control device key not found\");return{algorithm:t.algorithm,keyId:t.keyId,protectionClass:t.protectionClass,publicKeySpkiDerBase64:t.publicKeySpkiDerBase64}},signDeviceKey:s}}function wZ({resourcesPath:e}){let t=null,n=()=>{if(process.platform!==`darwin`)throw Error(`Remote control device keys are only available on macOS`);if(e==null)throw Error(`Remote control device keys require resourcesPath`);return t??=bZ((0,a.join)(e,`native`,xZ)),t},r=null,i=()=>r??=__codexSoftwareRemoteControlDeviceKeyClient(),o=e=>{__codexRemoteControlFlowLog(\"software_device_key_async_fallback\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code})};return{createDeviceKey:async e=>{try{return await n().createDeviceKey(e??`hardware_only`)}catch(t){if((process.env.CODEX_REMOTE_CONTROL_SOFTWARE_DEVICE_KEY_FALLBACK??`1`)===`0`)throw t;o(t);return i().createDeviceKey(e??`hardware_only`)}},deleteDeviceKey:e=>i().hasDeviceKey(e)?i().deleteDeviceKey(e):n().deleteDeviceKey(e),getDeviceKeyPublic:e=>i().hasDeviceKey(e)?i().getDeviceKeyPublic(e):n().getDeviceKeyPublic(e),signDeviceKey:async(e,t)=>{let r=TZ(t);if(i().hasDeviceKey(e)){let t=i().signDeviceKey(e,r);return{...t,signedPayloadBase64:r.toString(`base64`)}}return{...await n().signDeviceKey(e,r),signedPayloadBase64:r.toString(`base64`)}}}}";
  const oldPq = "function pQ({resourcesPath:e}){let t=null,n=()=>{if(process.platform!==`darwin`)throw Error(`Remote control device keys are only available on macOS`);if(e==null)throw Error(`Remote control device keys require resourcesPath`);return t??=lQ((0,s.join)(e,`native`,uQ)),t};return{createDeviceKey:e=>n().createDeviceKey(e??`hardware_only`),deleteDeviceKey:e=>n().deleteDeviceKey(e),getDeviceKeyPublic:e=>n().getDeviceKeyPublic(e),signDeviceKey:async(e,t)=>{let r=mQ(t);return{...await n().signDeviceKey(e,r),signedPayloadBase64:r.toString(`base64`)}}}}";
  const newPq = "function __codexSoftwareRemoteControlDeviceKeyClient(){let e=null,t=()=>{let t=require(\"node:os\"),n=require(\"node:path\"),r=require(\"node:fs\"),i=process.env.CODEX_REMOTE_CONTROL_SOFTWARE_DEVICE_KEYS_JSON?.trim()||n.join(t.homedir(),\".codex\",\"remote-control-device-keys.json\");return e??={path:i,fs:r,pathModule:n,crypto:require(\"node:crypto\")},e},n=()=>{let{path:e,fs:n}=t();try{return JSON.parse(n.readFileSync(e,\"utf8\"))}catch(e){if(e?.code===\"ENOENT\")return{keys:{}};throw e}},r=e=>{let{path:n}=t();__codexRemoteControlSafeWriteFile(n,JSON.stringify(e,null,2)+\"\\n\")},i=e=>{try{let t=n();return t.keys?.[e]??null}catch{return null}},a=e=>{let t=n();t.keys?.[e]&&delete t.keys[e];r(t)},o=e=>{let{crypto:t}=globalThis.__codexSoftwareRemoteControlDeviceKeyClientState??(globalThis.__codexSoftwareRemoteControlDeviceKeyClientState={crypto:require(\"node:crypto\")}),i=n(),a=t.generateKeyPairSync(\"ec\",{namedCurve:\"prime256v1\",publicKeyEncoding:{type:\"spki\",format:\"der\"},privateKeyEncoding:{type:\"pkcs8\",format:\"pem\"}}),o=\"sw_\"+t.randomUUID().replace(/-/g,\"\"),s={algorithm:\"ecdsa_p256_sha256\",keyId:o,protectionClass:\"os_protected_nonextractable\",publicKeySpkiDerBase64:a.publicKey.toString(\"base64\"),privateKeyPkcs8Pem:a.privateKey,createdAt:new Date().toISOString(),policy:e};return i.keys??={},i.keys[o]=s,r(i),{algorithm:s.algorithm,keyId:s.keyId,protectionClass:s.protectionClass,publicKeySpkiDerBase64:s.publicKeySpkiDerBase64}},s=(e,n)=>{let r=i(e);if(r==null)throw Error(\"software remote-control device key not found\");let{crypto:a}=t(),o=a.sign(\"sha256\",n,{key:r.privateKeyPkcs8Pem,dsaEncoding:\"der\"});return{algorithm:r.algorithm,signatureDerBase64:o.toString(\"base64\")}},c=e=>i(e)!=null;return{hasDeviceKey:c,createDeviceKey:o,deleteDeviceKey:a,getDeviceKeyPublic:e=>{let t=i(e);if(t==null)throw Error(\"software remote-control device key not found\");return{algorithm:t.algorithm,keyId:t.keyId,protectionClass:t.protectionClass,publicKeySpkiDerBase64:t.publicKeySpkiDerBase64}},signDeviceKey:s}}function pQ({resourcesPath:e}){let t=null,n=()=>{if(process.platform!==`darwin`)throw Error(`Remote control device keys are only available on macOS`);if(e==null)throw Error(`Remote control device keys require resourcesPath`);return t??=lQ((0,s.join)(e,`native`,uQ)),t},r=null,i=()=>r??=__codexSoftwareRemoteControlDeviceKeyClient(),a=e=>{__codexRemoteControlFlowLog(\"software_device_key_async_fallback\",{errorName:e?.name,errorMessage:e?.message,errorCode:e?.code})};return{createDeviceKey:async e=>{try{return await n().createDeviceKey(e??`hardware_only`)}catch(t){if((process.env.CODEX_REMOTE_CONTROL_SOFTWARE_DEVICE_KEY_FALLBACK??`1`)===`0`)throw t;a(t);return i().createDeviceKey(e??`hardware_only`)}},deleteDeviceKey:e=>i().hasDeviceKey(e)?i().deleteDeviceKey(e):n().deleteDeviceKey(e),getDeviceKeyPublic:e=>i().hasDeviceKey(e)?i().getDeviceKeyPublic(e):n().getDeviceKeyPublic(e),signDeviceKey:async(e,t)=>{let r=mQ(t);if(i().hasDeviceKey(e)){let t=i().signDeviceKey(e,r);return{...t,signedPayloadBase64:r.toString(`base64`)}}return{...await n().signDeviceKey(e,r),signedPayloadBase64:r.toString(`base64`)}}}}";
  const oldEq = "function EQ({resourcesPath:e}){let t=null,n=()=>{if(process.platform!==`darwin`)throw Error(`Remote control device keys are only available on macOS`);if(e==null)throw Error(`Remote control device keys require resourcesPath`);return t??=SQ((0,s.join)(e,`native`,CQ)),t};return{createDeviceKey:e=>n().createDeviceKey(e??`hardware_only`),deleteDeviceKey:e=>n().deleteDeviceKey(e),getDeviceKeyPublic:e=>n().getDeviceKeyPublic(e),signDeviceKey:async(e,t)=>{let r=DQ(t);return{...await n().signDeviceKey(e,r),signedPayloadBase64:r.toString(`base64`)}}}}";
  const newEq = newPq
    .replace("function pQ({resourcesPath:e})", "function EQ({resourcesPath:e})")
    .replace("lQ((0,s.join)(e,`native`,uQ))", "SQ((0,s.join)(e,`native`,CQ))")
    .replaceAll("mQ(t)", "DQ(t)");
  const oldL$ = "function L$({resourcesPath:e}){let t=null,n=()=>{if(process.platform!==`darwin`)throw Error(`Remote control device keys are only available on macOS`);if(e==null)throw Error(`Remote control device keys require resourcesPath`);return t??=N$((0,s.join)(e,`native`,P$)),t};return{createDeviceKey:e=>n().createDeviceKey(e??`hardware_only`),deleteDeviceKey:e=>n().deleteDeviceKey(e),getDeviceKeyPublic:e=>n().getDeviceKeyPublic(e),signDeviceKey:async(e,t)=>{let r=R$(t);return{...await n().signDeviceKey(e,r),signedPayloadBase64:r.toString(`base64`)}}}}";
  const newL$ = newPq
    .replace("function pQ({resourcesPath:e})", "function L$({resourcesPath:e})")
    .replace("lQ((0,s.join)(e,`native`,uQ))", "N$((0,s.join)(e,`native`,P$))")
    .replaceAll("mQ(t)", "R$(t)");
  const oldD0 = "function d0({resourcesPath:e}){let t=null,n=()=>{if(process.platform!==`darwin`)throw Error(`Remote control device keys are only available on macOS`);if(e==null)throw Error(`Remote control device keys require resourcesPath`);return t??=s0((0,s.join)(e,`native`,c0)),t};return{createDeviceKey:e=>n().createDeviceKey(e??`hardware_only`),deleteDeviceKey:e=>n().deleteDeviceKey(e),getDeviceKeyPublic:e=>n().getDeviceKeyPublic(e),signDeviceKey:async(e,t)=>{let r=f0(t);return{...await n().signDeviceKey(e,r),signedPayloadBase64:r.toString(`base64`)}}}}";
  const newD0 = newPq
    .replace("function pQ({resourcesPath:e})", "function d0({resourcesPath:e})")
    .replace("lQ((0,s.join)(e,`native`,uQ))", "s0((0,s.join)(e,`native`,c0))")
    .replaceAll("mQ(t)", "f0(t)");
  return {
    text: text.includes(oldWz)
      ? replaceExact(text, oldWz, newWz, "remote-control software device-key fallback")
      : text.includes(oldPq)
        ? replaceExact(text, oldPq, newPq, "remote-control software device-key fallback")
        : text.includes(oldEq)
          ? replaceExact(text, oldEq, newEq, "remote-control software device-key fallback")
          : text.includes(oldL$)
            ? replaceExact(text, oldL$, newL$, "remote-control software device-key fallback")
            : replaceExact(text, oldD0, newD0, "remote-control software device-key fallback"),
    status: "patched",
  };
}

function patchMobileSetup(text) {
  const marker = "remote_control_mobile_setup_no_auth_redirect";
  if (text.includes(marker)) {
    return { text, status: "already-patched" };
  }
  const oldUi =
    "e.status===401?(J(),new Se(`ChatGPT auth is required to load remote control environments.`))";
  const newUi =
    "e.status===401?(void\"remote_control_mobile_setup_no_auth_redirect\",new Se(`ChatGPT auth is required to load remote control environments.`))";
  const oldEffect2611 = "Y=()=>{J&&u(`/login`,{replace:!0})}";
  const newEffect2611 = "Y=()=>{J&&void\"remote_control_mobile_setup_no_auth_redirect\"}";
  const queryRedirectPattern =
    /e\.status===401\?\([A-Za-z_$][\w$]*\(\),new ([A-Za-z_$][\w$]*)\(`ChatGPT auth is required to load remote control environments\.`\)\)/;
  let next;
  if (text.includes(oldUi)) {
    next = replaceExact(text, oldUi, newUi, "mobile setup 401 login redirect");
  } else if (queryRedirectPattern.test(text)) {
    next = text.replace(
      queryRedirectPattern,
      (_match, ctor) =>
        `e.status===401?(void"remote_control_mobile_setup_no_auth_redirect",new ${ctor}(\`ChatGPT auth is required to load remote control environments.\`))`
    );
  } else {
    next = replaceExact(text, oldEffect2611, newEffect2611, "mobile setup 401 login redirect");
  }
  if (next.includes(oldUi) || next.includes(oldEffect2611) || !next.includes(marker)) {
    throw new Error("mobile setup 401 redirect still present after patch");
  }
  return { text: next, status: "patched" };
}

function patchMobileSetupMfaInfo403(text) {
  const marker = "remote_control_mfa_info_403_nonblocking";
  if (text.includes(marker)) {
    return { text, status: "already-patched" };
  }
  const oldMfaInfo =
    "async function k(){return S.parse(await _.safeGet(`/accounts/mfa_info`)).mfa_enabled_v2}";
  const newMfaInfo =
    "async function k(){try{return S.parse(await _.safeGet(`/accounts/mfa_info`)).mfa_enabled_v2}catch(e){if(e instanceof d&&e.status===403)return void\"remote_control_mfa_info_403_nonblocking\",!0;throw e}}";
  const oldMfaInfo2623 =
    "async function Te(){return D.parse(await p.safeGet(`/accounts/mfa_info`)).mfa_enabled_v2}";
  const newMfaInfo2623 =
    "async function Te(){try{return D.parse(await p.safeGet(`/accounts/mfa_info`)).mfa_enabled_v2}catch(e){if(e instanceof re&&e.status===403)return void\"remote_control_mfa_info_403_nonblocking\",!0;throw e}}";
  let next;
  if (text.includes(oldMfaInfo)) {
    next = replaceExact(text, oldMfaInfo, newMfaInfo, "mobile setup MFA info 403 fallback");
  } else if (text.includes(oldMfaInfo2623)) {
    next = replaceExact(text, oldMfaInfo2623, newMfaInfo2623, "mobile setup MFA info 403 fallback 26.623");
  } else {
    const mfaInfoPattern =
      /async function ([A-Za-z_$][\w$]*)\(\)\{return ([A-Za-z_$][\w$]*)\.parse\(await ([A-Za-z_$][\w$]*)\.safeGet\(`\/accounts\/mfa_info`\)\)\.mfa_enabled_v2\}/;
    if (!mfaInfoPattern.test(text)) {
      throw new Error("mobile setup MFA info query anchor not found");
    }
    next = text.replace(
      mfaInfoPattern,
      (_match, fnName, schemaName, requestName) =>
        `async function ${fnName}(){try{return ${schemaName}.parse(await ${requestName}.safeGet(\`/accounts/mfa_info\`)).mfa_enabled_v2}catch(e){if(e instanceof d&&e.status===403)return void"remote_control_mfa_info_403_nonblocking",!0;throw e}}`
    );
  }
  if (!next.includes(marker) || !next.includes("/accounts/mfa_info")) {
    throw new Error("mobile setup MFA info 403 fallback marker missing after patch");
  }
  return { text: next, status: "patched" };
}

function patchMobileSetupClientListPartialFailure(text) {
  const marker = "remote_control_client_list_partial_failure_nonblocking";
  if (text.includes(marker)) {
    return { text, status: "already-patched" };
  }
  const oldClientList =
    "async function I(e,{appServerHostId:t,includeBrowserClients:n=!0}={}){let[r,i]=await Promise.all([n&&t==null?j():[],e==null?[]:R(t??`local`,e)]),a=new Map;for(let e of r)a.set(e.client_id,z(e));for(let e of i)a.set(e.clientId,e);return Array.from(a.values())}";
  const newClientList =
    "async function I(e,{appServerHostId:t,includeBrowserClients:n=!0}={}){let[r,i]=await Promise.all([n&&t==null?j().catch(e=>{throw e}):[],e==null?[]:R(t??`local`,e).catch(e=>(void\"remote_control_client_list_partial_failure_nonblocking\",[]))]),a=new Map;for(let e of r)a.set(e.client_id,z(e));for(let e of i)a.set(e.clientId,e);return Array.from(a.values())}";
  let next;
  if (text.includes(oldClientList)) {
    next = replaceExact(text, oldClientList, newClientList, "mobile setup client list partial failure fallback");
  } else {
    const clientListPattern =
      /async function ([A-Za-z_$][\w$]*)\(e,\{appServerHostId:t,includeBrowserClients:n=!0\}=\{\}\)\{let\[r,i\]=await Promise\.all\(\[n&&t==null\?([A-Za-z_$][\w$]*)\(\):\[\],e==null\?\[\]:([A-Za-z_$][\w$]*)\(t\?\?`local`,e\)\]\),a=new Map;for\(let e of r\)a\.set\(e\.client_id,([A-Za-z_$][\w$]*)\(e\)\);for\(let e of i\)a\.set\(e\.clientId,e\);return Array\.from\(a\.values\(\)\)\}/;
    if (!clientListPattern.test(text)) {
      throw new Error("mobile setup client list merge anchor not found");
    }
    next = text.replace(
      clientListPattern,
      (_match, fnName, browserListFn, appServerListFn, browserMapFn) =>
        `async function ${fnName}(e,{appServerHostId:t,includeBrowserClients:n=!0}={}){let[r,i]=await Promise.all([n&&t==null?${browserListFn}().catch(e=>{throw e}):[],e==null?[]:${appServerListFn}(t??\`local\`,e).catch(e=>(void"remote_control_client_list_partial_failure_nonblocking",[]))]),a=new Map;for(let e of r)a.set(e.client_id,${browserMapFn}(e));for(let e of i)a.set(e.clientId,e);return Array.from(a.values())}`
    );
  }
  if (!next.includes(marker) || !next.includes("/wham/remote/control/clients")) {
    throw new Error("mobile setup client list partial-failure marker missing after patch");
  }
  return { text: next, status: "patched" };
}

function patchMobileSetupFlow(text) {
  const marker = "remote_control_mobile_setup_authorize_before_enable";
  if (text.includes(marker)) {
    return { text, status: "already-patched" };
  }
  const oldFlow =
    "async function z(e,t,n){return t===`local`?(await b(`set-local-remote-control-enabled`,{params:{enabled:n}}),T(e,n,{force:!0})):w(e,t,n)}";
  const newFlow =
    "async function z(e,t,n){return t===`local`?(n&&(void\"remote_control_mobile_setup_authorize_before_enable\",await b(`authorize-remote-control-connections`,{params:{}})),await b(`set-local-remote-control-enabled`,{params:{enabled:n}}),T(e,n,{force:!0})):w(e,t,n)}";
  const oldFlow2611 =
    "async function N(e,t,n){return t===`local`?(await y(`set-local-remote-control-enabled`,{params:{enabled:n}}),le(e,n,{force:!0})):E(e,t,n)}";
  const newFlow2611 =
    "async function N(e,t,n){return t===`local`?(n&&(void\"remote_control_mobile_setup_authorize_before_enable\",await y(`authorize-remote-control-connections`,{params:{}})),await y(`set-local-remote-control-enabled`,{params:{enabled:n}}),le(e,n,{force:!0})):E(e,t,n)}";
  const oldFlow2616 =
    "async function F(e,t,n){return t===`local`?(await y(`set-local-remote-control-enabled`,{params:{enabled:n}}),k(e,n,{force:!0})):se(e,t,n)}";
  const newFlow2616 =
    "async function F(e,t,n){return t===`local`?(n&&(void\"remote_control_mobile_setup_authorize_before_enable\",await y(`authorize-remote-control-connections`,{params:{}})),await y(`set-local-remote-control-enabled`,{params:{enabled:n}}),k(e,n,{force:!0})):se(e,t,n)}";
  const oldFlow2623 =
    "async function je(e,t,n){return t===`local`?(await g(`set-local-remote-control-enabled`,{params:{enabled:n}}),W(e,n,{force:!0})):q(e,t,n)}";
  const newFlow2623 =
    "async function je(e,t,n){return t===`local`?(n&&(void\"remote_control_mobile_setup_authorize_before_enable\",await g(`authorize-remote-control-connections`,{params:{}})),await g(`set-local-remote-control-enabled`,{params:{enabled:n}}),W(e,n,{force:!0})):q(e,t,n)}";
  const oldFlow26707 =
    "async function je(e,t,n){return t===`local`?(await h(`set-local-remote-control-enabled`,{params:{enabled:n}}),W(e,n,{force:!0})):q(e,t,n)}";
  const newFlow26707 =
    "async function je(e,t,n){return t===`local`?(n&&(void\"remote_control_mobile_setup_authorize_before_enable\",await h(`authorize-remote-control-connections`,{params:{}})),await h(`set-local-remote-control-enabled`,{params:{enabled:n}}),W(e,n,{force:!0})):q(e,t,n)}";
  const next = text.includes(oldFlow)
    ? replaceExact(text, oldFlow, newFlow, "mobile setup authorize before local enable")
    : text.includes(oldFlow2611)
      ? replaceExact(text, oldFlow2611, newFlow2611, "mobile setup authorize before local enable")
      : text.includes(oldFlow2616)
        ? replaceExact(text, oldFlow2616, newFlow2616, "mobile setup authorize before local enable")
        : text.includes(oldFlow2623)
          ? replaceExact(text, oldFlow2623, newFlow2623, "mobile setup authorize before local enable")
          : replaceExact(text, oldFlow26707, newFlow26707, "mobile setup authorize before local enable");
  if (!next.includes(marker) || !next.includes("authorize-remote-control-connections")) {
    throw new Error("mobile setup flow authorize-before-enable marker missing after patch");
  }
  return { text: next, status: "patched" };
}

function patchRemoteConnectionsSettingsVisibility(text) {
  const marker = "remote_control_settings_force_control_this_pc_visible";
  const sectionMarker = "remote_control_settings_force_remote_control_section_visible";
  let next = text;
  let changed = false;
  const oldVisibility = "ye=Fe(),xe=!c,";
  const newVisibility = "ye=(void\"remote_control_settings_force_control_this_pc_visible\",!0),xe=!c,";
  const oldVisibility2611 = "We=be&&!0,";
  const newVisibility2611 = "We=(void\"remote_control_settings_force_control_this_pc_visible\",!0),";
  const oldVisibility2616 = "nt=Ne&&!0,";
  const newVisibility2616 = "nt=(void\"remote_control_settings_force_control_this_pc_visible\",!0),";
  const oldVisibility2623 = "Ge=H&&!0,";
  const newVisibility2623 = "Ge=(void\"remote_control_settings_force_control_this_pc_visible\",!0),";
  const oldVisibility26707 = "dn=[...Ue?cn:[],...Ge?sn:[],...ln,...ve?un:[]];";
  const newVisibility26707 = "dn=[...(void\"remote_control_settings_force_control_this_pc_visible\",!0)?cn:[],...(void\"remote_control_settings_force_remote_control_section_visible\",!0)?sn:[],...ln,...ve?un:[]];";
  if (!next.includes(marker)) {
    next = next.includes(oldVisibility)
      ? replaceExact(next, oldVisibility, newVisibility, "remote connections local setup visibility")
      : next.includes(oldVisibility2611)
        ? replaceExact(next, oldVisibility2611, newVisibility2611, "remote connections local setup visibility")
        : next.includes(oldVisibility2616)
          ? replaceExact(next, oldVisibility2616, newVisibility2616, "remote connections local setup visibility")
          : next.includes(oldVisibility2623)
            ? replaceExact(next, oldVisibility2623, newVisibility2623, "remote connections local setup visibility")
            : replaceExact(next, oldVisibility26707, newVisibility26707, "remote connections local setup visibility");
    changed = true;
  }
  if (!next.includes(sectionMarker)) {
    const oldSection2611 = "be=qe(),X=!f,";
    const newSection2611 =
      "be=(void\"remote_control_settings_force_remote_control_section_visible\",!0),X=!f,";
    const oldSection2616 = "Ne=Xe(),X=!T,";
    const newSection2616 =
      "Ne=(void\"remote_control_settings_force_remote_control_section_visible\",!0),X=!T,";
    const oldSection2623 = "H=jn(),W=!p,";
    const newSection2623 =
      "H=(void\"remote_control_settings_force_remote_control_section_visible\",!0),W=!p,";
    next = next.includes(oldSection2611)
      ? replaceExact(next, oldSection2611, newSection2611, "remote connections remote-control section visibility")
      : next.includes(oldSection2616)
        ? replaceExact(next, oldSection2616, newSection2616, "remote connections remote-control section visibility")
        : next.includes(oldSection2623)
          ? replaceExact(next, oldSection2623, newSection2623, "remote connections remote-control section visibility")
          : next;
    changed = true;
  }
  if (!next.includes(marker) || !next.includes(sectionMarker) || !next.includes("showControlThisMacTab")) {
    throw new Error("remote connections settings visibility marker missing after patch");
  }
  return { text: next, status: changed ? "patched" : "already-patched" };
}

let mainText = read(mainFile);
const mainStatuses = {};
for (const [name, patcher] of [
  ["flowHelpers", patchFlowHelpers],
  ["desktopFetch", patchDesktopFetch],
  ["appServerAuthFallback", patchAppServerAuthFallback],
]) {
  const result = patcher(mainText);
  mainText = result.text;
  mainStatuses[name] = result.status;
}

for (const marker of [
  "remote_control_flow_log_ready",
  "remote_control_desktop_fetch_override_used",
  "remote_control_appserver_bh_isolated_auth_fallback",
  "remote_control_connection_auth_fallback_used",
]) {
  if (!mainText.includes(marker)) {
    throw new Error(`main bundle marker missing after patch: ${marker}`);
  }
}
write(mainFile, mainText);

const mobileResults = [];
for (const mobileSetupNoAuthRedirectFile of mobileSetupNoAuthRedirectFiles) {
  let mobileText = read(mobileSetupNoAuthRedirectFile);
  const mobileResult = patchMobileSetup(mobileText);
  mobileText = mobileResult.text;
  if (
    mobileText.includes("e.status===401?(J(),new Se(") ||
    /e\.status===401\?\([A-Za-z_$][\w$]*\(\),new [A-Za-z_$][\w$]*\(`ChatGPT auth is required to load remote control environments\.`\)\)/.test(mobileText)
  ) {
    throw new Error("mobile setup forced ChatGPT auth redirect still present");
  }
  write(mobileSetupNoAuthRedirectFile, mobileText);
  mobileResults.push({ file: mobileSetupNoAuthRedirectFile, status: mobileResult.status });
}

let mobileSetupMfaInfoText = read(mobileSetupMfaInfoFile);
const mobileSetupMfaInfoResult = patchMobileSetupMfaInfo403(mobileSetupMfaInfoText);
mobileSetupMfaInfoText = mobileSetupMfaInfoResult.text;
const mobileSetupClientListResult = patchMobileSetupClientListPartialFailure(mobileSetupMfaInfoText);
mobileSetupMfaInfoText = mobileSetupClientListResult.text;
write(mobileSetupMfaInfoFile, mobileSetupMfaInfoText);

let mobileFlowText = read(mobileSetupFlowFile);
const mobileFlowResult = patchMobileSetupFlow(mobileFlowText);
mobileFlowText = mobileFlowResult.text;
write(mobileSetupFlowFile, mobileFlowText);

let remoteConnectionsSettingsText = read(remoteConnectionsSettingsFile);
const remoteConnectionsSettingsResult = patchRemoteConnectionsSettingsVisibility(remoteConnectionsSettingsText);
remoteConnectionsSettingsText = remoteConnectionsSettingsResult.text;
write(remoteConnectionsSettingsFile, remoteConnectionsSettingsText);

process.stdout.write(
  JSON.stringify(
    {
      mainFile,
      mainStatus: mainStatuses,
      mobileSetupNoAuthRedirectFiles: mobileResults,
      mobileSetupMfaInfoFile,
      mobileSetupMfaInfoStatus: mobileSetupMfaInfoResult.status,
      mobileSetupClientListStatus: mobileSetupClientListResult.status,
      mobileSetupFlowFile,
      mobileSetupFlowStatus: mobileFlowResult.status,
      remoteConnectionsSettingsFile,
      remoteConnectionsSettingsStatus: remoteConnectionsSettingsResult.status,
    },
    null,
    2
  )
);
