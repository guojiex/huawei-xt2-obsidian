import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';
import vm from 'node:vm';
const html=readSourceFile(new URL('../../docs/prototype/v2/index.html',import.meta.url));
const code=html.match(/<script>([\s\S]*?)<\/script>/)[1];
const markupIds=new Set(Array.from(html.matchAll(/\bid="([^"]+)"/g),match=>match[1]));
test('footer links to the current v2 design notes without restoring the deleted prototype entry',()=>{
 assert.match(html,/<a href="\.\/设计说明\.md">设计说明<\/a>/);
 assert.doesNotMatch(html,/href="\.\.\/index\.html"/);
});
test('phone scrim closes navigation and simple toolbar follows editor focus',()=>{
 const f=fixture();const extension=html.match(/\/\/ v1\.29: first tap[\s\S]*?(?=<\/script>)/)[0];f.run(extension);
 f.run("setViewport('phone');$('window').classList.add('nav-open')");let prevented=false,stopped=false;f.get('navScrim').dispatch('click',{preventDefault(){prevented=true},stopPropagation(){stopped=true}});assert(prevented&&stopped);assert(!f.get('window').classList.contains('nav-open'));assert(f.get('menu').focused);
 f.run("experience='simple';activePane='left';document.activeElement={closest:s=>s==='[contenteditable=true]'?{}:null,blur(){document.activeElement=null}};$('leftPane').contains=()=>true;refreshSimpleTextFocus()");assert(!f.get('simpleTools').classList.contains('hidden'));assert(f.get('simpleToolsRight').classList.contains('hidden'));f.get('simpleDone').onclick();assert(f.get('simpleTools').classList.contains('hidden'));assert(f.get('leftTitle').focused);
});
test('save-success feedback stays hidden until the simulated save succeeds, then fades out',()=>{
 assert.match(html,/\.save-feedback\{position:absolute;left:var\(--s5\)/);
 assert.match(code,/scheduleSaveFeedback\(\).*setTimeout\(\(\)=>\{const feedback=saveFeedback\(\);feedback\.classList\.remove\('hidden'\);saveFeedbackHideTimer=setTimeout\(\(\)=>feedback\.classList\.add\('hidden'\),3500\);\},800\)/);
 assert.match(code,/event\.target===\$\('editor'\)\|\|event\.target===\$\('rightEditor'\)/);
});
function fixture(href='file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&vault=reading&left=reading_stream&right=reading_reading_journal',storage=new Map()){
 const nodes=new Map(),events={document:{},window:{}},pending=[];
 const listen=(area,key,fn)=>(events[area][key]??=[]).push(fn);
 const get=id=>{if(!nodes.has(id))nodes.set(id,{clientWidth:1200,clientHeight:300,scrollHeight:1000,scrollTop:0,innerHTML:'',value:'',textContent:'',dataset:{},attrs:{},style:{setProperty(k,v){this[k]=v},removeProperty(k){delete this[k]}},classList:{values:new Set(),contains(k){return this.values.has(k)},add(...keys){keys.forEach(k=>this.values.add(k))},remove(...keys){keys.forEach(k=>this.values.delete(k))},toggle(k,on=!this.values.has(k)){on?this.values.add(k):this.values.delete(k);return on}},setAttribute(k,v){this.attrs[k]=v},querySelectorAll(){return[]},listeners:{},addEventListener(k,fn){(this.listeners[k]??=[]).push(fn)},dispatch(type,event){for(const fn of this.listeners[type]||[])fn(event)},getBoundingClientRect(){return this.rect||(/^(formatBtn|rightFormatBtn)$/.test(id)?{left:100,right:148,top:700,bottom:748,width:48,height:48}:id==='formatDialog'?{left:0,right:360,top:0,bottom:400,width:360,height:400}:{left:0,right:1200,top:0,bottom:800,width:1200,height:800})},focus(){this.focused=true},select(){this.selected=true},contains(){return false},removeAttribute(k){delete this.attrs[k];if(k==='src')this.src=''},setSelectionRange(a,b){this.selectionStart=a;this.selectionEnd=b},setRangeText(text,start,end){this.value=this.value.slice(0,start)+text+this.value.slice(end);this.selectionStart=start;this.selectionEnd=start+text.length},show(){this.open=true},showModal(){this.open=true},close(){this.open=false}});return nodes.get(id);};
 const sharePaper=get('sharePaper'),shareStage=get('shareStage');shareStage.clientWidth=520;sharePaper.parentElement=shareStage;sharePaper.scrollHeight=800;sharePaper.style[Symbol.iterator]=function*(){};
 const rootStyle=new Set(['--ink','--paper','--line','--muted','--nav','--blue']);rootStyle.getPropertyValue=name=>name==='--ink'?'#202530':'';
 for(const id of ['navSplitter','contentSplitter'])get(id).querySelector=selector=>selector==='.split-tip'?get(id+'Tip'):null;
 for(const id of ['leftPane','referencePane'])get(id).querySelector=selector=>selector==='.pane-label'?get(id+'Label'):null;
 for(const id of ['switchPane','mobileBacklinks','mobileFollow','mobileFavorite'])get(id).querySelector=selector=>selector==='.menu-label'?get(id+'Label'):null;
 for(const id of ['leftEmpty','rightEmpty']){
  const box=get(id),prefix=id==='rightEmpty'?'rightEmpty':'empty';
  box.querySelector=selector=>selector==='.pane-empty-reopen'?null:selector==='.primary'?get(prefix+'NewNote'):null;
  box.querySelectorAll=selector=>selector==='[data-empty-act]'?['new','search'].map((act)=>{const n=get(prefix+(act==='new'?'NewNote':'Search'));n.dataset.emptyAct=act;return n;}):[];
 }
 let location=new URL(href),index=0;const history=[location.href];
 const win={innerWidth:1320,innerHeight:1000,matchMedia:query=>({matches:false,media:query}),get location(){return location},history:{pushState(_,__,href){location=new URL(href);history.splice(++index);history.push(location.href)},replaceState(_,__,href){location=new URL(href);history[index]=location.href}},addEventListener(k,fn){listen('window',k,fn)}};
 const context=vm.createContext({URL,URLSearchParams,window:win,document:{getElementById:get,querySelector:selector=>selector==='#sharePreview .share-paper'?sharePaper:null,querySelectorAll(){return[]},styleSheets:[{cssRules:[{selectorText:':root',style:rootStyle}]}],body:{dataset:{}},addEventListener(k,fn){listen('document',k,fn)}},queueMicrotask:fn=>pending.push(fn),setTimeout:fn=>{pending.push(fn);return 1},clearTimeout(){},ResizeObserver:class{observe(){}},MutationObserver:class{observe(){} disconnect(){}},getComputedStyle:element=>({paddingLeft:element===shareStage?'16px':'0px',getPropertyValue:k=>k==='--pane-min'?'240px':k==='--format-width'?'360px':k==='--s2'?'8px':'16px'}),localStorage:{getItem:k=>storage.get(k)||null,setItem:(k,v)=>storage.set(k,v),removeItem:k=>storage.delete(k)}});
 for(const id of ['updateCheckTemplate','updateCheckDemoTemplate']){
  const template=html.match(new RegExp(`<template id="${id}">([\\s\\S]*?)</template>`));
  get(id).innerHTML=template?.[1]||'';
 }
 get('aboutOverview').firstElementChild=get('aboutHero');
 get('updateCheckDemo').value='idle';
 for(const id of ['aboutHero','designControls']){
  const node=get(id);
  node.insertAdjacentHTML=(position,markup)=>{node.insertions??=[];node.insertions.push({position,markup});};
 }
 const run=s=>vm.runInContext(s,context);run(code);
 return {get,run,href:()=>location.href,flush(){while(pending.length)pending.shift()()},event(area,type,event={}){for(const fn of events[area][type]||[])fn(event)},back(){assert(index>0);location=new URL(history[--index]);for(const fn of events.window.popstate||[])fn({})},forward(){assert(index<history.length-1);location=new URL(history[++index]);for(const fn of events.window.popstate||[])fn({})},history};
}
test('vault manager shares the selected library as ZIP and restores focus',()=>{
 const f=fixture();f.run("openVaultManager(false);gitShareDemo=true");
 assert.match(f.get('vaultCards').innerHTML,/data-vault-action="share"/);
 const before=f.run('activeVault');const trigger={isConnected:true,focus(){this.focused=true}};
 f.get('vaultCards').onclick({target:{closest:()=>({dataset:{vaultAction:'share',vaultId:'projects'},...trigger,focus:trigger.focus})}});
 assert.equal(f.run('activeVault'),before);assert.equal(f.run('shareSnapshot.title'),'项目笔记');
 assert.equal(f.run('shareSnapshot.scope'),'vault');assert(f.run('shareSnapshot.zip'));
 assert(f.get('shareScopeSeg').classList.contains('hidden'));assert(f.get('shareRemoteLink').classList.contains('hidden'));
 f.run(html.match(/\$\('shareDialog'\)\.addEventListener\('close',\(\)=>\{if\(!shareVaultTarget\)return;[^\n]+/)[0]);
 const back=f.run('shareReturnFocus');f.get('shareDialog').dispatch('close',{});assert(back.focused);assert.equal(f.run('shareVaultTarget'),'');
  f.run("notes.filter(n=>n.vault==='local').forEach(n=>n.deleted=true);renderVaultManager()");assert.match(f.get('vaultCards').innerHTML,/data-vault-action="share" data-vault-id="local" disabled/);
});
test('share scope hides the folder segment when it would duplicate the vault root',()=>{
  const f=fixture();
  f.get('shareBtn').onclick();
  assert(!f.get('shareFolderScope').classList.contains('hidden'));
  assert.equal(f.run('shareSnapshot.scope'),'note');
  f.run("notes.push({id:'root-note',vault:activeVault,folder:'',title:'根笔记',tag:'',text:'正文',deleted:false});current='root-note'");
  f.get('shareBtn').onclick();
  assert(f.get('shareFolderScope').classList.contains('hidden'));
  assert.equal(f.get('shareScope').value,'note');
  assert.equal(f.run('shareSnapshot.scope'),'note');
  f.run("$('shareScope').value='folder';renderShareOptions()");
  assert.equal(f.get('shareScope').value,'note');
  assert(f.get('shareFolderScope').classList.contains('hidden'));
});
test('settings keeps single-vault export and recommends full app backup before reset',()=>{
 const f=fixture();const extension=html.match(/\/\/ v1\.37: data page backup export[\s\S]*?(?=<\/script>)/)[0];f.run(extension);
 assert.equal(f.get('exportVaultBackup').disabled,false);f.get('exportVaultBackup').onclick();
 assert.equal(f.run('shareSnapshot.title'),'阅读笔记');assert.equal(f.run('shareSnapshot.scope'),'vault');assert(f.run('shareSnapshot.zip'));
 f.get('shareDialog').open=false;f.get('resetConfirm').classList.remove('hidden');f.get('resetExportFirst').onclick();assert(f.get('resetConfirm').classList.contains('hidden'));assert(f.get('appBackupDialog').open);assert.equal(f.run('appBackupMode'),'export');f.run('closeAppBackup()');
 f.run("notes.filter(n=>n.vault===activeVault).forEach(n=>n.deleted=true);syncExportBackup()");
 assert(f.get('exportVaultBackup').disabled);f.get('shareDialog').open=false;f.get('resetExportFirst').onclick();assert.equal(f.get('shareDialog').open,false);assert(f.get('appBackupDialog').open,'app backup remains available when the current vault is empty');
});
test('decision prototypes handle TSV, cross-vault search and ZIP import states',()=>{
 const f=fixture();const extension=html.match(/\/\/ v1\.14 14\.4:[\s\S]*?(?=\/\/ v1\.32 32\.1:)/)[0];f.run(extension);
 assert.equal(f.run("tableMarkdown(parseTsv('A\\tB\\n1\\t2'))"),'| A | B |\n| --- | --- |\n| 1 | 2 |');
 assert.equal(f.run("parseTsv('A\\tB\\n1')"),null);
 f.get('quickSearchInput').value='笔记';f.run("setSearchScope('all')");assert.match(f.get('quickSearchResults').innerHTML,/search-group/);
 f.run('openQuickSearch()');assert.equal(f.run('searchScope'),'current');
 f.run('openImportVault()');f.get('importZipTab').onclick();assert(f.get('confirmImportVault').disabled);
 f.get('importFailDemo').onclick();assert.equal(f.run('importZipState'),'error');assert(f.get('confirmImportVault').disabled);
 f.get('chooseImportZip').onclick();assert.equal(f.run('importZipState'),'selected');assert.equal(f.get('confirmImportVault').disabled,false);
});
test('importSource=zip restores the import dialog on the ZIP tab and syncs back to the URL',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&importSource=zip');
 const extension=html.match(/\/\/ v1\.14 14\.4:[\s\S]*?(?=\/\/ v1\.32 32\.1:)/)[0];f.run(extension);
 assert(f.get('importVaultDialog').open);assert.equal(f.run('importVaultSource'),'zip');
 assert(!f.get('importZipPanel').classList.contains('hidden'));assert(f.get('importLocalPanel').classList.contains('hidden'));assert(f.get('importGitPanel').classList.contains('hidden'));
 assert.match(f.get('importVaultLead').textContent,/从 ZIP 备份新建一个知识库/);
 assert.match(f.href(),/importSource=zip/);
 f.get('importVaultDialog').close();f.run("syncUrl('replace')");assert.doesNotMatch(f.href(),/importSource=/);
});
test('release notes hide versions newer than the installed version',()=>{
 const f=fixture();assert.equal(f.run("versionNotAfter('1.0.0','0.2.0')"),false);assert.equal(f.run("versionNotAfter('0.2.0','0.2.0')"),true);
 assert.match(f.run("renderReleaseEntries([{version:'1.0.0',title:'future',date:'',changes:[]}])"),/当前版本的更新说明将在发布后显示/);
});
test('settings header returns one level at a time in single-pane layouts',()=>{
 const f=fixture();f.run("setViewport('phone');openSettings();chooseSettings('about',false);$('openHistory').onclick()");
 assert(f.run('historyOpen'));f.get('closeSettings').onclick();assert(!f.run('historyOpen'));assert(f.run('settingsOpen'));assert(f.get('settingsPage').classList.contains('detail-open'));
 f.get('closeSettings').onclick();assert(!f.get('settingsPage').classList.contains('detail-open'));assert(f.get('settingsNav-about').focused);
 f.get('closeSettings').onclick();assert(!f.run('settingsOpen'));
 f.run("setViewport('wide');openSettings();chooseSettings('about',false)");f.get('closeSettings').onclick();assert(!f.run('settingsOpen'));
 f.run("setViewport('wide');$('window').classList.add('compact-height');openSettings();chooseSettings('general',false)");f.get('closeSettings').onclick();assert(f.run('settingsOpen'));assert(!f.get('settingsPage').classList.contains('detail-open'));
});
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
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&vault=projects&left=welcome&right=../../x&preset=bogus&theme=%3Cscript%3E&nw=Infinity&cw=-3&collapsed=oops&panel=fileaction&file=missing');assert.equal(f.run('activeVault'),'projects');assert.equal(f.run('current'),'projects_inbox');assert.equal(f.run('reference'),'projects_todo');assert.equal(f.run('viewportPreset'),'wide');assert.equal(f.run('document.body.dataset.theme'),'light');assert.equal(f.run('widths.nav'),1/3);assert(!f.get('fileActionDialog').open);
});
test('share format and page, format panel, and non-destructive file action can be reopened from links',()=>{
 const f=fixture();f.get('shareBtn').onclick();f.get('shareScope').value='vault';f.get('shareScope').onchange();f.get('shareFile').onclick();f.run('syncUrl()');const g=fixture(f.href());assert(g.get('shareDialog').open);assert.equal(g.get('shareScope').value,'vault');assert.equal(g.run('shareStage'),'file');assert(g.get('sharePreview').innerHTML.includes('.zip'));
 const h=fixture();h.run("setEditing(true,false);openFormat('left');syncUrl()");assert(fixture(h.href()).get('formatDialog').open);
 const i=fixture();i.run("openFileAction('rename','reading_stream');syncUrl()");const j=fixture(i.href());assert(j.get('fileActionDialog').open);assert.equal(j.run("note('reading_stream').title"),'基础排版');
});
test('Git demo restores import, sync entry and remote share previews without network access',()=>{
 assert.match(html,/<label class="demo-toggle" title="仅展示 Git 库的同步入口、待推送角标和分享格式/);
 assert.match(html,/<div(?=[^>]*class="seg import-tabs")(?=[^>]*aria-label="导入来源")/);
 assert.doesNotMatch(html,/class="[^"]*import-tabs[^"]*hidden"|class="[^"]*hidden[^"]*import-tabs"/);
 assert.match(html,/<button class="icon git-sync-entry hidden" id="gitSyncBtn"/);
 assert.match(html,/id="mobileGitSync" class="hidden git-sync-menu"/);
 assert.match(code,/gitShareDemo=new URLSearchParams\(window.location.search\)\.get\('gitShareDemo'\)==='1'/);
 assert.match(code,/if\(stage==='link'&&gitShareDemo\)previewShare\('link'\)/);
 const syncCode=html.match(/\/\/ v1\.27: Git sync page design[\s\S]*?(?=<\/script>)/)[0];
 assert.match(syncCode,/never touches git, remote or tokens/);
 const local=fixture();
 assert(local.get('gitSyncBtn').classList.contains('hidden'));
 assert(local.get('mobileGitSync').classList.contains('hidden'));
 local.get('gitShareDemo').checked=true;local.get('gitShareDemo').onchange();
 assert(!local.get('gitSyncBtn').classList.contains('hidden'));
 assert(!local.get('mobileGitSync').classList.contains('hidden'));
 local.run(syncCode);
 assert.equal(local.run("validateGitBranch('bad name')").length>0,true);
 assert.equal(local.run("validateGitBranch('phone-notes')"),'');
 local.run("gitSyncState.clean=true;renderGitSync()");
 assert(local.get('gitSyncBody').innerHTML.includes('本地没有待推送的内容'));
 assert(local.get('gitSyncPush').disabled);
 assert.equal(new URL(local.href()).searchParams.get('gitShareDemo'),'1');
 local.get('shareBtn').onclick();
 assert(!local.get('shareRemoteLink').classList.contains('hidden'));
 local.get('shareRemoteLink').onclick();
 assert(local.get('shareNotice').textContent.includes('未访问远端'));
 assert(!local.get('sharePreview').innerHTML.includes('https://'));
 const restored=fixture(local.href());
 assert.equal(restored.get('gitShareDemo').checked,true);
 assert(!restored.get('gitSyncBtn').classList.contains('hidden'));
 assert(!restored.get('mobileGitSync').classList.contains('hidden'));
});
test('Git sync demo validates branches and renders progress and failure results locally',()=>{
 const f=fixture();
 const syncCode=html.match(/\/\/ v1\.27: Git sync page design[\s\S]*?(?=<\/script>)/)[0];
 f.run(syncCode);
 for(const branch of ['', 'bad name', 'a..b', 'HEAD', '-draft'])assert.notEqual(f.run(`validateGitBranch(${JSON.stringify(branch)})`),'');
 f.run("gitSyncState.editing=true;gitSyncState.draft='main';renderGitSync()");
 assert(f.get('gitSyncBody').innerHTML.includes('这是克隆时跟踪的分支'));
 f.run("gitSyncState.draft='bad name';renderGitSync()");
 assert(f.get('gitSyncBody').innerHTML.includes('aria-invalid=\"true\"'));
 assert.match(f.get('gitSyncBody').innerHTML,/id="gitSyncBranchSave"[^>]*disabled/);
 f.run("gitSyncState.draft='phone-notes';renderGitSync()");
 f.get('gitSyncBranchSave').onclick();
 assert.equal(f.run('gitSyncState.branch'),'phone-notes');
 f.run("gitSyncState.stage='running';gitSyncState.step=1;renderGitSync()");
 assert.match(f.get('gitSyncBody').innerHTML,/<li data-state="done">暂存改动<\/li>/);
 assert.match(f.get('gitSyncBody').innerHTML,/<li data-state="active">提交<\/li>/);
 assert(f.get('gitSyncPush').disabled);
 assert(f.get('gitSyncCancel').disabled);
 f.get('gitSyncDialog').open=true;
 f.run('closeGitSync()');
 assert.equal(f.get('gitSyncDialog').open,true);
 for(const [outcome,expected] of [
  ['ok','已推送到 phone-notes'],
  ['rejected','远端 phone-notes 已有新提交'],
  ['auth','401 / 403'],
  ['network','网络连接失败']
 ]){
  f.run(`gitSyncState.stage='done';gitSyncState.outcome=${JSON.stringify(outcome)};renderGitSync()`);
  assert(f.get('gitSyncBody').innerHTML.includes(expected));
 }
});
test('no-note demo toggle grays out note-scoped controls and restores the selection',()=>{
 const f=fixture();const before=f.run('current');assert.equal(f.get('editTab').disabled,false);assert.equal(f.get('previewTab').disabled,false);assert.equal(f.get('shareBtn').disabled,false);
 f.get('noNoteDemo').checked=true;f.get('noNoteDemo').onchange();
 assert.equal(f.run('current'),null);assert.equal(f.get('editTab').disabled,true);assert.equal(f.get('previewTab').disabled,true);assert.equal(f.get('shareBtn').disabled,true);assert.equal(f.get('noNoteDemo').checked,true);assert.equal(f.get('leftTitle').classList.contains('hidden'),true);
 f.run("openInPane('reading_stream','left')");
 assert.equal(f.get('noNoteDemo').checked,false);assert.equal(f.get('editTab').disabled,false);
 f.get('noNoteDemo').checked=true;f.get('noNoteDemo').onchange();f.get('noNoteDemo').checked=false;f.get('noNoteDemo').onchange();
 assert.equal(f.run('current'),'reading_stream');
});
test('wide dialogs stay inside the application window and phone remains a sheet',()=>{
 const f=fixture();f.run("setViewport('wide')");
 f.get('window').rect={left:100,right:700,top:100,bottom:700,width:600,height:600};
 const dialog=f.get('importVaultDialog');dialog.offsetWidth=300;dialog.offsetHeight=240;
 f.run("positionSheetDialog($('importVaultDialog'))");
 assert.equal(dialog.style.left,'250px');assert(Number.parseInt(dialog.style.top)>=100);
 assert(Number.parseInt(dialog.style.top)+240<=700);assert(!dialog.classList.contains('as-sheet'));
 f.run("setViewport('phone');positionSheetDialog($('importVaultDialog'))");assert(dialog.classList.contains('as-sheet'));
});
test('no-note empty state offers create and search actions',()=>{
 const f=fixture();
 f.get('noNoteDemo').checked=true;f.get('noNoteDemo').onchange();
 const empty=f.get('leftEmpty');
 assert(!empty.classList.contains('hidden'));
 assert(empty.innerHTML.replace(/<[^>]*>/g,'').includes('把空间，留给思考。'));
 assert(empty.innerHTML.includes('新建笔记'));
 assert(empty.innerHTML.includes('搜索笔记'));
 assert(f.get('article').classList.contains('hidden'));
 assert(f.get('editor').classList.contains('hidden'));
 assert.equal(f.get('count').textContent,'');
 assert.equal(f.get('leftTitle').classList.contains('hidden'),true);
 f.get('emptyNewNote').onclick();
 assert(f.get('newEntryDialog').open);
 f.get('cancelNewEntry').onclick();
 assert(!f.get('newEntryDialog').open);
 f.get('emptySearch').onclick();
 assert(f.get('quickSearchDialog').open);
 f.get('closeQuickSearch').onclick();
 f.run("openInPane('reading_stream','left')");
 assert(empty.classList.contains('hidden'));
 assert(!f.get('article').classList.contains('hidden'));
 assert(f.get('count').textContent.includes('字 · 本地样例'));
});
test('closing one pane preserves the other and empty pane survives a URL round trip',()=>{
 const f=fixture();const left=f.run('current');f.run("closePaneNote('right')");assert.equal(f.run('current'),left);assert.equal(f.run('reference'),'');assert.equal(f.run('referenceEnabled'),true);assert(!f.get('rightEmpty').classList.contains('hidden'));assert(f.get('rightEmpty').innerHTML.includes('重新打开'));assert(f.get('rightEmptyNewNote').focused);f.run('syncUrl()');const g=fixture(f.href());assert.equal(g.run('reference'),'');assert.equal(g.run('current'),left);g.run("closePaneNote('left')");assert.equal(g.run('current'),'');assert.equal(g.run('reference'),'');assert.equal(g.run('referenceEnabled'),true);assert(!g.get('leftEmpty').classList.contains('hidden'));assert(g.get('emptyNewNote').focused);
});
test('quick search aggregates filename and content matches without mode tabs',()=>{
 assert(!html.includes('quickNameMode')&&!html.includes('quickContentMode')&&!html.includes('search-mode'));
 assert.match(html,/placeholder="搜索文件名、路径或正文"/);
 const f=fixture();
 f.run('openQuickSearch()');
 assert.equal(f.get('quickSearchLabel').textContent,'最近打开');
 f.run("notes.push({id:'agg_name',vault:'reading',title:'AGGNEEDLE 图解',folder:'',tag:'',text:'正文不含关键词',deleted:false})");
 f.run("notes.push({id:'agg_content',vault:'reading',title:'长文随笔',folder:'随笔',tag:'',text:'这里记录了 AGGNEEDLE 工艺的细节。',deleted:false})");
 f.get('quickSearchInput').value='AGGNEEDLE';
 f.run('renderQuickSearch()');
 assert.equal(f.get('quickSearchLabel').textContent,'搜索结果');
 assert.equal(f.get('quickSearchCount').textContent,'2');
 const results=f.get('quickSearchResults').innerHTML;
 assert(results.indexOf('agg_name')<results.indexOf('agg_content'));
 assert(results.includes('search-excerpt'));
 f.get('quickSearchInput').value='什么都没有的词';
 f.run('renderQuickSearch()');
 assert(!f.get('quickSearchEmpty').classList.contains('hidden'));
 assert.equal(f.get('quickSearchEmpty').textContent,'没有匹配的笔记');
 f.get('quickSearchInput').value='';
 f.run('renderQuickSearch()');
 assert.equal(f.get('quickSearchLabel').textContent,'最近打开');
});
test('URL overrides other browser width preferences and keeps collapsed folders and scroll position',()=>{
 const f=fixture();f.run("folderState['reading/10_写作']=false;$('writingScroll').scrollTop=120;syncUrl()");const storage=new Map([['xt2-prototype-v2-widths',JSON.stringify({nav:.7,content:.2})]]);const g=fixture(f.href(),storage);assert.equal(g.run('widths.nav'),.3333);assert.equal(g.run("folderState['reading/10_写作']"),false);assert.equal(g.get('writingScroll').scrollTop,120);
});

test('reported phone link renders relative sample images when switched from edit to preview',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&preset=phone&rotate=0&theme=light&vault=reading&left=reading_stream&right=reading_reading_journal&active=left&lm=edit&rm=preview&dual=1&focus=0&side=files&nav=0&nw=0.2582&cw=0.5000&view=notes&settings=general&detail=0&history=0&panel=none&scroll_editor=1135');
  const source=f.get('editor').value;assert(source.includes('![长图排版示例](../50_Assets/长图排版示例.svg)'));assert(f.run('editing'));f.get('previewTab').onclick();assert(!f.run('editing'));assert.match(f.get('article').innerHTML,/<img[^>]*src="data:image\/svg\+xml;base64,[^"]+"[^>]*alt="长图排版示例">/);
  // data-md 行内编辑属性会保留原始 markdown，正文文本不得再出现它
  assert(!f.get('article').innerHTML.replace(/ data-md="[^"]*"/g,'').includes('![长图排版示例]'));assert.equal(f.get('editor').value,source);
});
test('right pane and share preview resolve images against their own note folder',()=>{
 const f=fixture();f.run("switchVault('local');openInPane('inbox','left');openInPane('stream','right')");assert.match(f.get('reference').innerHTML,/<img[^>]+alt="长图排版示例">/);f.get('shareBtn').onclick();f.get('shareImage').onclick();assert.match(f.get('sharePreview').innerHTML,/<img[^>]+alt="长图排版示例">/);
 f.run("note(reference).folder='20_样式/子目录';renderReference()");assert(!f.get('reference').innerHTML.includes('<img'));assert(f.get('reference').innerHTML.includes('图片未找到'));assert(!f.get('article').innerHTML.includes('长图排版示例'));
});
test('single-note image preview appends one watermark without changing the source note',()=>{
 const f=fixture();const source=f.get('editor').value;f.get('shareBtn').onclick();f.get('shareImage').onclick();const preview=f.get('sharePreview').innerHTML;
 assert(preview.includes('class="share-watermark">曜石笔记</footer>'));assert.equal((preview.match(/曜石笔记/g)||[]).length,1);assert.equal(f.get('editor').value,source);
 f.get('shareBack').onclick();f.get('shareFile').onclick();assert(!f.get('sharePreview').innerHTML.includes('share-watermark'));assert.equal(f.get('editor').value,source);
});
test('asset lookup handles encoded paths and rejects root escape without reading arbitrary files',()=>{
 const f=fixture();assert.match(f.run("resolvePreviewImage('../50_Assets/%E9%95%BF%E5%9B%BE%E6%8E%92%E7%89%88%E7%A4%BA%E4%BE%8B.svg',note(current))"),/^data:image\/svg\+xml;base64,/);assert.equal(f.run("resolvePreviewImage('../../50_Assets/长图排版示例.svg',note(current))"),'');assert.equal(f.run("resolvePreviewImage('file:///etc/passwd',note(current))"),'');assert.equal(f.run("resolvePreviewImage('%invalid',note(current))"),'');f.run("imageAssets.set('attachments/image-1.png','blob:local')");assert.equal(f.run("resolvePreviewImage('attachments/image-1.png',note(current))"),'blob:local');
});

test('phone navigation pushes the retained workspace and reverses without losing editing state',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&preset=phone&vault=reading&left=reading_stream&right=reading_reading_journal&active=left&lm=edit&nav=0');
 const editor=f.get('editor'),workspace=f.get('noteWorkspace');editor.value='动画中保留的编辑内容';editor.oninput();editor.setSelectionRange(4,7);editor.scrollTop=120;
 assert.equal(f.get('navSidebar').inert,true);assert.equal(workspace.inert,false);
 for(let i=0;i<3;i++){f.get('menu').onclick();assert.equal(f.get('navSidebar').inert,false);assert.equal(workspace.inert,false);assert.equal(f.get('notePanes').inert,true);assert.equal(f.get('menu').attrs['aria-expanded'],'true');f.get('menu').onclick();assert.equal(f.get('navSidebar').inert,true);assert.equal(workspace.inert,false);}
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
 const closed=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&preset=double&dual=1');assert.equal(closed.run('viewport'),'double');assert.equal(closed.get('window').classList.contains('nav-hidden'),true);assert.equal(closed.run('referenceShown()'),true);const open=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&preset=double&dual=1&nav=1');assert.equal(open.get('window').classList.contains('nav-hidden'),false);assert.equal(open.run('referenceShown()'),false);
});

test('frontmatter stays editable but is hidden in both previews and share image',()=>{
 const f=fixture();f.run("openInPane('reading_reading_journal','left');openInPane('reading_reading_journal','right')");const source=f.get('editor').value;assert(source.startsWith('---\n'));for(const id of ['article','reference']){assert(!f.get(id).innerHTML.includes('title:'));assert(!f.get(id).innerHTML.includes('tags:'));assert(f.get(id).innerHTML.includes('读书对话练习</h1>'));}f.get('shareBtn').onclick();f.get('shareImage').onclick();assert(!f.get('sharePreview').innerHTML.includes('title:'));assert.equal(f.get('editor').value,source);const headings=JSON.parse(f.run('JSON.stringify(headingsFor(note(current).text))'));assert.equal(headings[0].offset,source.indexOf('# 读书对话练习'));assert.equal(headings[1].offset,source.indexOf('## 本轮阅读问题'));
});
test('frontmatter handling preserves source offsets and does not strip body or incomplete blocks',()=>{
 const f=fixture();const source='\uFEFF---\r\ntitle: sample\r\n# metadata comment\r\n...\r\n# Heading\r\n\r\n---\r\nBody';f.run('globalThis.fmSource='+JSON.stringify(source));assert.equal(f.run('headingsFor(fmSource).length'),1);assert.equal(f.run('headingsFor(fmSource)[0].offset'),source.indexOf('# Heading'));assert.match(f.run('renderMarkdown(fmSource,true)'),/<hr data-source-start="\d+" data-source-end="\d+">/);assert(!f.run('renderMarkdown(fmSource,true)').includes('metadata comment'));assert(f.run("renderMarkdown('---\\ntitle: unfinished',false)").includes('unfinished'));assert(f.run("renderMarkdown('正文\\n---\\n后文',false)").includes('后文'));assert.equal(f.run("markdownBody('---\\n---\\n# Title').text"),'# Title');
});

test('frontmatter tags render as chips without exposing raw YAML or changing source',()=>{
   const f=fixture();f.run("openInPane('reading_reading_journal','left');openInPane('reading_reading_journal','right')");const source=f.get('editor').value;for(const id of ['article','reference']){assert(f.get(id).innerHTML.includes('aria-label="笔记属性与标签"'));assert(!f.get(id).innerHTML.includes('note-tags-label'));assert(f.get(id).innerHTML.includes('>#样例</span>'));assert(f.get(id).innerHTML.includes('>#阅读</span>'));assert(!f.get(id).innerHTML.includes('tags:'));assert(!f.get(id).innerHTML.includes('title:'));}assert.equal(f.get('editor').value,source);const tags=f.run('frontmatterTags('+JSON.stringify('---\ntags: ["Tag", "nested/tag", "tag", "1984", "y1984"]\n---\n# Note')+')');assert.deepEqual(Array.from(tags),['Tag','nested/tag','y1984']);
});
test('inline tags render outside code and links, keeping nested/unicode tags and numeric text correct',()=>{
  const f=fixture();const rendered=f.run('renderMarkdown('+JSON.stringify('# Heading\n\n#样例 #写作/练习 #1984 #y1984\n\n`#code` [link](https://example.com/#fragment)\n\n```\n#fenced\n```')+',false)');assert(rendered.includes('>#样例</span>'));assert(rendered.includes('>#写作/练习</span>'));assert(rendered.includes('>#y1984</span>'));assert(!rendered.includes('>#1984</span>'));assert(rendered.includes('data-inline="code" data-md="`#code`" data-occ="0">#code</code>'));assert.match(rendered,/<pre data-source-start="\d+" data-source-end="\d+"><code>#fenced<\/code><\/pre>/);assert(!rendered.includes('>#fragment</span>'));
});

test('phone hides redundant pane switching for same note and preserves current edit/preview controls',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&preset=phone&vault=reading&left=reading_stream&right=reading_stream&active=right&lm=edit&rm=preview');assert(f.get('switchPane').classList.contains('hidden'));f.get('switchPane').onclick();assert.equal(f.run('activePane'),'right');f.get('rightEditTab').onclick();assert(f.run('rightEditing'));f.get('rightPreviewTab').onclick();assert(!f.run('rightEditing'));assert(f.get('switchPane').classList.contains('hidden'));
});
test('phone offers document switching only for different notes and labels the destination',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&preset=phone&vault=reading&left=reading_stream&right=reading_reading_journal&active=left&lm=edit&rm=preview');assert(!f.get('switchPane').classList.contains('hidden'));assert(f.get('switchPane').attrs['aria-label'].includes('读书对话练习'));f.get('switchPane').onclick();assert.equal(f.run('activePane'),'right');assert(f.get('switchPane').attrs['aria-label'].includes('基础排版'));assert(f.run('editing'));assert(!f.run('rightEditing'));f.run("openInPane('reading_stream','right')");assert(f.get('switchPane').classList.contains('hidden'));f.run("openInPane('reading_reading_journal','right');setViewport('wide')");assert(f.get('switchPane').classList.contains('hidden'));f.run("setViewport('phone')");assert(!f.get('switchPane').classList.contains('hidden'));f.run("reference='';updatePaneChrome()");assert(f.get('switchPane').classList.contains('hidden'));
});

test('single-screen overflow contains no focus or dual-layout actions, including restored legacy links',()=>{
 const menu=html.match(/<details id="mobileMore"[\s\S]*?<\/details>/)[0];assert(!menu.includes('mobileFocus'));assert(!menu.includes('mobileDual'));assert(menu.includes('mobileShare'));assert(menu.includes('mobileSettings'));assert(menu.includes('switchPane'));const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&preset=phone&vault=reading&left=reading_stream&right=reading_reading_journal&active=left&focus=1');assert.equal(f.run('focused'),false);assert(!f.get('window').classList.contains('focus'));const before=f.run('referenceEnabled');f.run('toggleFocus();toggleReference();previewSameNote()');assert.equal(f.run('focused'),false);assert.equal(f.run('referenceEnabled'),before);
});
test('phone more menu groups actions and updates labels without replacing icons',()=>{
 const menu=html.match(/<details id="mobileMore"[\s\S]*?<\/details>/)[0];
 assert(menu.indexOf('aria-label="当前笔记"')<menu.indexOf('aria-label="快捷编辑模式"'));
 assert(menu.indexOf('aria-label="快捷编辑模式"')<menu.indexOf('aria-label="应用"'));
  assert.equal((menu.match(/class="menu-icon"/g)||[]).length,10);
 assert.match(menu,/class="git-sync-count"/);
 const f=fixture();f.run("setViewport('phone');backlinksPane=activePane;updatePaneChrome()");
 assert.equal(f.get('mobileBacklinksLabel').textContent,'隐藏反链');
 assert.match(f.get('switchPaneLabel').textContent,/切换到笔记/);
 f.run("current='';reference='';updatePaneChrome()");
 assert(f.get('mobileShare').disabled);assert(f.get('mobileBacklinks').disabled);
});

test('workspace more menu shares mode switching and settings across all breakpoints',()=>{
 const topbar=html.match(/<header class="topbar">([\s\S]*?)<\/header>/)[1];
 const menu=html.match(/<details id="mobileMore"[\s\S]*?<\/details>/)[0];
 assert(!topbar.includes('id="settingsBtn"'));
 assert.match(html,/\.topbar>\.mobile-top-more\{display:block\}/);
 assert.match(menu,/role="group" aria-label="快捷编辑模式"/);
 assert(menu.includes('id="quickSimple"')&&menu.includes('id="quickProfessional"')&&menu.includes('id="mobileSettings"'));
 for(const preset of ['phone','double','wide']){
  const f=fixture();f.run(`setViewport('${preset}')`);f.get('mobileMore').open=true;f.get('quickProfessional').onclick();
  assert.equal(f.run('experience'),'professional');assert.equal(f.get('mobileMore').open,false);assert(f.get('mobileMoreTrigger').focused);
  f.get('mobileMore').open=true;f.get('quickSimple').onclick();assert.equal(f.run('experience'),'simple');assert.equal(f.get('mobileMore').open,false);assert(f.get('mobileMoreTrigger').focused);
  f.get('mobileMore').open=true;f.get('mobileSettings').onclick();assert(f.run('settingsOpen'));assert.equal(f.get('mobileMore').open,false);
  f.get('closeSettings').onclick();assert(!f.run('settingsOpen'));assert(f.get('mobileMoreTrigger').focused);
 }
});

test('all six preset/rotation combinations use the effective layout for navigation actions',()=>{
 for(const [preset,rotated,isPhone]of [['phone',false,true],['phone',true,false],['double',false,false],['double',true,false],['wide',false,false],['wide',true,false]]){const f=fixture();f.run('viewportRotated='+rotated+';setViewport('+JSON.stringify(preset)+')');assert.equal(f.run('phone'),isPhone);if(isPhone){assert(!f.run('validReferenceDrag()'));assert(!f.get('leftMore').open);assert(!f.get('rightMore').open);}else{f.run('toggleFocus()');assert(f.run('focused'));f.run('toggleFocus()');assert(!f.run('focused'));}}
 const f=fixture();f.run("setViewport('wide');toggleFocus();$('mobileMore').open=true;setViewport('phone')");assert.equal(f.run('focused'),false);assert(!f.get('window').classList.contains('focus'));f.get('rotateViewport').onclick();assert(!f.run('phone'));assert.equal(f.get('mobileMore').open,true);f.run('applyViewportGeometry()');assert.equal(f.get('mobileMore').open,true); // Workspace menu stays available after leaving the phone layout.
});

test('phone hamburger stays interactive while the pushed note body is inert and can close navigation',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&preset=phone&vault=reading&left=reading_stream&right=reading_reading_journal&nav=0');f.get('menu').onclick();assert(f.get('window').classList.contains('nav-open'));assert.equal(f.get('noteWorkspace').inert,false);assert.equal(f.get('notePanes').inert,true);assert.equal(f.get('noteFooter').inert,true);assert.equal(f.get('mobileMore').inert,true);assert.notEqual(f.get('menu').inert,true);f.get('menu').onclick();assert(!f.get('window').classList.contains('nav-open'));assert.equal(f.get('notePanes').inert,false);assert.equal(f.get('noteFooter').inert,false);assert.equal(f.get('mobileMore').inert,false);assert.equal(f.get('navSidebar').inert,true);
});

test('hamburger toggles the in-focus navigation without exiting focus',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&preset=wide&focus=1&nav=0');
 assert(f.run('focused'));assert(f.get('window').classList.contains('focus'));
 f.get('menu').onclick();
 assert(f.run('focused'));assert(f.get('window').classList.contains('focus'));
 assert(f.run('focusNavigationOpen'));assert(f.get('window').classList.contains('focus-nav'));
 f.get('menu').onclick();
 assert(f.run('focused'));assert(!f.get('window').classList.contains('focus-nav'));
 assert.equal(f.run('focusNavigationOpen'),false);
});

test('focus button icon and accessible label follow mode changes and Escape',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&preset=wide');
 f.run('setFocused(false)');
 assert.match(f.get('focus').innerHTML,/M8 3H3v5/);
 assert.equal(f.get('focus').attrs['aria-pressed'],'false');
 assert.equal(f.get('focus').attrs['aria-label'],'进入专注模式');
 f.get('focus').onclick();
 assert.match(f.get('focus').innerHTML,/M3 8h5V3/);
 assert.equal(f.get('focus').attrs['aria-pressed'],'true');
 assert.equal(f.get('focus').attrs['aria-label'],'退出专注模式');
 assert.equal(f.get('focus').title,'退出专注');
 f.event('document','keydown',{key:'Escape',preventDefault(){}});
 assert.equal(f.run('focused'),false);
 assert.match(f.get('focus').innerHTML,/M8 3H3v5/);
 assert.equal(f.get('focus').attrs['aria-label'],'进入专注模式');
});

test('restored focus state is announced and compact layout reset updates the button',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&preset=double&focus=1');
 assert.equal(f.run('focused'),true);
 assert.match(f.get('focus').innerHTML,/M3 8h5V3/);
 assert.equal(f.get('focus').attrs['aria-pressed'],'true');
 assert.equal(f.get('focus').attrs['aria-label'],'退出专注模式');
 f.run("setViewport('phone')");
 assert.equal(f.run('focused'),false);
 assert.match(f.get('focus').innerHTML,/M8 3H3v5/);
 assert.equal(f.get('focus').attrs['aria-pressed'],'false');
 assert.equal(f.get('focus').attrs['aria-label'],'进入专注模式');
});

test('double-screen focus hamburger keeps the active pane while toggling navigation',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&preset=double&vault=reading&focus=1&nav=0&side=chapters&active=right&left=reading_stream&right=reading_reading_journal');
 assert(f.run('focused'));assert.equal(f.run('activePane'),'right');
 f.get('menu').onclick();
 assert(f.run('focused'));assert(f.get('window').classList.contains('focus-nav'));
 assert.equal(f.run('activePane'),'right');assert.equal(f.run('activeNoteId()'),'reading_reading_journal');
 f.run('setFocused(false)');
 assert.equal(f.run('focusNavigationOpen'),false);assert(!f.get('window').classList.contains('focus-nav'));
});

test('trash is a collapsed bottom folder; delete updates entries without auto-expanding and restore works',()=>{
 const f=fixture();assert.equal(f.get('trashFolder').open,false);assert(f.get('trashList').innerHTML.includes('回收站为空'));f.run("deleteFile('reading_stream')");assert.equal(f.get('trashFolder').open,false);assert(f.get('trashList').innerHTML.includes('基础排版'));assert.equal(f.get('trashCount').textContent,'1');f.get('openTrash').onkeydown({key:'ArrowRight',preventDefault(){}});assert.equal(f.get('trashFolder').open,true);assert(!f.get('trashDialog').open);f.run("trashFolderState[activeVault]=true;restoreFile('reading_stream')");assert(f.get('trashList').innerHTML.includes('回收站为空'));assert.equal(f.get('trashCount').textContent,'');assert.equal(f.get('trashFolder').open,false);f.get('openTrash').onkeydown({key:'ArrowLeft',preventDefault(){}});assert.equal(f.get('trashFolder').open,false);
});

test('trash entry uses a trash icon and only appears for a nonempty current-vault trash',()=>{
 const f=fixture();assert(f.get('trashFolder').classList.contains('hidden'));f.run("deleteFile('reading_stream')");assert(!f.get('trashFolder').classList.contains('hidden'));assert.equal(f.get('trashFolder').open,false);assert(f.get('openTrash').attrs['aria-label'].includes('1'));f.run("switchVault('projects')");assert(f.get('trashFolder').classList.contains('hidden'));f.run("switchVault('reading')");assert(!f.get('trashFolder').classList.contains('hidden'));f.run("trashFolderState[activeVault]=true;restoreFile('reading_stream')");assert(f.get('trashFolder').classList.contains('hidden'));assert.equal(f.get('trashFolder').open,false);const entry=html.match(/<details\b[^>]*id="trashFolder"[\s\S]*?<\/details>/)[0];assert(entry.includes('M4 7h16M9 7V4'));assert(entry.includes('data-empty-trash'));
});

test('preview scaling is pane-local, hides reset at 100 and leaves source/editor unchanged',()=>{
 const f=fixture();const source=f.get('editor').value;f.run("setEditing(false,false);setRightEditing(false,false);setPreviewZoom('left',125)");assert.equal(f.get('article').style['--preview-scale'],1.25);assert.equal(f.get('reference').style['--preview-scale'],1);assert(!f.get('leftZoomReset').classList.contains('hidden'));assert(f.get('rightZoomReset').classList.contains('hidden'));assert.equal(f.get('editor').style['--preview-scale'],undefined);assert.equal(f.get('editor').value,source);f.get('leftZoomReset').onclick();assert.equal(f.run('previewZoom.left'),100);assert(f.get('leftZoomReset').classList.contains('hidden'));f.run('setEditing(true,false)');assert(f.get('leftZoomControls').classList.contains('hidden'));f.run('setEditing(false,false)');assert(!f.get('leftZoomControls').classList.contains('hidden'));
});
test('zoom list and URL restore independent percentages and reject malformed values',()=>{
 const f=fixture();f.get('leftZoom').value='150';f.get('leftZoom').onchange();f.run("setPreviewZoom('right',83);syncUrl()");const g=fixture(f.href());assert.equal(g.run('previewZoom.left'),150);assert.equal(g.run('previewZoom.right'),83);assert(g.get('rightZoom').innerHTML.includes('value="83"'));for(const [value,want]of [['NaN',100],['Infinity',100],['',100],['-1',50],['999',200]]){const h=fixture('file:///repo/index.html?ui=2&experience=professional&lz='+value);assert.equal(h.run('previewZoom.left'),want);}
});
test('two-finger pinch scales only preview and cancellation stops further changes',()=>{
 const f=fixture();f.run('setEditing(false,false)');const scroll=f.get('writingScroll');let prevented=0;const event=d=>({touches:[{clientX:0,clientY:50},{clientX:d,clientY:50}],preventDefault(){prevented++}});scroll.dispatch('touchstart',event(100));scroll.dispatch('touchmove',event(150));assert.equal(f.run('previewZoom.left'),150);assert.equal(f.run('previewZoom.right'),100);assert.equal(prevented,2);scroll.dispatch('touchcancel',{});scroll.dispatch('touchmove',event(200));assert.equal(f.run('previewZoom.left'),150);scroll.dispatch('touchstart',event(100));scroll.dispatch('touchmove',event(1000));assert.equal(f.run('previewZoom.left'),200);scroll.dispatch('touchend',{});f.run('setEditing(true,false)');scroll.dispatch('touchstart',event(100));scroll.dispatch('touchmove',event(50));assert.equal(f.run('previewZoom.left'),200);
});
test('trackpad pinch supports preview zoom but ordinary wheel and editor remain unaffected',()=>{
 const f=fixture();f.run('setRightEditing(false,false)');const scroll=f.get('rightScroll');let prevented=0;const e={ctrlKey:false,deltaY:-10,clientY:80,preventDefault(){prevented++}};scroll.dispatch('wheel',e);assert.equal(f.run('previewZoom.right'),100);scroll.dispatch('wheel',{...e,ctrlKey:true});assert(f.run('previewZoom.right')>100);assert.equal(prevented,1);f.run('setRightEditing(true,false)');const before=f.run('previewZoom.right');scroll.dispatch('wheel',{...e,ctrlKey:true});assert.equal(f.run('previewZoom.right'),before);assert.equal(prevented,1);
});

test('design header switch previews filled and empty trash without changing notes',()=>{
 const f=fixture();const before=f.run('JSON.stringify(notes)');f.get('trashDemo').checked=true;f.get('trashDemo').onchange();assert(!f.get('trashFolder').classList.contains('hidden'));assert.equal(f.get('trashFolder').open,false);assert.equal(f.get('trashCount').textContent,'2');assert(f.get('trashList').innerHTML.includes('2026 年第四季度产品规划会议纪要与后续行动项（草稿）'));assert(f.get('trashList').innerHTML.includes('…/会议记录/2026 第四季度'));assert(f.get('trashList').innerHTML.includes('根目录'));f.run("syncUrl()");const g=fixture(f.href());assert.equal(g.get('trashDemo').checked,true);assert(!g.get('trashFolder').classList.contains('hidden'));f.get('trashDemo').checked=false;f.get('trashDemo').onchange();assert(f.get('trashFolder').classList.contains('hidden'));assert.equal(f.run('JSON.stringify(notes)'),before);f.run("deleteFile('reading_stream')");assert(f.get('trashDemo').checked);assert(f.get('trashList').innerHTML.includes('基础排版'));f.get('trashDemo').checked=false;f.get('trashDemo').onchange();assert(f.get('trashFolder').classList.contains('hidden'));assert.equal(f.run("notes.find(n=>n.id==='reading_stream').deleted"),true);
});

test('trash restore uses an icon button with accessible note name and tooltip',()=>{
 const f=fixture();f.get('trashDemo').checked=true;f.get('trashDemo').onchange();for(const id of ['trashList','trashItems']){const button=f.get(id).innerHTML.match(/<button[^>]*data-restore="demo-trash"[\s\S]*?<\/button>/)[0];assert(button.includes('class="icon"'));assert(button.includes('title="恢复到原位置：阅读笔记 / 10_写作/会议记录/2026 第四季度"'));assert(button.includes('aria-label="恢复 2026 年第四季度产品规划会议纪要与后续行动项（草稿） 到 阅读笔记 / 10_写作/会议记录/2026 第四季度"'));assert(button.includes('<svg'));assert(!button.includes('>恢复<'));}f.run("restoreFile('demo-trash-2')");assert(f.get('trashFolder').classList.contains('hidden'));
});

test('trash shows original location and restores the same note there without overwriting conflicts',()=>{
  const f=fixture();const before=f.run("JSON.stringify(notes.find(n=>n.id==='reading_stream'))");f.run("deleteFile('reading_stream')");assert(f.get('trashList').innerHTML.includes('原位置：阅读笔记 / 10_写作'));f.run("restoreFile('reading_stream')");assert.equal(f.run("JSON.stringify(notes.find(n=>n.id==='reading_stream'))"),before);f.run("deleteFile('reading_stream');notes.push({...note('reading_stream'),id:'conflict',deleted:false});restoreFile('reading_stream')");assert(f.run("note('reading_stream').deleted"));assert.equal(f.run("notes.find(n=>n.id==='conflict').deleted"),false);
});

test('trash rows offer an accessible permanent delete that requires confirmation and purges without undo',()=>{
  const f=fixture();f.get('trashDemo').checked=true;f.get('trashDemo').onchange();
  for(const id of ['trashList','trashItems']){const button=f.get(id).innerHTML.match(/<button[^>]*data-purge="demo-trash"[\s\S]*?<\/button>/)[0];assert(button.includes('class="icon"'));assert(button.includes('title="永久删除（不可恢复）"'));assert(button.includes('aria-label="永久删除 2026 年第四季度产品规划会议纪要与后续行动项（草稿）"'));assert(button.includes('<svg'));}
  f.run("askPurgeTrash('demo-trash')");
  assert.equal(f.get('trashDeleteDialog').open,true);
  assert(f.get('trashDeleteBody').textContent.includes('2026 年第四季度产品规划会议纪要与后续行动项（草稿）'));
  assert(f.get('trashDeleteBody').textContent.includes('原位置：…/会议记录/2026 第四季度'));
  assert(f.get('trashList').innerHTML.includes('data-restore')); // 未确认前列表不变
  f.get('cancelTrashDelete').onclick();
  assert.equal(f.get('trashDeleteDialog').open,false);assert.equal(f.run('trashDemo'),true);assert(f.get('trashList').innerHTML.includes('data-purge="demo-trash"'));
  f.run("askPurgeTrash('demo-trash')");f.get('confirmTrashDelete').onclick();
  assert.equal(f.get('trashDeleteDialog').open,false);assert.equal(f.run('trashDemo'),false);
  assert(f.get('trashList').innerHTML.includes('回收站为空'));assert.equal(f.get('trashCount').textContent,'');
  assert.equal(f.get('toastText').textContent,'已永久删除：2026 年第四季度产品规划会议纪要与后续行动项（草稿）');
});

test('permanent delete removes a real deleted note from the list and later restore is a no-op',()=>{
  const f=fixture();f.run("deleteFile('reading_stream')");
  assert(f.get('trashList').innerHTML.includes('data-purge="reading_stream"'));
  f.run("askPurgeTrash('reading_stream')");f.get('confirmTrashDelete').onclick();
  assert.equal(f.run("notes.some(n=>n.id==='reading_stream')"),false);
  assert(f.get('trashList').innerHTML.includes('回收站为空'));
  f.run("restoreFile('reading_stream')"); // 已清除：恢复为无操作，不复活条目
  assert.equal(f.run("notes.some(n=>n.id==='reading_stream')"),false);
  assert(f.get('trashList').innerHTML.includes('回收站为空'));
  assert.match(code,/if\(\$\('shareDialog'\)\.open\|\|\$\('fileActionDialog'\)\.open\|\|\$\('trashDialog'\)\.open\|\|\$\('trashDeleteDialog'\)\.open\)return;/);
  assert(code.includes("'trashDeleteDialog','vaultActionDialog'")); // sheetDialogIds 注册
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
test('open panel stays clamped inside its pane while rotation moves its anchor out of view',()=>{
 const f=fixture();f.run("setRightEditing(true,false)");formatGeometry(f,'right',{left:900,top:820,width:48,height:48},{left:600,top:100,width:300,height:700});f.run("openFormat('right')");const panel=f.get('formatDialog');assert(panel.open);
 formatGeometry(f,'right',{left:930,top:820,width:48,height:48},{left:600,top:200,width:300,height:400});f.run('positionFormatPanel()');assert(panel.open);assert.equal(panel.style.left,'608px');assert.equal(panel.style.top,'208px');assert.equal(panel.style.maxHeight,'384px');assert.equal(panel.dataset.placement,'above');
 formatGeometry(f,'right',{left:900,top:40,width:48,height:48},{left:600,top:200,width:300,height:400});f.run('positionFormatPanel()');assert(panel.open);assert.equal(panel.style.left,'608px');assert.equal(panel.style.top,'208px');assert.equal(panel.dataset.placement,'below');
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
test('open Aa panel stays within its visible pane while phone navigation pushes and returns the workspace',()=>{
 const f=fixture();f.run("setViewport('phone');setEditing(true,false);$('window').classList.remove('nav-open')");
 f.get('window').rect={left:0,right:380,top:0,bottom:780,width:380,height:780};
 f.get('leftPane').rect={left:0,right:380,top:0,bottom:780,width:380,height:780};
 f.get('formatBtn').rect={left:100,right:148,top:700,bottom:748,width:48,height:48};
 f.run("window.visualViewport={offsetLeft:0,offsetTop:0,width:380,height:780};openFormat('left')");
 const panel=f.get('formatDialog');assert(panel.open);assert.equal(panel.style.width,'360px');assert.equal(panel.classList.contains('compact'),false);
 f.get('window').rect={left:300,right:680,top:0,bottom:780,width:380,height:780};
 f.get('leftPane').rect={left:300,right:680,top:0,bottom:780,width:380,height:780};
 f.get('formatBtn').rect={left:400,right:448,top:700,bottom:748,width:48,height:48};
 f.event('document','pointerdown',{target:f.get('menu')});f.get('menu').onclick();assert(f.get('window').classList.contains('nav-open'));
 assert(panel.open);assert.equal(f.run('formatTarget.pane'),'left');assert.equal(panel.style.width,'64px');assert.equal(panel.style.left,'308px');assert.equal(panel.classList.contains('compact'),true);assert(f.get('formatFollowDemo').checked);
 f.get('window').rect={left:0,right:380,top:0,bottom:780,width:380,height:780};
 f.get('leftPane').rect={left:0,right:380,top:0,bottom:780,width:380,height:780};
 f.get('formatBtn').rect={left:100,right:148,top:700,bottom:748,width:48,height:48};
 f.event('document','pointerdown',{target:f.get('menu')});f.get('menu').onclick();assert(!f.get('window').classList.contains('nav-open'));
 assert(panel.open);assert.equal(panel.style.width,'360px');assert.equal(panel.classList.contains('compact'),false);assert(f.get('formatFollowDemo').checked);
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
  // frontmatter 的笔记属性入口块也带 0..frontmatterEnd 的源区间
  assert.deepEqual(ranges,[[0,source.indexOf('# 同名')],[source.indexOf('# 同名'),source.indexOf('# 同名')+4],[source.indexOf('# 同名',source.indexOf('# 同名')+1),source.indexOf('# 同名',source.indexOf('# 同名')+1)+4],[source.indexOf('~~~js'),source.indexOf('~~~\r\n正文')+3],[source.indexOf('正文'),source.indexOf('正文')+2]]);
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
  f.run('document').querySelectorAll=selector=>selector==='[data-file-wrap],[data-folder-wrap]'?[wrap]:[];f.run('document').activeElement=action;f.event('document','keydown',{key:'Escape'});
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

test('import library switches sources and associates a demo directory with safe removal semantics',()=>{
 const f=fixture();f.get('importVaultMenu').onclick();assert(f.get('importVaultDialog').open);assert(f.get('confirmImportVault').disabled);f.get('chooseImportDirectory').onclick();assert(!f.get('confirmImportVault').disabled);f.get('importGitTab').onclick();assert(f.get('confirmImportVault').disabled);assert(f.get('importLocalPanel').classList.contains('hidden'));f.get('importLocalTab').onclick();assert(!f.get('confirmImportVault').disabled);f.get('confirmImportVault').onclick();assert(!f.get('importVaultDialog').open);assert.equal(f.run('libraries.find(v=>v.id===activeVault).type'),'external');assert(f.get('vaultCards').innerHTML.includes('本地目录'));assert(f.get('vaultCards').innerHTML.includes('解除关联'));assert(!decodeURIComponent(f.href()).includes('我的 Markdown'));
 f.run("openVaultAction('rename',activeVault)");f.get('vaultActionName').value='目录别名';const id=f.run('activeVault'),dir=f.run('libraries.find(v=>v.id===activeVault).dir');f.get('confirmVaultAction').onclick();assert.equal(f.run('activeVault'),id);assert.equal(f.run('libraries.find(v=>v.id===activeVault).dir'),dir);f.run("openVaultAction('delete',activeVault)");assert(f.get('vaultActionDescription').textContent.includes('原目录和文件全部保留'));f.get('confirmVaultAction').onclick();assert(!f.run('libraries.some(v=>v.type===\'external\')'));
});
test('Git import validates HTTPS URL and adds only demo metadata without storing remote details',()=>{
 const f=fixture();f.run('openImportVault()');f.get('importGitTab').onclick();for(const value of ['oops','http://example.com/user/repo','https://secret@example.com/user/repo','https://example.com']){f.get('importGitUrl').value=value;f.get('importGitUrl').oninput();assert(f.get('confirmImportVault').disabled,value);}f.get('importGitUrl').value='https://example.com/user/demo.git';f.get('importGitUrl').oninput();assert(!f.get('confirmImportVault').disabled);f.get('confirmImportVault').onclick();assert.equal(f.run('libraries.find(v=>v.id===activeVault).type'),'git');assert.equal(f.run('libraries.find(v=>v.id===activeVault).name'),'demo');assert(!f.href().includes('example.com'));f.run("openVaultAction('delete',activeVault)");assert(f.get('vaultActionDescription').textContent.includes('远端仓库不受影响'));f.run('openImportVault()');f.event('document','keydown',{key:'Escape',preventDefault(){}});assert(!f.get('importVaultDialog').open);
});
test('Git import credential demo switches provider hints and clears secrets on close',()=>{
 const f=fixture();f.run('openImportVault()');f.get('importGitTab').onclick();f.get('importGitUrl').value='https://github.com/user/repo';f.get('importGitUrl').oninput();assert(f.get('importGitUserRow').classList.contains('hidden'));f.get('importGitUrl').value='https://gitee.com/user/repo';f.get('importGitUrl').oninput();assert(!f.get('importGitUserRow').classList.contains('hidden'));f.get('importGitToken').type='password';f.get('importGitToken').value='synthetic-secret';f.get('importGitUser').value='synthetic-user';f.get('importGitTokenToggle').onclick();assert.equal(f.get('importGitToken').type,'text');assert(!f.href().includes('synthetic-secret'));f.get('importVaultDialog').dispatch('close',{});assert.equal(f.get('importGitToken').value,'');assert.equal(f.get('importGitUser').value,'');assert.equal(f.get('importGitToken').type,'password');
});
test('v1.24 import prototype retains directory IDs and covers card states with a discoverable retry',()=>{
 for(const id of ['importVaultDialog','importVaultTitle','importVaultLead','importLocalTab','importGitTab','importLocalPanel','importGitPanel','chooseImportDirectory','importDirectoryName','importDirectoryHint','importDirectoryAction','importDirectoryIcon','importVaultStatus','importFailDemo','cancelImportVault','confirmImportVault'])assert(markupIds.has(id),id);
 assert.match(html,/<dialog(?=[^>]*id="importVaultDialog")(?=[^>]*aria-labelledby="importVaultTitle")(?=[^>]*aria-describedby="importVaultLead")/);
 assert.match(html,/<button(?=[^>]*id="chooseImportDirectory")(?=[^>]*aria-describedby="importDirectoryHint")/);
 assert.match(html,/<span(?=[^>]*id="importDirectoryAction")(?=[^>]*class="directory-action")(?=[^>]*aria-hidden="true")/);
 assert.match(html,/<span(?=[^>]*id="importVaultStatus")(?=[^>]*role="status")/);
 const f=fixture();f.get('importVaultMenu').onclick();
 const card=f.get('chooseImportDirectory');
 assert(f.get('importVaultDialog').open);assert.equal(card.focused,true);assert.equal(card.dataset.state,'empty');assert.equal(card.dataset.selected,'false');
 assert.equal(f.get('importDirectoryName').textContent,'选择笔记目录');assert.equal(f.get('importDirectoryAction').textContent,'选择');assert(f.get('confirmImportVault').disabled);
 f.get('importFailDemo').onclick();
 assert.equal(card.dataset.state,'error');assert.equal(f.get('importDirectoryName').textContent,'未获得目录授权');assert.equal(f.get('importDirectoryAction').textContent,'重试');
 assert.match(f.get('importVaultStatus').textContent,/未登记知识库/);assert(f.get('confirmImportVault').disabled);assert.equal(card.focused,true);
 card.onclick();
 assert.equal(card.dataset.state,'selected');assert.equal(card.dataset.selected,'true');assert.equal(f.get('importDirectoryAction').textContent,'更换');assert.equal(f.get('confirmImportVault').disabled,false);
});

test('first launch and missing or invalid mode choose simple; explicit professional remains available',()=>{
 for(const href of ['file:///repo/docs/prototype/v2/index.html','file:///repo/docs/prototype/v2/index.html?ui=2','file:///repo/docs/prototype/v2/index.html?ui=2&experience=invalid']){
  const f=fixture(href);assert.equal(f.run('experience'),'simple');assert.equal(f.run('referenceShown()'),false);assert(f.get('experienceSimple').checked);assert(f.get('window').classList.contains('simple-mode'));
 }
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&dual=1');assert.equal(f.run('experience'),'professional');assert(f.get('experienceProfessional').checked);assert.equal(f.run('referenceShown()'),true);
 const simpleDual=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=simple&preset=wide&dual=1');assert.equal(simpleDual.run('experience'),'simple');assert.equal(simpleDual.run('referenceShown()'),true);
});

test('simple split and focus controls change layout without changing editing mode',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=simple&preset=wide&dual=0&vault=reading&left=reading_stream&right=reading_reading_journal&active=left');
 assert.equal(f.run('experience'),'simple');assert.equal(f.run('referenceShown()'),false);
 f.get('showRef').onclick();
 assert.equal(f.run('experience'),'simple');assert.equal(f.run('referenceShown()'),true);
 assert(f.get('focus').classList.contains('hidden')===false);
 f.get('focus').onclick();
 assert(f.run('focused'));assert.equal(f.run('experience'),'simple');
 f.get('focus').onclick();
 assert(!f.run('focused'));assert.equal(f.run('experience'),'simple');assert.equal(f.run('referenceShown()'),true);
});

test('switching to simple mode preserves the open split layout',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&preset=wide&dual=1&vault=reading&left=reading_stream&right=reading_reading_journal&active=left');
 f.run("changeExperience('simple')");
 assert.equal(f.run('experience'),'simple');assert.equal(f.run('referenceShown()'),true);
 f.run("changeExperience('professional')");
 assert.equal(f.run('experience'),'professional');assert.equal(f.run('referenceShown()'),true);
});

test('prototype hides paragraph block IDs in preview while preserving source and ordinary carets',()=>{
 const f=fixture();
 const source='正文 ^demo-paragraph';
 f.run('globalThis.blockIdSource='+JSON.stringify(source));
 const rendered=f.run('renderMarkdown(blockIdSource,false)');
 assert.match(rendered, /data-block-id="demo-paragraph"/);
 assert.match(rendered, />正文<\/p>/);
 assert(!rendered.includes('^demo-paragraph'));
 assert.equal(f.run('blockIdSource'), source);
 assert.match(f.run('renderMarkdown('+JSON.stringify('普通 ^ 符号')+',false)'), />普通 \^ 符号<\/p>/);
 assert.match(f.run('renderMarkdown('+JSON.stringify('普通段落')+',false)'), />普通段落<\/p>/);
});

test('prototype renders common Markdown and preserves simple list prefixes',()=>{
 const f=fixture();
 const rendered=f.run('renderMarkdown("~~old~~\\n\\n3. first\\n  - child\\n\\n| a | b |\\n| --- | --- |\\n| c | d |",false)');
 assert.match(rendered,/<del>old<\/del>/);
 assert.match(rendered,/<ol start="3">/);
 assert.match(rendered,/<li data-depth="1"/);
 assert.match(rendered,/<table class="simple-table md-table" data-block-type="table" data-table-valid="true" data-source-start="\d+" data-source-end="\d+"/);
 assert.match(rendered,/<th[^>]*>a<\/th><th[^>]*>b<\/th>/);
 assert.equal(f.run('simplePrefix("  - child")'),'  - ');
 assert.equal(f.run('simplePrefix("3. first")'),'3. ');
 assert.equal(f.run('simpleBlockAllowed("~~old~~")'),false);
});

test('v1.14 prototype maps table cells and keeps complex or malformed cells read-only',()=>{
 const f=fixture(),source='before\n\n| 名称 | 内容 |\n| --- | --- |\n| A\\|B | **加粗** |\n| [链接](https://example.test) | 普通文本 |\n\nafter';
 const rendered=f.run('renderMarkdown('+JSON.stringify(source)+',false)');
 const cellFrom=source.indexOf('A\\|B');
 assert.match(rendered,/data-table-valid="true"/);
 assert.ok(rendered.includes('data-cell-source-from="'+cellFrom+'" data-cell-source-to="'+(cellFrom+4)+'"'));
 assert.match(rendered,/<td[^>]*data-simple-table-editable="true"[^>]*>A\|B<\/td>/);
 assert.match(rendered,/<td[^>]*data-simple-table-editable="false"[^>]*>.*?>链接<\/a><\/td>/);
 assert.match(rendered,/复杂单元格请在专业模式编辑/);
 const malformed=f.run('renderMarkdown("| a | b |\\n| c | d |",false)');
 assert.match(malformed,/data-table-valid="false"/);
 assert.match(malformed,/表格结构不规范，请在专业模式编辑/);
 assert.match(malformed,/data-simple-table-editable="false"/);
 assert.match(code,/navigateSimpleTableCell/);
 assert.match(code,/commitSimpleTableCell/);
});

test('unknown colon containers stay read-only and route nested clicks to the whole-block source drawer',()=>{
 const f=fixture(),source=':::custom\n[链接](https://example.test)\n\n| 标题 | 值 |\n| --- | --- |\n| a | b |\n:::';
 const rendered=f.run('renderMarkdown('+JSON.stringify(source)+',true)');
 assert.match(rendered,/class="md-unknown-colon" data-source-start="0" data-source-end="[^"]+"/);
 assert.match(rendered,/data-simple-table-editable="false"/);
 assert.doesNotMatch(rendered,/data-simple-table-editable="true"/);

 f.get('article').contains=()=>true;
 f.run("experience='simple';openComplexFor=(target)=>{window.__directiveTarget=target};annotateComplexBlocks('left')");
 const directive={matches:selector=>selector==='.md-unknown-colon'};
 const inline={matches:selector=>selector==='[data-inline]'};
 const target={closest:selector=>selector==='.md-unknown-colon'?directive:
  selector==='.block-chip,.block-copy,[data-inline],.md-props-entry,.md-callout-head,.md-math,.cb-para'?inline:null};
 let prevented=false,stopped=false;
 f.get('article').listeners.click.at(-1)({
  target,
  preventDefault(){prevented=true},
  stopPropagation(){stopped=true}
 });
 assert(prevented&&stopped);
 assert.equal(f.run('window.__directiveTarget'),directive);
});

test('update-check prototype covers outcomes, disables repeat checks, and leaves the system dialog external',()=>{
 const f=fixture();
 const aboutInsert=f.get('aboutHero').insertions[0];
 const demoInsert=f.get('designControls').insertions[0];
 assert.equal(aboutInsert.position,'afterend');
 assert.match(aboutInsert.markup,/id="updateCheckButton"/);
 assert.match(demoInsert.markup,/只切换界面演示状态，不发起联网请求/);
 const demo=f.get('updateCheckDemo'),button=f.get('updateCheckButton');
 demo.value='latest';button.onclick();
 assert.equal(f.get('updateCheckGroup').dataset.state,'checking');
 assert.equal(button.disabled,true);
 f.flush();
 assert.equal(f.get('updateCheckGroup').dataset.state,'latest');
 assert.equal(button.disabled,false);
 assert.match(f.get('updateCheckStatus').textContent,/当前没有可用更新/);
 demo.value='available';demo.onchange();
 assert.equal(f.get('updateCheckGroup').dataset.state,'available');
 assert.equal(f.get('updateCheckHandoff').classList.contains('hidden'),false);
 assert.match(aboutInsert.markup,/系统升级弹框接管；弹框由系统显示/);
 assert.doesNotMatch(f.get('updateCheckStatus').textContent,/\b\d+\.\d+\.\d+\b/);
 for(const [state,message] of [
  ['network','网络不可用'],
  ['background','不在前台'],
  ['privacy','隐私协议'],
  ['limited','上次检查']
 ]){
  demo.value=state;demo.onchange();
  assert.equal(f.get('updateCheckGroup').dataset.state,state);
  assert.match(f.get('updateCheckStatus').textContent,new RegExp(message));
  assert.equal(button.disabled,false);
 }
 demo.value='checking';demo.onchange();
 assert.equal(button.disabled,true);
 assert.match(f.get('updateCheckStatus').textContent,/正在检查/);
 for(const preset of ['phone','double','wide']){
  const layout=fixture();
  layout.run(`setViewport('${preset}');openSettings();chooseSettings('about',false)`);
  layout.get('updateCheckDemo').value='available';
  layout.get('updateCheckDemo').onchange();
  assert.equal(layout.run('viewportPreset'),preset);
  assert.equal(layout.get('updateCheckGroup').dataset.state,'available');
 }
});

test('v1.58 58.10: view=stats URL 复现打开写作统计弹窗，热力图 7×12、下一个成就唯一、关闭返还焦点',()=>{
 const f=fixture('file:///repo/docs/prototype/v2/index.html?ui=2&experience=professional&vault=reading&left=reading_stream&right=reading_reading_journal&view=stats');
 assert.equal(f.get('statsDialog').open,true,'restoreUrl 的 view=stats 必须打开统计弹窗');
 assert.equal(f.run('vaultStatsOpen'),true);
 assert.equal((f.get('statsHeat').innerHTML.match(/<i class=/g)||[]).length,84,'热力图 84 格');
 assert.match(f.get('statsHeat').innerHTML,/grid-column:13/,'第 12 周落在最后一列');
 const medals=f.get('statsBadges').innerHTML;
 assert.equal((medals.match(/<div class="stats-medal/g)||[]).length,8);
 assert.equal((medals.match(/--p:/g)||[]).length,1,'只有一枚「下一个」显示圆环');
 f.run("document.contains=()=>true;statsReturnFocus=$('mobileMoreTrigger')");
 f.get('closeVaultStats').onclick();
 assert.equal(f.get('statsDialog').open,false);
 assert.equal(f.run('vaultStatsOpen'),false);
 assert.equal(f.get('mobileMoreTrigger').focused,true,'关闭后焦点回到更多按钮');
});


function appBackupFixture(){const f=fixture();f.run(html.match(/\/\/ v1\.66: design-only application backup[\s\S]*?(?=<\/script>)/)[0]);return f;}
test('v1.66 app export previews all vaults and completes without modifying samples',()=>{
 const f=appBackupFixture();const before=f.run('JSON.stringify({libraries,notes})');
 f.get('exportAppBackup').onclick();assert(f.get('appBackupDialog').open);
 assert.equal(f.run('appBackupMode'),'export');assert.match(f.get('appBackupSummary').textContent,/3 个知识库/);
 assert.match(f.get('appBackupVaultNames').textContent,/本地笔记.*阅读笔记.*项目笔记/);
 f.get('appBackupPrimary').onclick();assert.equal(f.run('appBackupStep'),'working');
 assert(f.get('appBackupPrimary').disabled);assert(f.get('closeAppBackup').disabled);
 f.flush();assert.equal(f.run('appBackupStep'),'done');
 assert.match(f.get('appBackupDoneCopy').textContent,/保存位置后才算完成/);
 assert.equal(f.run('JSON.stringify({libraries,notes})'),before);
});
test('v1.66 restore requires file review and separate acknowledged replacement confirmation',()=>{
 const f=appBackupFixture();const before=f.run('JSON.stringify({libraries,notes})');
 f.get('restoreAppBackup').onclick();assert.equal(f.run('appBackupStep'),'choose');assert(f.get('appBackupPrimary').disabled);
 f.get('chooseAppBackupFile').onclick();assert.equal(f.run('appBackupStep'),'review');
 f.get('appBackupPrimary').onclick();assert.equal(f.run('appBackupStep'),'confirm');assert(f.get('appBackupPrimary').disabled);
 f.get('appBackupPrimary').onclick();assert.equal(f.run('appBackupStep'),'confirm');
 f.get('ackAppBackupReplace').checked=true;f.get('ackAppBackupReplace').onchange();assert(!f.get('appBackupPrimary').disabled);
 f.get('appBackupPrimary').onclick();f.flush();assert.equal(f.run('appBackupStep'),'done');
 assert.equal(f.run('JSON.stringify({libraries,notes})'),before,'prototype must not replace sample data');
});
test('v1.66 corrupt, future and failed restore states preserve data and allow retry',()=>{
 for(const scenario of ['corrupt','future','failed']){
  const f=appBackupFixture();const before=f.run('JSON.stringify({libraries,notes})');
  f.run("appBackupScenario='"+scenario+"';openAppBackup('import')");f.get('chooseAppBackupFile').onclick();
  if(scenario==='failed'){f.get('appBackupPrimary').onclick();f.get('ackAppBackupReplace').checked=true;f.get('ackAppBackupReplace').onchange();f.get('appBackupPrimary').onclick();f.flush();}
  assert.equal(f.run('appBackupStep'),'error');assert(f.get('appBackupPrimary').disabled===false);
  assert.match(f.get('appBackupErrorCopy').textContent,scenario==='corrupt'?/清单/:scenario==='future'?/升级/:/空间不足/);
  assert.equal(f.run('JSON.stringify({libraries,notes})'),before);
  f.get('appBackupPrimary').onclick();assert.equal(f.run('appBackupStep'),'choose');assert(f.get('appBackupPrimary').disabled);
 }
});
test('v1.66 cancel and Escape close backup before settings and restore the trigger focus',()=>{
 for(const preset of ['phone','double','wide']){
  const f=appBackupFixture();f.run("setViewport('"+preset+"');openSettings();chooseSettings('data',false);openAppBackup('import')");
  let prevented=false;f.event('document','keydown',{key:'Escape',preventDefault(){prevented=true}});
  assert(prevented);assert(!f.get('appBackupDialog').open);assert.equal(f.run('settingsOpen'),true);assert(f.get('restoreAppBackup').focused);
 }
});
