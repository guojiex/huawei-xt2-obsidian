import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const html = fs.readFileSync(new URL('../docs/prototype/index.html', import.meta.url), 'utf8');
const code = html.split('/* VIEWPORT_BEGIN:')[1].split('/* VIEWPORT_END */')[0];
const source = code.slice(code.indexOf('var viewportPreset'));
function fixture() {
  const nodes = new Map(), attrs = {};
  const get = id => {
    if (!nodes.has(id)) nodes.set(id, { style: { setProperty(k,v) { this[k]=v; } }, setAttribute(k,v) { this[k]=v; }, textContent:'' });
    return nodes.get(id);
  };
  const c = vm.createContext({ document:{getElementById:get}, body:{setAttribute(k,v){attrs[k]=v;}}, applied:'', applyForm(f){c.applied=f;} });
  vm.runInContext(source,c);return {c,get,attrs,run:s=>vm.runInContext(s,c)};
}
for (const [preset, rotated, width, height, form] of [
  ['sm',false,380,780,'sm'], ['sm',true,780,380,'md'],
  ['md',false,709,860,'md'], ['md',true,860,709,'lg'],
  ['lg',false,1061,830,'lg'], ['lg',true,830,1061,'md']
]) test(`${preset} rotated=${rotated} derives ${width}x${height} and ${form}`,()=>{
  const f=fixture(); f.run(`applyViewport('${preset}',${rotated})`);
  assert.equal(f.c.applied,form);assert.equal(f.get('device').style['--viewport-width'],width+'px');
  assert.equal(f.get('device').style['--viewport-height'],height+'px');
  assert.equal(f.attrs['data-compact-height'],String(height<480));
});
test('rotation round trip preserves preset and does not modify conversation state',()=>{
  const f=fixture();f.c.conversation={draft:'先参考 A',refs:['a'],panels:{threads:false,files:true}};
  const before=JSON.stringify(f.c.conversation);f.run("applyViewport('sm',true);applyViewport('sm',false)");
  assert.equal(f.run('viewportPreset'),'sm');assert.equal(f.get('device').style['--viewport-height'],'780px');
  assert.equal(JSON.stringify(f.c.conversation),before);
});
test('URL stores preset plus rotation independently of effective breakpoint',()=>{
  assert.match(html,/var hash = 'f=' \+ viewportPreset \+ '&r='/);
  assert.match(html,/applyViewport\(f, params\.r === '1'\)/);
  assert.match(html,/if \(viewportRotated\) \{ return; \}/);
});
