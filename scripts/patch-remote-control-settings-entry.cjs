const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const tabMarker = 'remote_control_settings_force_control_this_pc_visible';
const sectionMarker = 'remote_control_settings_force_remote_control_section_visible';

function transform(source) {
  const markerCounts = [tabMarker, sectionMarker].map(marker => source.split(marker).length - 1);
  const original = /,([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\(\),([A-Za-z_$][\w$]*)=![A-Za-z_$][\w$]*,([A-Za-z_$][\w$]*)=[A-Za-z_$][\w$]*==null,/g;
  const route = /showControlThisMacTab:([A-Za-z_$][\w$]*),showRemoteControlConnectionsSection:([A-Za-z_$][\w$]*),showRemoteSshConnections:!0,showTabbedSshPage:([A-Za-z_$][\w$]*)/g;
  const routes = [...source.matchAll(route)];
  if (routes.length !== 1) throw new Error('Expected one complete remote settings route contract');
  const [, tab, section, tabbed] = routes[0];
  const tabSource = tab + '=' + section + '&&!0,';
  const tabPatched = tab + '=(void"' + tabMarker + '",!0),';
  const sectionPatched = new RegExp(',[' + 'A-Za-z_$][\\w$]*=\\(([A-Za-z_$][\\w$]*)\\(\\),void"' + sectionMarker + '",!0\\),', 'g');
  const patchedSections = [...source.matchAll(sectionPatched)];
  const originals = [...source.matchAll(original)].filter(match => match[1] === section);
  if (markerCounts.some(Boolean)) {
    if (markerCounts.some(count => count !== 1) || patchedSections.length !== 1 ||
        !patchedSections[0][0].startsWith(',' + section + '=' ) ||
        source.split(tabPatched).length !== 2 || source.includes(tabSource) || originals.length !== 0 ||
        !source.includes(tabbed + '=' + section + '&&!0,')) {
      throw new Error('Incomplete, mixed or duplicate remote settings entry patch');
    }
    return { text: source, status: 'already-patched' };
  }
  if (originals.length !== 1 || source.split(tabSource).length !== 2 ||
      !source.includes(tabbed + '=' + section + '&&!0,')) {
    throw new Error('Unsupported remote settings entry layout');
  }
  const match = originals[0];
  const after = match[0].replace(section + '=' + match[2] + '()', section + '=(' + match[2] + '(),void"' + sectionMarker + '",!0)');
  return { text: source.replace(match[0], after).replace(tabSource, tabPatched), status: 'patched' };
}

function patch(root) {
  const assets = path.join(root, 'webview', 'assets');
  const candidates = fs.readdirSync(assets).filter(name => /^remote-connections-settings-.*\.js$/.test(name));
  if (candidates.length !== 1) throw new Error('Expected exactly one remote connections settings asset');
  const file = path.join(assets, candidates[0]);
  const source = fs.readFileSync(file, 'utf8');
  const result = transform(source);
  // Parse as an ES module without evaluating Desktop imports or side effects.
  new vm.SourceTextModule(result.text);
  if (result.text !== source) fs.writeFileSync(file, result.text);
  return { settingsEntryOnly: true, status: result.status, files: [file], markers: [tabMarker, sectionMarker],
    authentication: 'unchanged', pairing: 'not-verified', native: 'unchanged' };
}

module.exports = { transform, patch, tabMarker, sectionMarker };
if (require.main === module) {
  if (process.argv.length !== 3) throw new Error('Usage: node --experimental-vm-modules patch-remote-control-settings-entry.cjs <extracted-asar>');
  process.stdout.write(JSON.stringify(patch(process.argv[2]), null, 2));
}
