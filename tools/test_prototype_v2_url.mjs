import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const html=fs.readFileSync(new URL('../docs/prototype/v2/index.html',import.meta.url),'utf8');
const code=html.match(/<script>([\s\S]*?)<\/script>/)[1];
const markupIds=new Set(Array.from(html.matchAll(/\bid="([^"]+)"/g),match=>match[1]));
test('save-success feedback stays hidden until the simulated save succeeds, then fades out',()=>{
 assert.match(html,/\.save-feedback\{position:absolute;left:var\(--s5\)/);
 assert.match(code,/scheduleSaveFeedback\(\).*setTimeout\(\(\)=>\{const feedback=saveFeedback\(\);feedback\.classList\.remove\('hidden'\);saveFeedbackHideTimer=setTimeout\(\(\)=>feedback\.classList\.add\('hidden'\),3500\);\},800\)/);
 assert.match(code,/event\.target===\$\('editor'\)\|\|event\.target===\$\('rightEditor'\)/);
});
function fixture(href='file:///repo/docs/prototype/v2/index.html',storage=new Map()){
 const nodes=new Map(),events={document:{},window:{}},pending=[];
 const listen=(area,key,fn)=>(events[area][key]??=[]).push(fn);
 const get=id=>{if(!nodes.has(id))nodes.set(id,{clientWidth:1200,clientHeight:300,scrollHeight:1000,scrollTop:0,innerHTML:'',value:'',textContent:'',dataset:{},attrs:{},style:{setProperty(k,v){this[k]=v},removeProperty(k){delete this[k]}},classList:{values:new Set(),contains(k){return this.values.has(k)},add(...keys){keys.forEach(k=>this.values.add(k))},remove(...keys){keys.forEach(k=>this.values.delete(k))},toggle(k,on=!this.values.has(k)){on?this.values.add(k):this.values.delete(k);return on}},setAttribute(k,v){this.attrs[k]=v},querySelectorAll(){return[]},listeners:{},addEventListener(k,fn){(this.listeners[k]??=[]).push(fn)},dispatch(type,event){for(const fn of this.listeners[type]||[])fn(event)},getBoundingClientRect(){return this.rect||(/^(formatBtn|rightFormatBtn)$/.test(id)?{left:100,right:148,top:700,bottom:748,width:48,height:48}:id==='formatDialog'?{left:0,right:360,top:0,bottom:400,width:360,height:400}:{left:0,right:1200,top:0,bottom:800,width:1200,height:800})},focus(){this.focused=true},select(){this.selected=true},contains(){return false},removeAttribute(k){delete this.attrs[k];if(k==='src')this.src=''},setSelectionRange(a,b){this.selectionStart=a;this.selectionEnd=b},setRangeText(text,start,end){this.value=this.value.slice(0,start)+text+this.value.slice(end);this.selectionStart=start;this.selectionEnd=start+text.length},show(){this.open=true},showModal(){this.open=true},close(){this.open=false}});return nodes.get(id);};
 let location=new URL(href),index=0;const history=[location.href];
 const win={innerWidth:1320,innerHeight:1000,get location(){return location},history:{pushState(_,__,href){location=new URL(href);history.splice(++index);history.push(location.href)},replaceState(_,__,href){location=new URL(href);history[index]=location.href}},addEventListener(k,fn){listen('window',k,fn)}};
 const context=vm.createContext({URL,URLSearchParams,window:win,document:{getElementById:get,querySelectorAll(){return[]},body:{dataset:{}},addEventListener(k,fn){listen('document',k,fn)}},queueMicrotask:fn=>pending.push(fn),setTimeout:fn=>{pending.push(fn);return 1},clearTimeout(){},ResizeObserver:class{observe(){}},getComputedStyle:()=>({getPropertyValue:k=>k==='--pane-min'?'240px':k==='--format-width'?'360px':k==='--s2'?'8px':'16px'}),localStorage:{getItem:k=>storage.get(k)||null,setItem:(k,v)=>storage.set(k,v),removeItem:k=>storage.delete(k)}});
 const run=s=>vm.runInContext(s,context);run(code);
 return {get,run,href:()=>location.href,flush(){while(pending.length)pending.shift()()},event(area,type,event={}){for(const fn of events[area][type]||[])fn(event)},back(){assert(index>0);location=new URL(history[--index]);for(const fn of events.window.popstate||[])fn({})},forward(){assert(index<history.length-1);location=new URL(history[++index]);for(const fn of events.window.popstate||[])fn({})},history};
}
test('link round trip restores panes, geometry, theme, sidebar, widths and settings history',()=>{
 const f=fixture();f.run("switchVault('projects');openInPane('projects_inbox','left');openInPane('projects_todo','right');setEditing(true,false);setRightEditing(false,false);setViewport('phone');viewportRotated=true;applyViewportGeometry();document.body.dataset.theme='dark';widths={nav:.4,content:.6};setSidebarView('chapters');openSettings();chooseSettings('about',false);$('openHistory').onclick();syncUrl('push')");
 const g=fixture(f.href());assert.equal(g.run('activeVault'),'projects');assert.equal(g.run('current'),'projects_inbox');assert.equal(g.run('reference'),'projects_todo');assert.equal(g.run('editing'),true);assert.equal(g.run('rightEditing'),false);assert.equal(g.run('viewportPreset'),'phone');assert(g.run('viewportRotated'));assert.equal(g.run('document.body.dataset.theme'),'dark');assert.equal(g.run('activePane'),'right');assert.equal(g.run('sidebarView'),'chapters');assert.equal(g.run('widths.nav'),.4);assert.equal(g.run('widths.content'),.6);assert(g.run('settingsOpen&&historyOpen'));assert.equal(g.run('settingsCategory'),'about');
});
test('user events update the address; back and forward restore navigation without overwriting edits',()=>{
 const f=fixture();f.get('editor').value='private unsaved content';f.get('editTab').onclick();f.get('editor').oninput();const original=f.run('current');f.run("selectNote('reading_reading_journal')");f.event('document','click');f.flush();assert.equal(new URL(f.href()).searchParams.get('left'),'reading_reading_journal');f.back();assert.equal(f.run('current'),original);assert.equal(f.run('note(current).text'),'private unsaved content');f.forward();assert.equal(f.run('current'),'reading_reading_journal');assert.equal(f.history.length,2);
});
test('only allowlisted UI metadata appears in URL, never drafts or file content',()=>{
 const f=fixture();f.run("setEditing(true,false);$('editor').value='SECRET_NOTE_BODY';$('editor').oninput();$('feedbackSteps').value='SECRET_FEEDBACK';$('feedbackSteps').oninput();syncUrl('push')");assert(!decodeURIComponent(f.href()).includes('SECRET'));const g=fixture(f.href());assert(!g.run('note(current).text').includes('SECRET_NOTE_BODY'));
});
test('invalid or cross-vault note ids and malformed configuration fall back safely',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&vault=projects&left=welcome&right=../../x&preset=bogus&theme=%3Cscript%3E&nw=Infinity&cw=-3&collapsed=oops&panel=fileaction&file=missing');assert.equal(f.run('activeVault'),'projects');assert.equal(f.run('current'),'projects_inbox');assert.equal(f.run('reference'),'projects_todo');assert.equal(f.run('viewportPreset'),'wide');assert.equal(f.run('document.body.dataset.theme'),'light');assert.equal(f.run('widths.nav'),1/3);assert(!f.get('fileActionDialog').open);
});
test('share format and page, format panel, and non-destructive file action can be reopened from links',()=>{
 const f=fixture();f.get('shareBtn').onclick();f.get('shareScope').value='vault';f.get('shareScope').onchange();f.get('shareFile').onclick();f.run('syncUrl()');const g=fixture(f.href());assert(g.get('shareDialog').open);assert.equal(g.get('shareScope').value,'vault');assert.equal(g.run('shareStage'),'file');assert(g.get('sharePreview').innerHTML.includes('.zip'));
 const h=fixture();h.run("setEditing(true,false);openFormat('left');syncUrl()");assert(fixture(h.href()).get('formatDialog').open);
 const i=fixture();i.run("openFileAction('rename','reading_stream');syncUrl()");const j=fixture(i.href());assert(j.get('fileActionDialog').open);assert.equal(j.run("note('reading_stream').title"),'基础排版');
});
test('Git share design state exposes scope-specific remote link previews without a fake URL',()=>{
 const f=fixture();f.get('gitShareDemo').checked=true;f.get('gitShareDemo').onchange();f.get('shareBtn').onclick();
 for(const [scope,label]of [['note','远端笔记网页链接'],['folder','远端文件夹网页链接'],['vault','仓库首页链接']]){
  f.get('shareScope').value=scope;f.get('shareScope').onchange();assert(!f.get('shareRemoteLink').classList.contains('hidden'));assert.equal(f.get('shareRemoteLinkLabel').textContent,label);
  if(scope==='note')assert(!f.get('shareImage').classList.contains('hidden'));else assert(f.get('shareImage').classList.contains('hidden'));
  f.get('shareRemoteLink').onclick();assert.equal(f.run('shareStage'),'link');assert.match(f.get('sharePreview').innerHTML,/私有仓库.*访问权限/);assert.match(f.get('sharePreview').innerHTML,/未推送的本地修改不会出现在链接中/);assert(!f.get('sharePreview').innerHTML.includes('https://'));
  f.get('shareBack').onclick();
 }
 f.run('syncUrl()');const g=fixture(f.href());assert(g.get('shareDialog').open);assert.equal(g.run('gitShareDemo'),true);assert.equal(g.run('shareStage'),'formats');assert(!g.get('shareRemoteLink').classList.contains('hidden'));
 const h=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&gitShareDemo=1&panel=share&scope=vault&stage=link');assert.equal(h.run('shareStage'),'link');assert(h.get('sharePreview').innerHTML.includes('仓库首页链接'));assert.equal(new URL(h.href()).searchParams.get('gitShareDemo'),'1');
 g.get('gitShareDemo').checked=false;g.get('gitShareDemo').onchange();assert(g.get('shareRemoteLink').classList.contains('hidden'));assert.equal(g.run('shareStage'),'formats');
});
test('URL overrides other browser width preferences and keeps collapsed folders and scroll position',()=>{
 const f=fixture();f.run("folderState['reading/10_写作']=false;$('writingScroll').scrollTop=120;syncUrl()");const storage=new Map([['xt2-prototype-v2-widths',JSON.stringify({nav:.7,content:.2})]]);const g=fixture(f.href(),storage);assert.equal(g.run('widths.nav'),.3333);assert.equal(g.run("folderState['reading/10_写作']"),false);assert.equal(g.get('writingScroll').scrollTop,120);
});

test('reported phone link renders relative sample images when switched from edit to preview',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&preset=phone&rotate=0&theme=light&vault=reading&left=reading_stream&right=reading_reading_journal&active=left&lm=edit&rm=preview&dual=1&focus=0&side=files&nav=0&nw=0.2582&cw=0.5000&view=notes&settings=general&detail=0&history=0&panel=none&scroll_editor=1135');
 const source=f.get('editor').value;assert(source.includes('![长图排版示例](../50_Assets/长图排版示例.svg)'));assert(f.run('editing'));f.get('previewTab').onclick();assert(!f.run('editing'));assert.match(f.get('article').innerHTML,/<img[^>]*src="data:image\/svg\+xml;base64,[^"]+"[^>]*alt="长图排版示例">/);assert(!f.get('article').innerHTML.includes('![长图排版示例]'));assert.equal(f.get('editor').value,source);
});
test('right pane and share preview resolve images against their own note folder',()=>{
 const f=fixture();f.run("switchVault('local');openInPane('welcome','left');openInPane('stream','right')");assert.match(f.get('reference').innerHTML,/<img[^>]+alt="长图排版示例">/);f.get('shareBtn').onclick();f.get('shareImage').onclick();assert.match(f.get('sharePreview').innerHTML,/<img[^>]+alt="长图排版示例">/);
 f.run("note(reference).folder='20_样式/子目录';renderReference()");assert(!f.get('reference').innerHTML.includes('<img'));assert(f.get('reference').innerHTML.includes('图片未找到'));assert(!f.get('article').innerHTML.includes('长图排版示例'));
});
test('asset lookup handles encoded paths and rejects root escape without reading arbitrary files',()=>{
 const f=fixture();assert.match(f.run("resolvePreviewImage('../50_Assets/%E9%95%BF%E5%9B%BE%E6%8E%92%E7%89%88%E7%A4%BA%E4%BE%8B.svg',note(current))"),/^data:image\/svg\+xml;base64,/);assert.equal(f.run("resolvePreviewImage('../../50_Assets/长图排版示例.svg',note(current))"),'');assert.equal(f.run("resolvePreviewImage('file:///etc/passwd',note(current))"),'');assert.equal(f.run("resolvePreviewImage('%invalid',note(current))"),'');f.run("imageAssets.set('attachments/image-1.png','blob:local')");assert.equal(f.run("resolvePreviewImage('attachments/image-1.png',note(current))"),'blob:local');
});

test('phone navigation pushes the retained workspace and reverses without losing editing state',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&preset=phone&vault=reading&left=reading_stream&right=reading_reading_journal&active=left&lm=edit&nav=0');
 const editor=f.get('editor'),workspace=f.get('noteWorkspace');editor.value='动画中保留的编辑内容';editor.oninput();editor.setSelectionRange(4,7);editor.scrollTop=120;
 assert.equal(f.get('navSidebar').inert,true);assert.equal(workspace.inert,false);
 for(let i=0;i<3;i++){f.get('menu').onclick();assert.equal(f.get('navSidebar').inert,false);assert.equal(workspace.inert,false);assert.equal(f.get('notePanes').inert,true);assert.equal(f.get('menu').attrs['aria-expanded'],'true');f.get('closeNav').onclick();assert.equal(f.get('navSidebar').inert,true);assert.equal(workspace.inert,false);}
 assert.equal(f.get('editor'),editor);assert.equal(f.get('noteWorkspace'),workspace);assert.equal(editor.value,'动画中保留的编辑内容');assert.equal(editor.selectionStart,4);assert.equal(editor.selectionEnd,7);assert.equal(editor.scrollTop,120);
 f.get('menu').onclick();f.run("selectNote('reading_reading_journal')");assert(!f.get('window').classList.contains('nav-open'));assert.equal(workspace.inert,false);
});
test('wide sidebar toggles and rotation keep active note and hidden navigation inaccessible',()=>{
 const f=fixture();const before=f.run('current');f.get('menu').onclick();assert.equal(f.get('navSidebar').inert,true);f.get('menu').onclick();assert.equal(f.get('navSidebar').inert,false);f.run("setViewport('phone')");f.get('menu').onclick();f.get('rotateViewport').onclick();assert.equal(f.run('current'),before);assert.equal(f.get('noteWorkspace').inert,false);assert.equal(f.get('navSidebar').inert,f.get('window').classList.contains('nav-hidden'));
});

test('entering the two-pane width collapses navigation when both panes are enabled',()=>{
 const f=fixture();assert.equal(f.run('viewport'),'wide');assert.equal(f.get('window').classList.contains('nav-hidden'),false);f.get('rotateViewport').onclick();assert.equal(f.run('viewport'),'double');assert.equal(f.get('window').classList.contains('nav-hidden'),true);assert.equal(f.run('referenceShown()'),true);f.get('rotateViewport').onclick();assert.equal(f.run('viewport'),'wide');f.get('menu').onclick();assert.equal(f.get('window').classList.contains('nav-hidden'),false);f.get('double').onclick();assert.equal(f.run('viewport'),'double');assert.equal(f.get('window').classList.contains('nav-hidden'),true);assert.equal(f.run('referenceShown()'),true);
});

test('double layout defaults to two panes and honors an explicit navigation URL state',()=>{
 const closed=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&preset=double&dual=1');assert.equal(closed.run('viewport'),'double');assert.equal(closed.get('window').classList.contains('nav-hidden'),true);assert.equal(closed.run('referenceShown()'),true);const open=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&preset=double&dual=1&nav=1');assert.equal(open.get('window').classList.contains('nav-hidden'),false);assert.equal(open.run('referenceShown()'),false);
});

test('frontmatter stays editable but is hidden in both previews and share image',()=>{
 const f=fixture();f.run("openInPane('reading_reading_journal','left');openInPane('reading_reading_journal','right')");const source=f.get('editor').value;assert(source.startsWith('---\n'));for(const id of ['article','reference']){assert(!f.get(id).innerHTML.includes('title:'));assert(!f.get(id).innerHTML.includes('tags:'));assert(f.get(id).innerHTML.includes('读书对话练习</h1>'));}f.get('shareBtn').onclick();f.get('shareImage').onclick();assert(!f.get('sharePreview').innerHTML.includes('title:'));assert.equal(f.get('editor').value,source);const headings=JSON.parse(f.run('JSON.stringify(headingsFor(note(current).text))'));assert.equal(headings[0].offset,source.indexOf('# 读书对话练习'));assert.equal(headings[1].offset,source.indexOf('## 本轮阅读问题'));
});
test('frontmatter handling preserves source offsets and does not strip body or incomplete blocks',()=>{
 const f=fixture();const source='\uFEFF---\r\ntitle: sample\r\n# metadata comment\r\n...\r\n# Heading\r\n\r\n---\r\nBody';f.run('globalThis.fmSource='+JSON.stringify(source));assert.equal(f.run('headingsFor(fmSource).length'),1);assert.equal(f.run('headingsFor(fmSource)[0].offset'),source.indexOf('# Heading'));assert.match(f.run('renderMarkdown(fmSource,true)'),/<hr data-source-start="\d+" data-source-end="\d+">/);assert(!f.run('renderMarkdown(fmSource,true)').includes('metadata comment'));assert(f.run("renderMarkdown('---\\ntitle: unfinished',false)").includes('unfinished'));assert(f.run("renderMarkdown('正文\\n---\\n后文',false)").includes('后文'));assert.equal(f.run("markdownBody('---\\n---\\n# Title').text"),'# Title');
});

test('frontmatter tags render as chips without exposing raw YAML or changing source',()=>{
 const f=fixture();f.run("openInPane('reading_reading_journal','left');openInPane('reading_reading_journal','right')");const source=f.get('editor').value;for(const id of ['article','reference']){assert(f.get(id).innerHTML.includes('aria-label="笔记标签"'));assert(!f.get(id).innerHTML.includes('note-tags-label'));assert(f.get(id).innerHTML.includes('>#样例</span>'));assert(f.get(id).innerHTML.includes('>#阅读</span>'));assert(!f.get(id).innerHTML.includes('tags:'));assert(!f.get(id).innerHTML.includes('title:'));}assert.equal(f.get('editor').value,source);const tags=f.run('frontmatterTags('+JSON.stringify('---\ntags: ["Tag", "nested/tag", "tag", "1984", "y1984"]\n---\n# Note')+')');assert.deepEqual(Array.from(tags),['Tag','nested/tag','y1984']);
});
test('inline tags render outside code and links, keeping nested/unicode tags and numeric text correct',()=>{
 const f=fixture();const rendered=f.run('renderMarkdown('+JSON.stringify('# Heading\n\n#样例 #写作/练习 #1984 #y1984\n\n`#code` [link](https://example.com/#fragment)\n\n```\n#fenced\n```')+',false)');assert(rendered.includes('>#样例</span>'));assert(rendered.includes('>#写作/练习</span>'));assert(rendered.includes('>#y1984</span>'));assert(!rendered.includes('>#1984</span>'));assert(rendered.includes('<code>#code</code>'));assert.match(rendered,/<pre data-source-start="\d+" data-source-end="\d+"><code>#fenced<\/code><\/pre>/);assert(!rendered.includes('>#fragment</span>'));
});

test('phone hides redundant pane switching for same note and preserves current edit/preview controls',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&preset=phone&vault=reading&left=reading_stream&right=reading_stream&active=right&lm=edit&rm=preview');assert(f.get('switchPane').classList.contains('hidden'));f.get('switchPane').onclick();assert.equal(f.run('activePane'),'right');f.get('rightEditTab').onclick();assert(f.run('rightEditing'));f.get('rightPreviewTab').onclick();assert(!f.run('rightEditing'));assert(f.get('switchPane').classList.contains('hidden'));
});
test('phone offers document switching only for different notes and labels the destination',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&preset=phone&vault=reading&left=reading_stream&right=reading_reading_journal&active=left&lm=edit&rm=preview');assert(!f.get('switchPane').classList.contains('hidden'));assert(f.get('switchPane').attrs['aria-label'].includes('读书对话练习'));f.get('switchPane').onclick();assert.equal(f.run('activePane'),'right');assert(f.get('switchPane').attrs['aria-label'].includes('基础排版'));assert(f.run('editing'));assert(!f.run('rightEditing'));f.run("openInPane('reading_stream','right')");assert(f.get('switchPane').classList.contains('hidden'));f.run("openInPane('reading_reading_journal','right');setViewport('wide')");assert(f.get('switchPane').classList.contains('hidden'));f.run("setViewport('phone')");assert(!f.get('switchPane').classList.contains('hidden'));f.run("reference='';updatePaneChrome()");assert(f.get('switchPane').classList.contains('hidden'));
});

test('single-screen overflow contains no focus or dual-layout actions, including restored legacy links',()=>{
 const menu=html.match(/<details id="mobileMore"[\s\S]*?<\/details>/)[0];assert(!menu.includes('mobileFocus'));assert(!menu.includes('mobileDual'));assert(menu.includes('mobileShare'));assert(menu.includes('mobileSettings'));assert(menu.includes('switchPane'));const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&preset=phone&vault=reading&left=reading_stream&right=reading_reading_journal&active=left&focus=1');assert.equal(f.run('focused'),false);assert(!f.get('window').classList.contains('focus'));const before=f.run('referenceEnabled');f.run('toggleFocus();toggleReference();previewSameNote()');assert.equal(f.run('focused'),false);assert.equal(f.run('referenceEnabled'),before);
});
test('all six preset/rotation combinations use the effective layout for navigation actions',()=>{
 for(const [preset,rotated,isPhone]of [['phone',false,true],['phone',true,false],['double',false,false],['double',true,false],['wide',false,false],['wide',true,false]]){const f=fixture();f.run('viewportRotated='+rotated+';setViewport('+JSON.stringify(preset)+')');assert.equal(f.run('phone'),isPhone);if(isPhone){assert(!f.run('validReferenceDrag()'));assert(!f.get('leftMore').open);assert(!f.get('rightMore').open);}else{f.run('toggleFocus()');assert(f.run('focused'));f.run('toggleFocus()');assert(!f.run('focused'));}}
 const f=fixture();f.run("setViewport('wide');toggleFocus();$('mobileMore').open=true;setViewport('phone')");assert.equal(f.run('focused'),false);assert(!f.get('window').classList.contains('focus'));f.get('rotateViewport').onclick();assert(!f.run('phone'));assert.equal(f.get('mobileMore').open,false);
});

test('phone hamburger stays interactive while the pushed note body is inert and can close navigation',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&preset=phone&vault=reading&left=reading_stream&right=reading_reading_journal&nav=0');f.get('menu').onclick();assert(f.get('window').classList.contains('nav-open'));assert.equal(f.get('noteWorkspace').inert,false);assert.equal(f.get('notePanes').inert,true);assert.equal(f.get('noteFooter').inert,true);assert.equal(f.get('mobileMore').inert,true);assert.notEqual(f.get('menu').inert,true);f.get('menu').onclick();assert(!f.get('window').classList.contains('nav-open'));assert.equal(f.get('notePanes').inert,false);assert.equal(f.get('noteFooter').inert,false);assert.equal(f.get('mobileMore').inert,false);assert.equal(f.get('navSidebar').inert,true);
});

test('hamburger exits focus and reveals navigation',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&preset=wide&focus=1&nav=0');
 assert(f.run('focused'));assert(f.get('window').classList.contains('focus'));
 f.get('menu').onclick();
 assert(!f.run('focused'));assert(!f.get('window').classList.contains('focus'));assert(!f.get('window').classList.contains('nav-hidden'));
});

test('double-screen focus hamburger aligns navigation with the visible left pane',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&preset=double&vault=reading&focus=1&nav=0&side=chapters&active=right&left=reading_stream&right=reading_reading_journal');
 assert(f.run('focused'));assert.equal(f.run('activePane'),'right');
 f.get('menu').onclick();
 assert(!f.run('focused'));assert(!f.get('window').classList.contains('nav-hidden'));
 assert.equal(f.run('activePane'),'left');assert.equal(f.run('activeNoteId()'),'reading_stream');
});

test('trash is a collapsed bottom folder; delete updates entries without auto-expanding and restore works',()=>{
 const f=fixture();assert.equal(f.get('trashFolder').open,false);assert(f.get('trashList').innerHTML.includes('回收站为空'));f.run("deleteFile('reading_stream')");assert.equal(f.get('trashFolder').open,false);assert(f.get('trashList').innerHTML.includes('基础排版'));assert.equal(f.get('trashCount').textContent,'1');f.get('openTrash').onkeydown({key:'ArrowRight',preventDefault(){}});assert.equal(f.get('trashFolder').open,true);assert(!f.get('trashDialog').open);f.run("trashFolderState[activeVault]=true;restoreFile('reading_stream')");assert(f.get('trashList').innerHTML.includes('回收站为空'));assert.equal(f.get('trashCount').textContent,'');assert.equal(f.get('trashFolder').open,false);f.get('openTrash').onkeydown({key:'ArrowLeft',preventDefault(){}});assert.equal(f.get('trashFolder').open,false);
});

test('trash entry uses a trash icon and only appears for a nonempty current-vault trash',()=>{
 const f=fixture();assert(f.get('trashFolder').classList.contains('hidden'));f.run("deleteFile('reading_stream')");assert(!f.get('trashFolder').classList.contains('hidden'));assert.equal(f.get('trashFolder').open,false);assert(f.get('openTrash').attrs['aria-label'].includes('1'));f.run("switchVault('projects')");assert(f.get('trashFolder').classList.contains('hidden'));f.run("switchVault('reading')");assert(!f.get('trashFolder').classList.contains('hidden'));f.run("trashFolderState[activeVault]=true;restoreFile('reading_stream')");assert(f.get('trashFolder').classList.contains('hidden'));assert.equal(f.get('trashFolder').open,false);const entry=html.match(/<details id="trashFolder"[\s\S]*?<\/details>/)[0];assert(entry.includes('M4 7h16M9 7V4'));
});

test('preview scaling is pane-local, hides reset at 100 and leaves source/editor unchanged',()=>{
 const f=fixture();const source=f.get('editor').value;f.run("setEditing(false,false);setRightEditing(false,false);setPreviewZoom('left',125)");assert.equal(f.get('article').style['--preview-scale'],1.25);assert.equal(f.get('reference').style['--preview-scale'],1);assert(!f.get('leftZoomReset').classList.contains('hidden'));assert(f.get('rightZoomReset').classList.contains('hidden'));assert.equal(f.get('editor').style['--preview-scale'],undefined);assert.equal(f.get('editor').value,source);f.get('leftZoomReset').onclick();assert.equal(f.run('previewZoom.left'),100);assert(f.get('leftZoomReset').classList.contains('hidden'));f.run('setEditing(true,false)');assert(f.get('leftZoomControls').classList.contains('hidden'));f.run('setEditing(false,false)');assert(!f.get('leftZoomControls').classList.contains('hidden'));
});
test('zoom list and URL restore independent percentages and reject malformed values',()=>{
 const f=fixture();f.get('leftZoom').value='150';f.get('leftZoom').onchange();f.run("setPreviewZoom('right',83);syncUrl()");const g=fixture(f.href());assert.equal(g.run('previewZoom.left'),150);assert.equal(g.run('previewZoom.right'),83);assert(g.get('rightZoom').innerHTML.includes('value="83"'));for(const [value,want]of [['NaN',100],['Infinity',100],['',100],['-1',50],['999',200]]){const h=fixture('file:///repo/index.html?ui=2&lz='+value);assert.equal(h.run('previewZoom.left'),want);}
});
test('two-finger pinch scales only preview and cancellation stops further changes',()=>{
 const f=fixture();f.run('setEditing(false,false)');const scroll=f.get('writingScroll');let prevented=0;const event=d=>({touches:[{clientX:0,clientY:50},{clientX:d,clientY:50}],preventDefault(){prevented++}});scroll.dispatch('touchstart',event(100));scroll.dispatch('touchmove',event(150));assert.equal(f.run('previewZoom.left'),150);assert.equal(f.run('previewZoom.right'),100);assert.equal(prevented,2);scroll.dispatch('touchcancel',{});scroll.dispatch('touchmove',event(200));assert.equal(f.run('previewZoom.left'),150);scroll.dispatch('touchstart',event(100));scroll.dispatch('touchmove',event(1000));assert.equal(f.run('previewZoom.left'),200);scroll.dispatch('touchend',{});f.run('setEditing(true,false)');scroll.dispatch('touchstart',event(100));scroll.dispatch('touchmove',event(50));assert.equal(f.run('previewZoom.left'),200);
});
test('trackpad pinch supports preview zoom but ordinary wheel and editor remain unaffected',()=>{
 const f=fixture();f.run('setRightEditing(false,false)');const scroll=f.get('rightScroll');let prevented=0;const e={ctrlKey:false,deltaY:-10,clientY:80,preventDefault(){prevented++}};scroll.dispatch('wheel',e);assert.equal(f.run('previewZoom.right'),100);scroll.dispatch('wheel',{...e,ctrlKey:true});assert(f.run('previewZoom.right')>100);assert.equal(prevented,1);f.run('setRightEditing(true,false)');const before=f.run('previewZoom.right');scroll.dispatch('wheel',{...e,ctrlKey:true});assert.equal(f.run('previewZoom.right'),before);assert.equal(prevented,1);
});

test('design header switch previews filled and empty trash without changing notes',()=>{
 const f=fixture();const before=f.run('JSON.stringify(notes)');f.get('trashDemo').checked=true;f.get('trashDemo').onchange();assert(!f.get('trashFolder').classList.contains('hidden'));assert.equal(f.get('trashFolder').open,false);assert.equal(f.get('trashCount').textContent,'1');assert(f.get('trashList').innerHTML.includes('已删除的笔记示例'));f.run("syncUrl()");const g=fixture(f.href());assert.equal(g.get('trashDemo').checked,true);assert(!g.get('trashFolder').classList.contains('hidden'));f.get('trashDemo').checked=false;f.get('trashDemo').onchange();assert(f.get('trashFolder').classList.contains('hidden'));assert.equal(f.run('JSON.stringify(notes)'),before);f.run("deleteFile('reading_stream')");assert(f.get('trashDemo').checked);assert(f.get('trashList').innerHTML.includes('基础排版'));f.get('trashDemo').checked=false;f.get('trashDemo').onchange();assert(f.get('trashFolder').classList.contains('hidden'));assert.equal(f.run("notes.find(n=>n.id==='reading_stream').deleted"),true);
});

test('trash restore uses an icon button with accessible note name and tooltip',()=>{
 const f=fixture();f.get('trashDemo').checked=true;f.get('trashDemo').onchange();for(const id of ['trashList','trashItems']){const button=f.get(id).innerHTML.match(/<button[^>]*data-restore="demo-trash"[\s\S]*?<\/button>/)[0];assert(button.includes('class="icon"'));assert(button.includes('title="恢复到原位置：阅读笔记 / 10_写作"'));assert(button.includes('aria-label="恢复 已删除的笔记示例 到 阅读笔记 / 10_写作"'));assert(button.includes('<svg'));assert(!button.includes('>恢复<'));}f.run("restoreFile('demo-trash')");assert(f.get('trashFolder').classList.contains('hidden'));
});

test('trash shows original location and restores the same note there without overwriting conflicts',()=>{
 const f=fixture();const before=f.run("JSON.stringify(notes.find(n=>n.id==='reading_stream'))");f.run("deleteFile('reading_stream')");assert(f.get('trashList').innerHTML.includes('原位置：阅读笔记 / 10_写作'));f.run("restoreFile('reading_stream')");assert.equal(f.run("JSON.stringify(notes.find(n=>n.id==='reading_stream'))"),before);f.run("deleteFile('reading_stream');notes.push({...note('reading_stream'),id:'conflict',deleted:false});restoreFile('reading_stream')");assert(f.run("note('reading_stream').deleted"));assert.equal(f.run("notes.find(n=>n.id==='conflict').deleted"),false);
});

test('same-note panes hide redundant other-pane preview but keep the backlinks menu',()=>{
 const f=fixture();f.run("setViewport('wide');openInPane('reading_stream','left');openInPane('reading_reading_journal','right')");for(const id of ['samePreview','rightSamePreview','leftMore','rightMore'])assert(!f.get(id).classList.contains('hidden'));f.get('leftMore').open=true;f.get('samePreview').onclick();assert.equal(f.run('current'),f.run('reference'));for(const id of ['samePreview','rightSamePreview'])assert(f.get(id).classList.contains('hidden'));for(const id of ['leftMore','rightMore'])assert(!f.get(id).classList.contains('hidden'));assert.equal(f.get('leftMore').open,false);assert.equal(f.get('leftBacklinks').textContent,'查看反链');f.run('setEditing(true,false);setRightEditing(true,false);previewSameNote()');assert(f.run('editing&&rightEditing'));f.run("openInPane('reading_reading_journal','right')");assert(!f.get('leftMore').classList.contains('hidden'));assert(!f.get('rightMore').classList.contains('hidden'));f.run("syncUrl()");const g=fixture(f.href());assert(!g.get('samePreview').classList.contains('hidden'));f.run("openInPane(current,'right');syncUrl()");const h=fixture(f.href());assert(h.get('samePreview').classList.contains('hidden'));assert(h.get('rightSamePreview').classList.contains('hidden'));assert(!h.get('leftMore').classList.contains('hidden'));assert(!h.get('rightMore').classList.contains('hidden'));
});

test('pane headers omit note picker; file click follows active pane and drag targets a pane',()=>{
 assert(!html.includes('id="chooseLeft"'));assert(!html.includes('id="chooseReference"'));assert(!code.includes('choosePaneNote'));const f=fixture();f.run("setViewport('wide')");const left=f.run('current');f.get('referencePane').dispatch('pointerdown',{});f.run("selectNote('reading_reading_journal')");assert.equal(f.run('reference'),'reading_reading_journal');assert.equal(f.run('current'),left);f.get('leftPane').dispatch('focusin',{});f.run("selectNote('reading_reading_journal')");assert.equal(f.run('current'),'reading_reading_journal');f.run("draggedReference='reading_stream'");let prevented=false;f.get('referencePane').dispatch('drop',{preventDefault(){prevented=true}});assert(prevented);assert.equal(f.run('reference'),'reading_stream');assert.equal(f.run('current'),'reading_reading_journal');assert.equal(f.run('activePane'),'right');
});

function formatGeometry(f,pane='left',anchor={left:320,top:660,width:48,height:48},bounds={left:300,top:100,width:240,height:700}){
 const rect=r=>({...r,right:r.left+r.width,bottom:r.top+r.height});f.get(pane==='left'?'leftPane':'referencePane').rect=rect(bounds);f.get(pane==='left'?'formatBtn':'rightFormatBtn').rect=rect(anchor);f.get('formatDialog').scrollHeight=400;f.get('formatDialog').rect=rect({left:0,top:0,width:224,height:400});
}
test('Aa panel anchors within its source pane, flips below and constrains height',()=>{
 const f=fixture();f.run("setEditing(true,false)");formatGeometry(f);f.run("openFormat('left')");const panel=f.get('formatDialog');assert(panel.open);assert.equal(panel.style.width,'224px');assert.equal(panel.style.left,'308px');assert.equal(panel.style.top,'252px');assert.equal(panel.dataset.placement,'above');assert.equal(f.get('formatBtn').attrs['aria-expanded'],'true');formatGeometry(f,'left',{left:320,top:120,width:48,height:48});f.run('positionFormatPanel()');assert.equal(panel.dataset.placement,'below');assert.equal(panel.style.top,'176px');formatGeometry(f,'left',{left:320,top:220,width:48,height:48},{left:300,top:100,width:240,height:300});f.run('positionFormatPanel()');assert.equal(panel.style.maxHeight,'116px');assert.equal(panel.style.top,'276px');
});
test('open panel follows moving anchor on animation frames and viewport resize',()=>{
 const f=fixture();f.run("window.requestAnimationFrame=fn=>{globalThis.nextFormatFrame=fn;return 1};window.cancelAnimationFrame=()=>{nextFormatFrame=null};setRightEditing(true,false)");formatGeometry(f,'right');f.run("openFormat('right')");const panel=f.get('formatDialog');assert.equal(panel.style.left,'308px');formatGeometry(f,'right',{left:620,top:560,width:48,height:48},{left:600,top:100,width:300,height:700});f.run('nextFormatFrame()');assert.equal(panel.style.left,'608px');assert.equal(panel.style.width,'284px');assert.equal(panel.style.top,'152px');f.run('window.visualViewport={offsetLeft:0,offsetTop:0,width:1320,height:600}');formatGeometry(f,'right',{left:620,top:500,width:48,height:48},{left:600,top:100,width:300,height:700});f.event('window','resize');assert.equal(panel.style.top,'108px');f.run('closeFormat()');assert.equal(f.run('nextFormatFrame'),null);assert.equal(f.get('rightFormatBtn').attrs['aria-expanded'],'false');
});
test('format dismissal retains original selection and source, outside click does not steal focus',()=>{
 const f=fixture();f.run("setEditing(true,false);$('editor').setSelectionRange(2,7);openFormat('left')");f.event('document','keydown',{key:'Escape',preventDefault(){}});assert(!f.get('formatDialog').open);assert.equal(f.get('editor').selectionStart,2);assert.equal(f.get('editor').selectionEnd,7);f.run("openFormat('left')");f.get('editor').focused=false;f.event('document','pointerdown',{target:f.get('theme')});assert(!f.get('formatDialog').open);assert.equal(f.get('editor').focused,false);f.run("openFormat('left')");f.event('document','pointerdown',{target:f.get('contentSplitter')});assert(f.get('formatDialog').open);f.run("setEditing(false,false)");assert(!f.get('formatDialog').open);f.run("setEditing(true,false);openFormat('left');selectNote('reading_reading_journal')");assert(!f.get('formatDialog').open);f.run("openFormat('left');switchVault('projects')");assert(!f.get('formatDialog').open);
});
test('format changes use originating pane and stale pane focus closes the panel',()=>{
 const f=fixture();f.run("setEditing(true,false);setRightEditing(true,false);$('rightEditor').setSelectionRange(0,2);openFormat('right')");assert.equal(f.run('formatTarget.pane'),'right');const left=f.get('editor').value;f.run("applyFormatChoice('bold')");assert.equal(f.get('editor').value,left);assert(f.get('rightEditor').value.startsWith('**'));assert(!f.get('formatDialog').open);f.run("openFormat('right');activatePane('left')");assert(!f.get('formatDialog').open);
});

function setFormatSource(f,text,start=0,end=text.length,pane='left'){
 f.run((pane==='left'?'setEditing':'setRightEditing')+'(true,false)');const editor=f.get(pane==='left'?'editor':'rightEditor');editor.value=text;editor.setSelectionRange(start,end);editor.oninput();return editor;
}
test('Aa recognizes code-body selection, full fences and caret; code click removes outer markers',()=>{
 const source='前文\n\n```js\n包含\n下一行\n```\n\n后文',body=source.indexOf('包含'),open=source.indexOf('```'),close=source.lastIndexOf('```')+3;
 for(const [start,end]of [[body,body+2],[body+1,body+1],[open,close],[open,close+1]]){const f=fixture(),editor=setFormatSource(f,source,start,end);editor.scrollTop=85;f.run("openFormat('left')");assert.equal(f.get('formatCodeChoice').attrs['aria-pressed'],'true');assert.equal(editor.value,source);assert.equal(editor.selectionStart,start);assert.equal(editor.selectionEnd,end);f.run("applyFormatChoice('code')");assert.equal(editor.value,'前文\n\n包含\n下一行\n\n后文');assert.equal(editor.value.slice(editor.selectionStart,editor.selectionEnd),'包含\n下一行');assert.equal(editor.scrollTop,85);f.run("openFormat('left')");assert.equal(f.get('formatCodeChoice').attrs['aria-pressed'],'false');}
});
test('plain text code formatting toggles repeatedly, preserves surrounding lines and uses safe fences',()=>{
 const f=fixture(),editor=setFormatSource(f,'前文\n包含\n后文',4,5);for(let i=0;i<6;i++){f.run("openFormat('left');applyFormatChoice('code')");assert.equal(editor.value,i%2===0?'前文\n```\n包含\n```\n后文':'前文\n包含\n后文');assert.equal(editor.value.slice(editor.selectionStart,editor.selectionEnd),'包含');}
 const g=fixture(),other=setFormatSource(g,'const marker = "```";');g.run("insertFormat('code')");assert(other.value.startsWith('````\n'));assert.match(g.run("renderMarkdown($('editor').value,false)"),/<pre data-source-start="\d+" data-source-end="\d+"><code>const marker/);g.run("insertFormat('code')");assert.equal(other.value,'const marker = "```";');
});
test('code fence matching retains inner fences, CRLF and adjacent blocks and skips YAML metadata',()=>{
 const f=fixture(),source='前文\r\n\r\n~~~~python\r\n包含\r\n```\r\n\r\n~~~~~\r\n\r\n```js\r\n后块\r\n```',editor=setFormatSource(f,source,source.indexOf('包含'),source.indexOf('包含')+2);f.run("openFormat('left')");assert.equal(f.get('formatCodeChoice').attrs['aria-pressed'],'true');f.run("applyFormatChoice('code')");assert.equal(editor.value,'前文\r\n\r\n包含\r\n```\r\n\r\n\r\n```js\r\n后块\r\n```');
 const g=fixture(),text='````js\n```\n# 非标题\n````\n# 标题',e=setFormatSource(g,text,9,10);g.run("openFormat('left')");assert.equal(g.get('formatCodeChoice').attrs['aria-pressed'],'true');assert.equal(g.run("headingsFor($('editor').value).length"),1);assert.match(g.run("renderMarkdown($('editor').value,false)"),/<pre data-source-start="\d+" data-source-end="\d+"><code>```\n# 非标题<\/code><\/pre>/);g.run("applyFormatChoice('code')");assert.equal(e.value,'```\n# 非标题\n# 标题');assert.equal(g.run("codeBlockAt("+JSON.stringify("---\nexample: ```\n---\n正文")+",5,5)"),null);
});
test('mixed selections do not mark a single code block and right-pane toggle preserves left note',()=>{
 const f=fixture(),source='```\n一\n```\n正文\n~~~\n二\n~~~',editor=setFormatSource(f,source,source.indexOf('一'),source.indexOf('二')+1);f.run("openFormat('left')");assert.equal(f.get('formatCodeChoice').attrs['aria-pressed'],'false');f.run('closeFormat()');assert.equal(editor.value,source);
 const g=fixture(),left=g.get('editor').value,right=setFormatSource(g,'```ts\n包含\n```',6,8,'right');g.run("openFormat('right');applyFormatChoice('code')");assert.equal(right.value,'包含');assert.equal(g.get('editor').value,left);assert.equal(g.run('activePane'),'right');
});

test('empty and unclosed code fences toggle safely and closing Aa leaves markers intact',()=>{
 for(const [source,want]of [['```\n```',''],['```js\n包含','包含'],['```js\n包含\n','包含\n']]){const f=fixture(),editor=setFormatSource(f,source,source.length,source.length);f.run("openFormat('left')");assert.equal(f.get('formatCodeChoice').attrs['aria-pressed'],'true');f.run('closeFormat()');assert.equal(editor.value,source);f.run("openFormat('left');applyFormatChoice('code')");assert.equal(editor.value,want);}
 const f=fixture(),editor=setFormatSource(f,'');f.run("insertFormat('code');insertFormat('code')");assert.equal(editor.value,'代码');
});

test('design switch opens Aa directly, stays open for layout controls and reflects URL/close state',()=>{
 const f=fixture(),source=f.get('editor').value;f.get('formatFollowDemo').checked=true;f.get('formatFollowDemo').onchange();assert(f.run('editing'));assert(f.get('formatDialog').open);assert(f.get('formatFollowDemo').checked);assert.equal(f.get('editor').value,source);f.event('document','pointerdown',{target:f.get('designControls')});assert(f.get('formatDialog').open);f.run("setViewport('double');viewportRotated=true;applyViewportGeometry();syncUrl()");assert(f.get('formatDialog').open);const g=fixture(f.href());assert(g.get('formatFollowDemo').checked);assert(g.get('formatDialog').open);f.get('formatFollowDemo').checked=false;f.get('formatFollowDemo').onchange();assert(!f.get('formatDialog').open);f.get('formatFollowDemo').checked=true;f.get('formatFollowDemo').onchange();f.run('closeFormat()');assert.equal(f.get('formatFollowDemo').checked,false);
});
test('design format switch targets active right pane and closes phone navigation before opening',()=>{
 const f=fixture();f.run("setViewport('phone');activatePane('right',true);$('window').classList.add('nav-open');applySplits()");f.get('formatFollowDemo').checked=true;f.get('formatFollowDemo').onchange();assert(f.run('rightEditing'));assert.equal(f.run('formatTarget.pane'),'right');assert(f.get('formatDialog').open);assert(!f.get('window').classList.contains('nav-open'));assert(f.get('formatFollowDemo').checked);
});

test('edit-preview visual variants share the same pane state and survive a reproducible URL',()=>{
 const f=fixture(),left=f.run('current'),right=f.run('reference');f.run("setEditing(true,false);setRightEditing(false,false)");for(const style of ['outline','underline','capsule']){f.get('modeStyle').value=style;f.get('modeStyle').onchange();assert.equal(f.get('window').dataset.modeStyle,style);assert.equal(f.run('editing'),true);assert.equal(f.run('rightEditing'),false);assert.equal(f.run('current'),left);assert.equal(f.run('reference'),right);}f.get('modeStyle').value='underline';f.get('modeStyle').onchange();f.run('syncUrl()');const g=fixture(f.href());assert.equal(g.get('modeStyle').value,'underline');assert.equal(g.get('window').dataset.modeStyle,'underline');assert.equal(g.run('editing'),true);assert.equal(g.run('rightEditing'),false);const bad=fixture('file:///repo/index.html?ui=2&modeStyle=invalid');assert.equal(bad.get('modeStyle').value,'outline');const missing=fixture('file:///repo/index.html?ui=2');assert.equal(missing.get('modeStyle').value,'outline');const legacy=fixture('file:///repo/index.html?ui=2&modeStyle=capsule');assert.equal(legacy.get('modeStyle').value,'capsule');assert(html.includes('<option value="outline" selected>轻描边</option>'));assert(html.includes('id="window" data-mode-style="outline"'));
});


test('same-note preview exposes the follow preference only in its pane menu and persists it',()=>{
 const f=fixture();f.run("openInPane('reading_stream','left');openInPane('reading_stream','right');setEditing(true,false);setRightEditing(false,false);activatePane('left')");
 assert(f.get('rightFollowToggle').classList.contains('hidden')===false);assert(f.get('leftFollowToggle').classList.contains('hidden'));assert(f.get('rightMore').classList.contains('hidden')===false);assert.equal(f.get('rightFollowToggle').attrs['aria-pressed'],'true');
 f.get('rightFollowToggle').onclick();assert.equal(f.run('followEnabled'),false);assert.equal(f.get('rightFollowToggle').attrs['aria-pressed'],'false');assert.equal(new URL(f.href()).searchParams.get('follow'),'0');
 f.get('rightFollowToggle').onclick();assert.equal(f.run('followEnabled'),true);assert.equal(new URL(f.href()).searchParams.get('follow'),'1');
 const restored=fixture(f.href());assert.equal(restored.run('followEnabled'),true);const disabled=fixture(f.href().replace('follow=1','follow=0'));assert.equal(disabled.run('followEnabled'),false);
});

test('manual preview scroll pauses follow until the editor is actively scrolled again',()=>{
 const f=fixture();f.run("openInPane('reading_stream','left');openInPane('reading_stream','right');setEditing(true,false);setRightEditing(false,false);activatePane('left')");
 f.get('rightScroll').dispatch('wheel',{type:'wheel',deltaY:20});assert.equal(f.run('previewFollowing'),false);
 f.get('editor').dispatch('wheel',{type:'wheel',deltaY:20});assert.equal(f.run('previewFollowing'),true);
 f.get('rightScroll').dispatch('keydown',{type:'keydown',key:'ArrowDown'});assert.equal(f.run('previewFollowing'),false);
 f.get('editor').dispatch('keydown',{type:'keydown',key:'a'});assert.equal(f.run('previewFollowing'),false);
 f.get('editor').dispatch('keydown',{type:'keydown',key:'PageDown'});assert.equal(f.run('previewFollowing'),true);
});

test('source offsets map through markdown blocks without using document scroll percentage',()=>{
 const f=fixture();const source='\uFEFF---\r\ntitle: sample\r\n---\r\n# 同名\r\n# 同名\r\n\r\n~~~js\r\n代码\r\n~~~\r\n正文';
 const html=f.run('renderMarkdown('+JSON.stringify(source)+',true)'),ranges=[...html.matchAll(/data-source-start="(\d+)" data-source-end="(\d+)"/g)].map(match=>[Number(match[1]),Number(match[2])]);
 assert.deepEqual(ranges,[[source.indexOf('# 同名'),source.indexOf('# 同名')+4],[source.indexOf('# 同名',source.indexOf('# 同名')+1),source.indexOf('# 同名',source.indexOf('# 同名')+1)+4],[source.indexOf('~~~js'),source.indexOf('~~~\r\n正文')+3],[source.indexOf('正文'),source.indexOf('正文')+2]]);
 assert.equal(f.run('previewPositionForOffset(15,[{start:0,end:10,top:20,height:100},{start:20,end:30,top:200,height:40}])'),120);
 assert.equal(f.run('previewPositionForOffset(100,[{start:0,end:10,top:20,height:100}])'),120);
});

test('editor scroll maps its source block to preview position in either pane direction',()=>{
 const f=fixture();f.run("openInPane('reading_stream','left');openInPane('reading_stream','right');setEditing(true,false);setRightEditing(false,false);activatePane('left');editorLinePositions=[{start:0,end:10,top:0,height:100},{start:10,end:20,top:100,height:100}];previewBlockPositions=[{start:0,end:10,top:20,height:100},{start:10,end:20,top:500,height:200}];followGeometryDirty=false;$('editor').scrollHeight=1000;$('editor').clientHeight=300;$('editor').scrollTop=150;$('rightScroll').scrollHeight=1500;$('rightScroll').clientHeight=300;syncPreviewFollow()");
 assert.equal(f.get('rightScroll').scrollTop,600);
 f.run("setEditing(false,false);setRightEditing(true,false);activatePane('right');editorLinePositions=[{start:0,end:10,top:0,height:100},{start:10,end:20,top:100,height:100}];previewBlockPositions=[{start:0,end:10,top:20,height:100},{start:10,end:20,top:500,height:200}];followGeometryDirty=false;$('rightEditor').scrollHeight=1000;$('rightEditor').clientHeight=300;$('rightEditor').scrollTop=150;$('writingScroll').scrollHeight=1500;$('writingScroll').clientHeight=300;syncPreviewFollow()");
 assert.equal(f.get('writingScroll').scrollTop,600);
});

test('hidden or different-note panes never receive follow scrolling',()=>{
 const f=fixture();f.run("openInPane('reading_stream','left');openInPane('reading_stream','right');setEditing(true,false);setRightEditing(false,false);activatePane('left');editorLinePositions=[{start:0,end:10,top:0,height:100}];previewBlockPositions=[{start:0,end:10,top:400,height:200}];followGeometryDirty=false;$('editor').scrollTop=100;$('rightScroll').scrollTop=17;referenceEnabled=false;syncPreviewFollow()");
 assert.equal(f.get('rightScroll').scrollTop,17);
 f.run("referenceEnabled=true;reference='reading_reading_journal';$('rightScroll').scrollTop=23;syncPreviewFollow()");assert.equal(f.get('rightScroll').scrollTop,23);
});

test('root and folder new-entry controls create nested notes and retain empty folders',()=>{
 const f=fixture();assert(html.includes('id="newAtRoot"'));assert(html.includes('data-create-in-folder='));f.get('newAtRoot').onclick();assert(f.get('newEntryDialog').open);assert.equal(f.get('newEntryFolder').value,'');
 f.get('newFolderKind').onclick();f.get('newEntryName').value='新建文件夹/子目录';f.get('confirmNewEntry').onclick();assert.equal(f.run("demoFolders.some(item=>item.vault===activeVault&&item.path==='新建文件夹/子目录')"),true);assert(f.get('notes').innerHTML.includes('data-create-in-folder="新建文件夹/子目录"'));
 f.run("openNewEntry('新建文件夹/子目录','note')");assert.equal(f.get('newEntryFolder').value,'新建文件夹/子目录');f.get('newEntryName').value='更深/文件夹内笔记.md';f.get('confirmNewEntry').onclick();assert.equal(f.run('note(current).title'),'文件夹内笔记');assert.equal(f.run('note(current).folder'),'新建文件夹/子目录/更深');assert.equal(f.get('newEntryDialog').open,false);
});

test('new-entry paths retain duplicate suffixing and reject traversal or trailing slash',()=>{
 const f=fixture();f.run("openNewEntry('','folder')");f.get('newEntryName').value='10_写作';f.get('confirmNewEntry').onclick();assert.equal(f.run("folderPathsForVault().includes('10_写作-2')"),true);assert.equal(f.get('newEntryDialog').open,false);
 f.run("openNewEntry('','folder')");f.get('newEntryName').value='../越界';f.get('confirmNewEntry').onclick();assert.match(f.get('newEntryError').textContent,/有效名称/);assert(f.get('newEntryDialog').open);
 f.get('newEntryName').value='只要目录/';f.get('confirmNewEntry').onclick();assert.match(f.get('newEntryError').textContent,/不能以 \/ 结尾/);assert(f.get('newEntryDialog').open);
 const existing=f.run('currentNotes()[0]');f.run("openNewEntry(note(currentNotes()[0].id).folder,'note')");f.get('newEntryName').value=existing.title+'.md';f.get('confirmNewEntry').onclick();assert.equal(f.run('note(current).title'),existing.title+'-2');assert.equal(f.get('newEntryDialog').open,false);
});

test('folder swipe operations expose sharing, rename, move and confirmed permanent delete without a swipe-delete action',()=>{
 const f=fixture();f.run("switchVault('local');addDemoFolder(activeVault,'10_写作/子目录');notes.push({id:'folder-child',vault:activeVault,folder:'10_写作/子目录',title:'子笔记',text:'',deleted:false});renderTree()");
 const tree=f.get('notes').innerHTML;for(const action of ['share','rename','move','delete'])assert(tree.includes('data-folder-action="'+action+'"'));
 const folderStart=tree.indexOf('data-folder-wrap="local/10_写作"');assert(tree.indexOf('</div></div></div><div class="tree-children"',folderStart)>folderStart);
 assert(tree.includes('Shift+F10'));assert(html.includes('id="deleteFolderDialog"'));assert(html.includes('id="confirmDeleteFolder"'));
 assert.match(code,/function bindFolderSwipe\([\s\S]*?Math\.max\(-drag\.width/);assert(!code.split('\n').find(line=>line.startsWith('function bindFolderSwipe(')).includes('deleteFile('));
 f.run("openDeleteFolder('10_写作')");assert(f.get('deleteFolderDialog').open);assert.match(f.get('deleteFolderSummary').textContent,/3 篇笔记/);f.get('cancelDeleteFolder').onclick();assert(f.run("folderPathsForVault().includes('10_写作')"));
 f.run("openDeleteFolder('10_写作')");f.get('confirmDeleteFolder').onclick();assert(!f.get('deleteFolderDialog').open);assert(!f.run("folderPathsForVault().some(path=>path==='10_写作'||path.startsWith('10_写作/'))"));assert(!f.run("currentNotes().some(n=>n.folder==='10_写作'||n.folder.startsWith('10_写作/'))"));assert.equal(f.run('deletedUndo'),null);
});

test('folder rename and move retarget the full active subtree, preserve collapse state and suffix collisions',()=>{
 const f=fixture();f.run("switchVault('local');addDemoFolder(activeVault,'10_写作/子目录');notes.push({id:'folder-child',vault:activeVault,folder:'10_写作/子目录',title:'子笔记',text:'',deleted:false});folderState['local/10_写作']=false;folderState['local/10_写作/子目录']=false;addDemoFolder(activeVault,'写作');openFolderAction('rename','10_写作')");
 assert.equal(f.get('fileActionDialog').open,true);assert.equal(f.get('renameInput').value,'10_写作');f.get('renameInput').value='写作';f.get('confirmFileAction').onclick();assert.equal(f.run("folderPathsForVault().includes('写作-2')"),true);assert.equal(f.run("note('stream').folder"),'写作-2');assert.equal(f.run("note('folder-child').folder"),'写作-2/子目录');assert.equal(f.run("folderState['local/写作-2']"),false);assert.equal(f.run("folderState['local/写作-2/子目录']"),false);
 f.run("addDemoFolder(activeVault,'20_样式/写作-2');openFolderAction('move','写作-2')");const options=f.get('moveSelect').innerHTML;assert(options.includes('根目录'));assert(!options.includes('写作-2/子目录'));f.get('moveSelect').value='写作-2/子目录';f.get('confirmFileAction').onclick();assert.match(f.get('fileActionError').textContent,/自身或子文件夹/);assert(f.get('fileActionDialog').open);
 f.get('moveSelect').value='20_样式';f.get('confirmFileAction').onclick();assert.equal(f.run("folderPathsForVault().includes('20_样式/写作-2-2')"),true);assert.equal(f.run("note('stream').folder"),'20_样式/写作-2-2');assert.equal(f.run("note('folder-child').folder"),'20_样式/写作-2-2/子目录');assert.equal(f.run("folderState['local/20_样式/写作-2-2/子目录']"),false);
});

test('folder sharing stays scoped to the invoked folder and restores that sample target from its URL',()=>{
 const f=fixture();f.run("switchVault('local');addDemoFolder(activeVault,'10_写作/子目录');notes.push({id:'folder-child',vault:activeVault,folder:'10_写作/子目录',title:'子笔记',text:'',deleted:false});openFolderShare('10_写作')");
 assert(f.get('shareDialog').open);assert.equal(f.get('shareScope').value,'folder');assert.equal(f.run('shareSnapshot.rows.length'),3);assert.equal(f.run('shareSnapshot.title'),'10_写作');assert(new URL(f.href()).searchParams.get('shareFolder')==='10_写作');
 f.get('shareScope').value='vault';f.get('shareScope').onchange();f.get('shareScope').value='folder';f.get('shareScope').onchange();assert.equal(f.run('shareSnapshot.rows.length'),3);const restored=fixture(f.href());assert(restored.get('shareDialog').open);assert.equal(restored.run('shareFolderPath'),'10_写作');assert.equal(restored.run('shareSnapshot.rows.length'),2);assert(restored.run("shareSnapshot.rows.every(row=>row.folder==='10_写作'||row.folder.startsWith('10_写作/'))"));
});

test('Escape closes swipe actions and returns focus to the file or folder row',()=>{
 for(const type of ['file','folder']){
  const f=fixture(),action={},actions={inert:false,contains:element=>element===action},front={style:{},classList:{remove(){}}},trigger={focus(){this.focused=true;}};
  const wrap={classList:{toggle(){},remove(){}},querySelector(selector){if(selector==='.file-actions,.folder-actions')return actions;if(selector==='.file-front,.folder-front')return front;if(selector==='[data-note],[data-folder]')return trigger;return null;}};
  f.get('notes').querySelectorAll=()=>[wrap];f.run('document').activeElement=action;f.event('document','keydown',{key:'Escape'});
  assert.equal(actions.inert,true);assert.equal(trigger.focused,true,`${type} trigger regains focus`);
 }
});

test('vault manager handlers reference controls that exist in the page markup',()=>{
 const actionCode=code.slice(code.indexOf('function renderVaultManager'),code.indexOf('function notePath'));
 const referencedIds=Array.from(actionCode.matchAll(/\$\('([^']+)'\)/g),match=>match[1]);
 assert(referencedIds.length>0);
 for(const id of referencedIds)assert(markupIds.has(id),`vault manager references missing element #${id}`);
});

test('temporary vault names, notes and folders stay out of reproduction URLs',()=>{
 const f=fixture();f.run("openVaultManager(false);openVaultAction('create')");f.get('vaultActionName').value='临时私有库';f.get('confirmVaultAction').onclick();
 f.run("addDemoFolder(activeVault,'用户资料/草稿');folderState[activeVault+'/用户资料']=false;notes.push({id:'private-note-id',vault:activeVault,folder:'用户资料',title:'机密标题',text:'机密正文',deleted:false});current='private-note-id';reference='private-note-id';shareFolderPath='用户资料';$('shareScope').value='folder';$('shareDialog').open=true;syncUrl('replace')");
 const url=f.href(),params=new URL(url).searchParams,decoded=decodeURIComponent(url);
 assert(!decoded.includes('临时私有库'));assert(!decoded.includes('private-note-id'));assert(!decoded.includes('机密标题'));assert(!decoded.includes('机密正文'));assert(!decoded.includes('用户资料'));
 assert(Array.from(f.run('SAMPLE_VAULT.vaults.map(v=>v.id)')).includes(params.get('vault')));
 const publicNoteIds=Array.from(f.run('publicSampleNotes.map(n=>n.id)'));assert(publicNoteIds.includes(params.get('left')));assert(publicNoteIds.includes(params.get('right')));
 assert.equal(params.get('panel'),'none');assert.equal(params.has('collapsed'),false);assert.equal(params.has('shareFolder'),false);
});

test('vault manager is reachable from the picker and its page is restored from the URL',()=>{
 const f=fixture();f.get('manageVaults').onclick();assert(f.run('vaultManagerOpen'));assert(f.get('vaultManagerPage').classList.contains('hidden')===false);assert(f.get('vaultCards').innerHTML.includes('阅读笔记'));assert(f.get('vaultCards').innerHTML.includes('项目笔记'));assert.equal(new URL(f.href()).searchParams.get('view'),'vaults');
 const restored=fixture(f.href());assert(restored.run('vaultManagerOpen'));assert.equal(restored.get('vaultManagerPage').classList.contains('hidden'),false);assert(restored.get('vaultCards').innerHTML.includes('本地笔记'));restored.get('closeVaultManager').onclick();assert(!restored.run('vaultManagerOpen'));
});

test('vault create and rename preserve the active empty vault and suffix duplicate names',()=>{
 const f=fixture();f.run("openVaultManager(false);openVaultAction('create')");assert(f.get('vaultActionDialog').open);f.get('vaultActionName').value='../阅读笔记';f.get('vaultActionName').oninput();assert.match(f.get('vaultActionPath').textContent,/vaults\/阅读笔记-2/);f.get('confirmVaultAction').onclick();assert.equal(f.run('activeVault'),'阅读笔记-2');assert.equal(f.run('currentNotes().length'),0);assert(f.get('notes').innerHTML.includes('当前知识库还没有笔记'));assert(f.get('vaultCards').innerHTML.includes('阅读笔记-2'));
 f.run("openVaultAction('rename','阅读笔记-2')");f.get('vaultActionName').value='新/空库';f.get('vaultActionName').oninput();f.get('confirmVaultAction').onclick();assert.equal(f.run('activeVault'),'新空库');assert.equal(f.run('currentNotes().length'),0);assert(f.get('vaultCards').innerHTML.includes('vaults/新空库'));
});

test('vault rename migrates notes and folder state; confirmed deletion removes only that demo vault',()=>{
 const f=fixture();f.run("switchVault('reading');folderState['reading/10_写作']=false;openVaultManager(false);openVaultAction('rename','reading')");f.get('vaultActionName').value='项目笔记';f.get('vaultActionName').oninput();f.get('confirmVaultAction').onclick();assert.equal(f.run('activeVault'),'项目笔记-2');assert.equal(f.run("currentNotes().length"),2);assert(f.run("notes.filter(n=>n.vault==='reading').length===0"));assert.equal(f.run("folderState['项目笔记-2/10_写作']"),false);
 f.run("openVaultAction('delete','项目笔记-2')");assert(f.get('vaultActionDialog').open);assert.match(f.get('vaultActionDescription').textContent,/刷新后公开样例会恢复/);f.get('confirmVaultAction').onclick();assert(!f.run("libraries.some(v=>v.id==='项目笔记-2')"));assert.equal(f.run("notes.filter(n=>n.vault==='项目笔记-2').length"),0);assert.equal(f.run('activeVault'),'local');assert(f.get('vaultCards').innerHTML.includes('本地笔记'));
});

test('deleting the final vault leaves a recoverable manager empty state and creation path',()=>{
 const f=fixture();f.run('openVaultManager(false)');for(const id of ['reading','projects','local']){f.run(`openVaultAction('delete','${id}');confirmVaultAction()`);}assert.equal(f.run('libraries.length'),0);assert.equal(f.run('activeVault'),'');assert(f.get('vaultCards').innerHTML.includes('暂无知识库'));assert(f.get('notes').innerHTML.includes('当前没有知识库'));assert(f.get('vaultName').textContent.includes('暂无知识库'));
 f.get('createVaultButton').onclick();f.get('vaultActionName').value='重新开始';f.get('confirmVaultAction').onclick();assert.equal(f.run('libraries.length'),1);assert.equal(f.run('activeVault'),'重新开始');assert.equal(f.run('currentNotes().length'),0);
});

test('browser history remains usable after deleting every in-memory vault',()=>{
 const f=fixture();f.run('openVaultManager(false)');for(const id of ['reading','projects','local'])f.run(`openVaultAction('delete','${id}');confirmVaultAction()`);
 assert.equal(f.run('libraries.length'),0);assert.doesNotThrow(()=>f.back());assert.equal(f.run('libraries.length'),0);assert.equal(f.run('activeVault'),'');assert(f.run('vaultManagerOpen'));
});

test('wiki links resolve relative paths, offer missing-note creation, and backlink results open in their pane',()=>{
 const f=fixture();
 f.run("openInPane('reading_reading_journal','left');note('reading_reading_journal').text='[[10_写作/基础排版|排版]] `[[幽灵]]`\\n```md\\n[[幽灵]]\\n```';render()");
 assert.match(f.get('article').innerHTML,/data-source="reading_stream"/);
 assert(!f.get('article').innerHTML.includes('data-wiki-create="幽灵"'));
 f.run("note('reading_reading_journal').text='![[10_写作/基础排版]] [[10_写作/基础排版#二级标题|标题]]';render()");
 assert(f.get('article').innerHTML.includes('![[10_写作/基础排版]]'));
 assert(!f.get('article').innerHTML.includes('data-wiki-create="10_写作/基础排版"'));
 assert.match(f.get('article').innerHTML,/标题锚点暂不支持/);
 f.run("openInPane('reading_reading_journal','left');note('reading_reading_journal').text='[[新建条目]]';render()");
 assert.match(f.get('article').innerHTML,/data-wiki-create="新建条目"/);
 const missing={dataset:{wikiCreate:'新建条目'}};f.get('article').contains=node=>node===missing;
 f.get('article').dispatch('click',{target:{closest:selector=>selector==='[data-wiki-create]'?missing:null},preventDefault(){}});
 assert.equal(f.get('newEntryDialog').open,true);assert.equal(f.get('newEntryFolder').value,'40_阅读');assert.equal(f.get('newEntryName').value,'新建条目');
 f.get('confirmNewEntry').onclick();assert.equal(f.run('note(current).title'),'新建条目');assert.equal(f.run('note(current).folder'),'40_阅读');
 const g=fixture();g.run("openInPane('reading_reading_journal','left');note('reading_reading_journal').text='[[10_写作/基础排版]] `[[幽灵]]`\\n~~~md\\n[[幽灵]]\\n~~~';render();openInPane('reading_stream','right')");g.get('rightBacklinks').onclick();
 assert.equal(g.get('rightBacklinksCount').textContent,'1');assert(!g.get('rightBacklinksPanel').classList.contains('hidden'));assert(g.get('rightBacklinksItems').innerHTML.includes('40_阅读 / 读书对话练习.md'));
 g.flush();assert.equal(new URL(g.href()).searchParams.get('backlinks'),'right');
 const source={dataset:{backlinkNote:'reading_reading_journal',backlinkPane:'right'}};g.event('document','click',{target:{closest:selector=>selector==='[data-backlink-note]'?source:null}});assert.equal(g.run('reference'),'reading_reading_journal');assert.equal(g.run('activePane'),'right');
 g.run("note('reading_reading_journal').text='![[10_写作/基础排版]]';renderBacklinksPanel('right')");assert.equal(g.get('rightBacklinksCount').textContent,'0');
});

test('preview images open a scrollable full-image viewer by click or keyboard and restore focus on close',()=>{
 const f=fixture();f.run("openInPane('reading_stream','left')");assert.match(f.get('article').innerHTML,/data-preview-image/);assert.match(f.get('article').innerHTML,/role="button" tabindex="0" aria-label="查看完整图片：[^\"]+" alt="/);
 const image={src:'data:image/svg+xml;base64,PHN2Zz4=',alt:'长图',focus(){this.focused=true}};f.get('article').contains=node=>node===image;
 f.get('article').dispatch('click',{target:{closest:selector=>selector==='[data-preview-image]'?image:null}});assert.equal(f.get('imageViewerDialog').open,true);assert.equal(f.get('imageViewerImage').src,image.src);assert.equal(f.get('imageViewerTitle').textContent,'长图');
 f.get('closeImageViewer').onclick();assert.equal(f.get('imageViewerDialog').open,false);assert.equal(f.get('imageViewerImage').alt,'');assert.equal(image.focused,true);
 let prevented=false;f.get('article').dispatch('keydown',{target:{matches:selector=>selector==='img[data-preview-image]',src:image.src,alt:image.alt,focus(){this.focused=true}},key:'Enter',preventDefault(){prevented=true}});assert(prevented);assert.equal(f.get('imageViewerDialog').open,true);assert.match(html,/\.image-viewer-scroll\{[^}]*overflow:auto/);f.get('closeImageViewer').onclick();
});

test('escaped wiki links stay literal and do not create backlinks',()=>{
 const f=fixture(),escaped='\\[[10_写作/基础排版]]';
 assert.deepEqual(JSON.parse(f.run('JSON.stringify(wikiTargetsIn('+JSON.stringify(escaped)+'))')),[]);
 f.run('note(\'reading_reading_journal\').text='+JSON.stringify(escaped)+';render()');
 assert(!f.get('article').innerHTML.includes('class="wiki-link'));
 assert(!f.get('article').innerHTML.includes('data-wiki-create='));
});
