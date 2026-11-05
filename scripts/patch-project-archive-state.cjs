'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const recovery = 'function ez(e){let t=eu(e);if(null!=t)return t;let r=eu(`${e}.bak`);if(null!=r)return K().warning("Loaded global state from backup",{safe:{},sensitive:{}}),r;let i=(0,o.dirname)(e),s=`.${(0,o.basename)(e)}.tmp-`,a=`.${(0,o.basename)(e)}.bak.tmp-`,l=[];try{for(let e of(0,n.readdirSync)(i)){if(!e.startsWith(s)&&!e.startsWith(a))continue;let t=(0,o.join)(i,e);try{let e=(0,n.lstatSync)(t);e.isFile()&&l.push({path:t,mtime:e.mtimeMs})}catch{}}}catch{}for(let e of l.sort((e,t)=>t.mtime-e.mtime)){let t=eu(e.path);if(null!=t)return K().warning("Recovered global state from interrupted write",{safe:{},sensitive:{}}),t}return new Map}';

const profiles = [
  {
    kind: 'global-state',
    file: 'early-bootstrap-133-27035703de164763.js',
    sha256: ['df82c9a76c02589e115937da6cc6016a85ad03b5ce171f5fe844e9694874c17d'],
    edits: [
      ['this.state=function(e){if(!(0,n.existsSync)(e))return new Map;let t=eu(e);if(null!=t)return t;let r=eu(`${e}.bak`);return null!=r?(K().warning("Loaded global state from backup",{safe:{},sensitive:{}}),r):new Map}(this.filePath)', 'this.state=ez(this.filePath)'],
      ['function eu(e){', recovery + 'function eu(e){'],
      ['(0,n.writeFileSync)(r,t,"utf8")', '(0,n.writeFileSync)(r,t,{encoding:"utf8",flush:!0})'],
      ['(0,s.writeFile)(r,t,"utf8")', '(0,s.writeFile)(r,t,{encoding:"utf8",flush:!0})'],
    ],
  },
  {
    kind: 'project-membership',
    file: 'early-bootstrap-499-8b3807f1185eeae8.js',
    sha256: [
      '1f7b01a46ac107c75609ce8f0fc958ea2ef584493d1b338b4683a4e3958dd3be',
      '91ed814e18c0d55a585dfa359829746df6e8eb2f7488bfe9bfd71378ef24cdf1',
    ],
    edits: [
      ['E.setThreadAssignmentsEnabled(tl().localProjectTaskMembership)', 'E.setThreadAssignmentsEnabled(tl().localProjectTaskMembership||process.platform==="win32"/*codex_windows_local_project_membership_persistence*/)'],
    ],
  },
  {
    kind: 'archive-errors',
    file: 'app-primary-93b5541c5ac8.js',
    sha256: ['511ea3f88380ed9cc24b57fcbf645031a3494d568157ecb85f75dd651658cb25'],
    edits: [
      ['function kjn(){let e=(0,Jjn.c)(122)', 'function kjn(){let e=(0,Jjn.c)(123)'],
      ['let Be=ze,Ve;e[40]!==P||e[41]!==R||e[42]!==ae||e[43]!==C||e[44]!==W||e[45]!==L?(Ve=L&&P.some(Njn)||C&&W||R&&ae,e[40]=P,e[41]=R,e[42]=ae,e[43]=C,e[44]=W,e[45]=L,e[46]=Ve):Ve=e[46];let He=Ve,Ue;', 'let Be=ze,He=Se&&we.some(Njn)||Te&&W||Ee&&ae/*codex_archive_error_scope_v1*/,Ue;'],
      ['e[112]!==Be||e[113]!==oe?(at=!Be&&Ee&&ae?', 'e[112]!==Be||e[113]!==oe||e[122]!==Ne.length?(at=!Be&&Ee&&ae&&Ne.length===0?'],
      ['e[113]=oe,e[114]=at):at=e[114];let ot;', 'e[113]=oe,e[114]=at,e[122]=Ne.length):at=e[114];let ot;'],
    ],
  },
];

profiles.push(
  { ...profiles[0], file: 'early-bootstrap-133-485dbc70b8296756.js', sha256: ['8cf2f389549308e8913c1472c576d6cb7b6d8ba6a9524cdd0fd49960a9224699'] },
  {
    kind: 'project-membership',
    file: 'early-bootstrap-632-62c641245a52ef0e.js',
    sha256: ['c16675e64dae86bdb09f7720f038a8c2f2beacf0e85bbadd369f407d38662aa4'],
    compatibleEdits: [['isAvailable:({features:e})=>e.deepResearch',
      'isAvailable:()=>!0/*codex_windows_deep_research_bundled_plugin_available*/']],
    edits: [['M.setThreadAssignmentsEnabled(tl().localProjectTaskMembership)', 'M.setThreadAssignmentsEnabled(tl().localProjectTaskMembership||process.platform==="win32"/*codex_windows_local_project_membership_persistence*/)']],
  },
  {
    kind: 'archive-errors',
    file: 'async/678916.1a2b7b8d2a.js',
    sha256: ['2b052845ef91d58cdf5a508c18ff2f362b295b568c05d55ea1766f110334aa26'],
    edits: [
      ['function eU(e){let t,a,s,l,o,d,c,u,g,m,p,A,_,P,M,D,F,T,B,q,Q,K,W,R,z,X,Y=(0,i.c)(132)', 'function eU(e){let t,a,s,l,o,d,c,u,g,m,p,A,_,P,M,D,F,T,B,q,Q,K,W,R,z,X,Y=(0,i.c)(133)'],
      ['isLocalArchiveError:S&&eC,', 'isLocalArchiveError:S&&(ey?.length??0)===0&&eC/*codex_archive_local_error_scope_v2*/,'],
      ['isDurableArchiveError:S&&null!=q[1]&&(', 'isDurableArchiveError:S&&null!=q[1]&&(q[1].data?.length??0)===0&&('],
      ['chatGptArchiveError:Y&&ec?eh:null,', 'chatGptArchiveError:Y&&ec&&(J?.length??0)===0?eh:null/*codex_archive_cloud_error_scope_v2*/,'],
      ['Y[115]!==tr?(K=(null!=eA||tr||ti)&&!eC?', 'Y[115]!==tr||Y[132]!==ee.length?(K=ee.length===0&&(null!=eA||tr||ti)&&!eC?'],
      ['Y[115]=tr,Y[116]=K):K=Y[116]', 'Y[115]=tr,Y[116]=K,Y[132]=ee.length):K=Y[116]'],
    ],
  },
);

function relativePath(profile) {
  return (profile.kind === 'archive-errors' ? 'webview/assets/' : '.vite/build/') + profile.file;
}

function selectProfiles(hasFile) {
  const layouts = [profiles.slice(0, 3), profiles.slice(3, 6)];
  const matches = layouts.filter(layout => layout.every(profile => hasFile(relativePath(profile))));
  if (matches.length !== 1) throw new Error(`Expected one complete project/archive layout, found ${matches.length}`);
  return matches[0];
}

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function replaceOnce(text, before, after) {
  const count = text.split(before).length - 1;
  if (count !== 1) throw new Error(`Expected one patch anchor, found ${count}`);
  return text.replace(before, after);
}

function transform(source, profile) {
  // Normalize only the known desktop overlay, then require the complete source hash.
  const states = [[], ...(profile.compatibleEdits ? [profile.compatibleEdits] : [])];
  if (profile.compatibleEdits) {
    const desktop = require('./desktop-261029-profiles.json').files.find(entry =>
      entry.file === relativePath(profile) && profile.sha256.includes(entry.sha256));
    if (desktop) states.push(desktop.edits.map(({before, after}) => [before, after]));
  }
  for (const overlays of states) {
    try {
      const normalized = [...overlays].reverse().reduce((s, [before, after]) => replaceOnce(s, after, before), source);
      if (profile.sha256.includes(sha256(normalized))) {
        return { source: profile.edits.reduce((s, [before, after]) => replaceOnce(s, before, after), source), status: 'patched' };
      }
      const original = [...profile.edits].reverse().reduce((s, [before, after]) => replaceOnce(s, after, before), normalized);
      if (profile.sha256.includes(sha256(original))) return { source, status: 'already-patched' };
    } catch {}
  }
  throw new Error(`Unsupported or partial ${profile.kind} source: ${sha256(source)}`);
}

function patchFiles(asarRoot, backupRoot, checkOnly = false) {
  const targets = selectProfiles(rel => fs.existsSync(path.join(asarRoot, rel))).map(profile => {
    const target = path.join(asarRoot, relativePath(profile));
    const source = fs.readFileSync(target, 'utf8');
    return { target, original: source, profile, ...transform(source, profile) };
  });
  if (!checkOnly) {
    fs.mkdirSync(backupRoot, { recursive: true });
    for (const target of targets) {
      if (target.status === 'already-patched') continue;
      const backup = path.join(backupRoot, target.profile.file);
      fs.mkdirSync(path.dirname(backup), { recursive: true });
      if (fs.existsSync(backup)) {
        if (sha256(fs.readFileSync(backup)) !== sha256(target.original)) throw new Error('Existing backup does not match original');
      } else {
        const original = fs.readFileSync(target.target);
        if (sha256(original) !== sha256(target.original)) throw new Error('Target changed during preflight');
        fs.writeFileSync(backup, original, { flag: 'wx', flush: true });
      }
    }
    for (const target of targets) {
      if (target.status === 'already-patched') continue;
      fs.writeFileSync(target.target, target.source, { encoding: 'utf8', flush: true });
    }
  }
  return targets.map(({ profile, source, status }) => ({ kind: profile.kind, status, sha256: sha256(source) }));
}

module.exports = { profiles, selectProfiles, relativePath, transform, patchFiles };

if (require.main === module) {
  const [asarRoot, backupRoot, flag] = process.argv.slice(2);
  if (asarRoot && backupRoot === '--paths' && !flag) {
    selectProfiles(rel => fs.existsSync(path.join(asarRoot, rel))).forEach(profile => console.log(relativePath(profile)));
    process.exit(0);
  }
  if (!asarRoot || !backupRoot || (flag && flag !== '--check')) throw new Error('Usage: patch-project-archive-state.cjs <extracted-asar> <backup-root> [--check]');
  console.log(JSON.stringify(patchFiles(asarRoot, backupRoot, flag === '--check')));
}
