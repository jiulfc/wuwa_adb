const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const html = fs.readFileSync('assets/orchestration_1.html', 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)?.[1];

assert.ok(script, 'inline editor script is present');
new vm.Script(script);
for (const type of ['if', 'while', 'run_until', 'tap', 'drag', 'ocr_text', 'return']) {
  assert.match(script, new RegExp(`\\b${type}: \\{ type: '${type}'`), `${type} exists in the palette model`);
}
for (const hook of ['loadDocument', 'markSaved', 'showStatus']) {
  assert.match(script, new RegExp(`function ${hook}\\(`), `${hook} remains available to the native bridge`);
}
assert.match(script, /node\.className = `flow-node/);
assert.match(html, /className = 'branch-board'/);
assert.match(script, /board\.dataset\.branches = String\(keys\.length\)/);
assert.match(html, /\.branch-board\[data-branches="2"\]::after/);
assert.match(html, /className = 'event-dot end'/);
assert.match(script, /button\.draggable = true/);
assert.match(script, /function dropPalette\(/);
assert.match(script, /function renderRunUntil\(/);
assert.match(html, /\.run-until-board/);
assert.match(script, /until: '\$\{done\}'/);
assert.match(script, /done: false/);

function source(name, next) {
  return script.slice(script.indexOf(`    function ${name}(`), script.indexOf(`    function ${next}(`));
}
const dragContext = vm.createContext({ draggedType: 'tap', templates: { tap: {} } });
vm.runInContext(source('draggedCommand', 'acceptPaletteDrop'), dragContext);
assert.equal(dragContext.draggedCommand({}), 'tap');
dragContext.draggedType = null;
assert.equal(dragContext.draggedCommand({ dataTransfer: { getData: () => 'tap' } }), 'tap');
assert.equal(dragContext.draggedCommand({ dataTransfer: { getData: () => 'unknown' } }), null);

const untilContext = vm.createContext({});
vm.runInContext(source('readUntil', 'updateParameter'), untilContext);
assert.equal(untilContext.readUntil('${ready}'), '${ready}');
assert.equal(untilContext.readUntil('true'), true);
assert.equal(untilContext.readUntil('false'), false);
assert.throws(() => untilContext.readUntil('ready'));
console.log('Diagram editor structure, bridge hooks, command palette, and JavaScript syntax passed');
