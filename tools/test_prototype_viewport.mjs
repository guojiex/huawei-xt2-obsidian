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

test('single-screen overflow menu reuses original actions and closes on selection, outside click or Escape', () => {
  const nodes = new Map(), handlers = {}, actions = [];
  const get = id => {
    if (!nodes.has(id)) nodes.set(id, { open: false, handlers: {}, addEventListener(type, fn) { this.handlers[type] = fn; }, click() { actions.push(id); }, contains(target) { return target === this; } });
    return nodes.get(id);
  };
  const c = vm.createContext({ document: { getElementById: get, addEventListener(type, fn) { handlers[type] = fn; } } });
  const start = html.indexOf("  document.getElementById('toolbarMore').addEventListener");
  vm.runInContext(html.slice(start, html.indexOf("  document.getElementById('quickInput').addEventListener", start)), c);
  const more = get('toolbarMore');
  for (const id of ['shareNoteBtn', 'syncBtn', 'settingsBtn']) {
    more.open = true;
    more.handlers.click.call(more, {target:{closest(){return {getAttribute(){return id;}};}}});
    assert.equal(more.open, false);
  }
  assert.deepEqual(actions, ['shareNoteBtn', 'syncBtn', 'settingsBtn']);
  more.open = true; handlers.click({target:more}); assert.equal(more.open, true);
  handlers.click({target:{}}); assert.equal(more.open, false);
  more.open = true; handlers.keydown({key:'Escape'}); assert.equal(more.open, false);
});

test('only the rotated single-screen preset enables navigation split despite retaining the md width breakpoint', () => {
  const f = fixture(); f.run("applyViewport('sm', true)");
  assert.equal(f.c.applied, 'md'); assert.equal(f.attrs['data-single-landscape'], 'true');
  f.run("applyViewport('md', false)"); assert.equal(f.attrs['data-single-landscape'], 'false');
  f.run("applyViewport('md', true)"); assert.equal(f.attrs['data-single-landscape'], 'false');
  f.run("applyViewport('sm', false)"); assert.equal(f.attrs['data-single-landscape'], 'false');
});

test('single-screen note navigation pushes through layout state and the hide button closes it', () => {
  const f = fixture(); f.c.drawer = false; f.c.sideHidden = false;
  f.c.body.getAttribute = () => 'sm';
  f.run(html.match(/function toggleDrawer\(open\) \{[\s\S]*?\n  \}/)[0]);
  f.run(html.match(/function setSideHidden\(h\) \{[\s\S]*?\n  \}/)[0]);
  f.run('toggleDrawer()');
  assert.equal(f.attrs['data-note-nav'], 'open'); assert.equal(f.get('sidebar').inert, false);
  f.run('setSideHidden(true)');
  assert.equal(f.attrs['data-note-nav'], 'closed'); assert.equal(f.get('sidebar').inert, true);
  f.run('toggleDrawer(true); toggleDrawer(false)');
  assert.equal(f.attrs['data-note-nav'], 'closed');
  assert.equal(f.get('sidebar').style.position, undefined);
});
