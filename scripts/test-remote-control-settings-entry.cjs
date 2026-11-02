const assert = require('node:assert/strict');
const fs = require('node:fs');
const { transform, tabMarker, sectionMarker } = require('./patch-remote-control-settings-entry.cjs');
let checks = 0;
function verify(source) {
  const result = transform(source);
  assert.equal(result.status, 'patched'); checks++;
  assert.equal(transform(result.text).text, result.text); checks++;
  assert.equal(transform(result.text).status, 'already-patched'); checks++;
  assert.ok(result.text.includes('authRequired:auth')); checks++;
  assert.ok(result.text.includes('accessRequired:access')); checks++;
  assert.ok(result.text.includes('(),void"' + sectionMarker)); checks++;
  for (const bad of [result.text.replace(tabMarker, 'partial'), result.text + ';void"' + sectionMarker + '";',
    result.text.replace('(void"' + tabMarker + '",!0)', 'V&&!0'), source + source,
    source.replace('showRemoteSshConnections:!0', 'showRemoteSshConnections:!1')]) {
    assert.throws(() => transform(bad)); checks++;
  }
}
const fixture = 'function view(){let cache=[],V=Ur(),H=!d,Se=h==null,Ce=g==null;let Qe=V&&!0,et=V&&!0,next=1;return route({showControlThisMacTab:Qe,showRemoteControlConnectionsSection:V,showRemoteSshConnections:!0,showTabbedSshPage:et,authRequired:auth,accessRequired:access})}';
verify(fixture);
verify(fixture.replaceAll('V', '$section').replaceAll('Qe', '_tab').replaceAll('Ur', '$hook'));
assert.throws(() => transform(fixture.replace('V=Ur()', 'V=unknown(argument)'))); checks++;
if (process.argv[2]) {
  const original = fs.readFileSync(process.argv[2], 'utf8');
  const result = transform(original);
  assert.equal(result.status, 'patched'); checks++;
  assert.equal(transform(result.text).status, 'already-patched'); checks++;
  assert.ok(original.includes('V=Ur(),H=!d,Se=h==null,')); checks++;
}
console.log('remote settings entry tests passed: ' + checks);
