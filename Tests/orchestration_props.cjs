const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const html = fs.readFileSync('assets/orchestration.html', 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
new vm.Script(script);
function source(name, next) {
  return script.slice(script.indexOf(`    function ${name}(`), script.indexOf(`    function ${next}(`));
}
const context = vm.createContext({ selectedStep: {type: 'script', script_name: 'child.json'},
  dirty: false, renderAll() {}, showStatus(message, error) { if (error) this.error = message; } });
vm.runInContext(source('readScriptProps', 'addStep') + source('updateParameter', 'readScriptProps'), context);
assert.equal(context.readScriptProps('  '), undefined);
assert.equal(context.readScriptProps('"${props}"'), '${props}');
for (const value of ['null', '[]', '1', 'true', '"text"', '{']) {
  assert.throws(() => context.readScriptProps(value));
}
context.updateParameter('props', undefined, {value: '{"wait_ms":1000,"roi":"${roi}"}'});
assert.equal(JSON.stringify(context.selectedStep.props), '{"wait_ms":1000,"roi":"${roi}"}');
context.updateParameter('props', context.selectedStep.props, {value: ''});
assert.equal(Object.hasOwn(context.selectedStep, 'props'), false);
assert.equal(context.selectedStep.script_name, 'child.json');
console.log('Orchestration props parsing, saving, omission, and JavaScript syntax passed');
