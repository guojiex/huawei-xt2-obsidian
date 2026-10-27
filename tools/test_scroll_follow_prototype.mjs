import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../docs/prototype/index.html', import.meta.url), 'utf8');
const renderer = html.slice(html.indexOf('  function renderMarkdown('), html.indexOf('  function inline(s)'));
const follow = html.slice(html.indexOf('  /* 源码行 → 预览块'), html.indexOf('  function render() {'));
function sourceRanges(text) {
  const context = vm.createContext({ inline: s => s, esc: s => s });
  vm.runInContext(renderer, context);
  return [...context.renderMarkdown(text).matchAll(/data-source-start="(\d+)" data-source-end="(\d+)"/g)].map(m => [+m[1], +m[2]]);
}

test('source maps distinguish duplicate headings, wrapped paragraphs, lists, table and fenced blocks', () => {
  const text = ['# 同名', '', '段落第一行', '段落第二行', '', '# 同名', '- 项目', '  - 嵌套', '- [ ] 任务', '', '| 列 |', '| --- |', '| 值 |', '', '```js', 'code', '```', '$$ x $$', '```mermaid', 'graph LR', '```'].join('\n');
  assert.deepEqual(sourceRanges(text), [[0,1],[2,4],[5,6],[6,7],[7,8],[8,9],[10,13],[14,17],[17,18],[18,21]]);
  assert.deepEqual(sourceRanges('```\nunclosed\ncode'), [[0,3]]);
});

function fixture(savedPreference = null) {
  const events = {}, frames = new Map(), stored = new Map([['xt2-follow-editor', savedPreference]]);
  let frameId = 0, measurements = 0;
  function element(id) {
    return { clientWidth: 300, clientHeight: 200, scrollHeight: 1200, scrollTop: 0,
      addEventListener(type, fn) { events[id + ':' + type] = fn; },
      setAttribute(name, value) { this[name] = value; },
      getBoundingClientRect() { return { top: 0, height: 200 }; },
      querySelectorAll() { return []; } };
  }
  const ta = element('ta'), mdEl = element('md'), hl = element('hl'), button = element('button');
  const editorRows = Array.from({ length: 40 }, (_, line) => ({ getBoundingClientRect() { measurements++; return { top: 16 + line * 25 - hl.scrollTop }; } }));
  // 图片/代码高度与源码行比例不同，验证不是全文滚动百分比。
  const blocks = [{start:0,end:4,top:20,height:100},{start:4,end:8,top:140,height:500},{start:8,end:40,top:660,height:400}];
  hl.querySelectorAll = () => editorRows;
  mdEl.querySelectorAll = () => blocks.map(b => ({ dataset:{sourceStart:b.start,sourceEnd:b.end}, getBoundingClientRect() { measurements++; return {top:b.top-mdEl.scrollTop,height:b.height}; } }));
  const context = vm.createContext({ ta, mdEl, hl, current:'a', body:{getAttribute(){return 'note';}},
    document:{getElementById(){return button;}}, localStorage:{getItem(k){return stored.get(k);},setItem(k,v){stored.set(k,v);}},
    ResizeObserver: class { observe() {} disconnect() {} },
    getComputedStyle(el) { return {paddingTop:el===mdEl?'20px':'16px',lineHeight:'25px'}; },
    requestAnimationFrame(fn) { frames.set(++frameId,fn); return frameId; }, cancelAnimationFrame(id) { frames.delete(id); } });
  vm.runInContext(follow, context);
  return { context, ta, mdEl, hl, button, stored, frames,
    measureCount:()=>measurements,
    run(code) { vm.runInContext(code, context); },
    emit(id,type,key) { events[id+':'+type]({type,key}); },
    flush() { const pending=[...frames.values()]; frames.clear(); pending.forEach(fn=>fn()); },
    scroll(top) { ta.scrollTop=top; hl.scrollTop=top; vm.runInContext('schedulePreviewFollow()',context); this.flush(); } };
}

test('editor follows source block position, reuses geometry, and clamps both ends', () => {
  const f=fixture(); f.scroll(0); assert.equal(f.mdEl.scrollTop,0);
  const reads=f.measureCount(); f.scroll(150);
  assert.equal(f.mdEl.scrollTop,370); // 源码第 6 行 → 高块中部（140 + 250 - 20）。
  assert.equal(f.measureCount(),reads);
  f.scroll(1000); assert.equal(f.mdEl.scrollTop,1000);
  f.scroll(0); assert.equal(f.mdEl.scrollTop,0);
});

test('manual preview scrolling cancels pending follow and survives rerender/late image layout', () => {
  const f=fixture(); f.scroll(100);
  f.run('schedulePreviewFollow()'); f.emit('md','wheel'); assert.equal(f.frames.size,0);
  f.mdEl.scrollTop=700; f.run('invalidateFollowGeometry()'); f.flush(); assert.equal(f.mdEl.scrollTop,700);
  f.scroll(150); assert.equal(f.mdEl.scrollTop,700);
  f.emit('ta','wheel'); f.scroll(150); assert.equal(f.mdEl.scrollTop,370);
});

test('preference persists and re-enabling aligns immediately; hidden panes do not scroll', () => {
  const f=fixture('false'); f.scroll(150); assert.equal(f.mdEl.scrollTop,0);
  f.emit('button','click'); f.flush(); assert.equal(f.mdEl.scrollTop,370);
  assert.equal(f.stored.get('xt2-follow-editor'),'true');
  f.mdEl.clientWidth=0; f.run('invalidateFollowGeometry()'); f.flush();
  f.scroll(200); assert.equal(f.mdEl.scrollTop,370);
  f.mdEl.clientWidth=300; f.run('invalidateFollowGeometry()'); f.flush(); assert.equal(f.mdEl.scrollTop,640);
  f.run('schedulePreviewFollow()'); f.emit('button','click'); assert.equal(f.frames.size,0);
});

test('only last editor scroll in a frame applies; queued work reads current note geometry', () => {
  const f=fixture(); f.scroll(100);
  f.run('schedulePreviewFollow(); schedulePreviewFollow(); schedulePreviewFollow()'); assert.equal(f.frames.size,1);
  f.ta.scrollTop=150; f.hl.scrollTop=150;
  f.run("current='b'; invalidateFollowGeometry()"); f.flush(); assert.equal(f.mdEl.scrollTop,370);
});

test('blank source gaps use nearest block and empty documents have a valid origin', () => {
  const f=fixture();
  assert.equal(f.context.previewPositionForLine(0,[]),0);
  const blocks=[{start:0,end:1,top:0,height:20},{start:5,end:6,top:100,height:20}];
  assert.equal(f.context.previewPositionForLine(2,blocks),20);
  assert.equal(f.context.previewPositionForLine(4,blocks),100);
});
