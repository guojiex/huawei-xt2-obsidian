import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const html = fs.readFileSync(new URL('../docs/prototype/index.html', import.meta.url), 'utf8');
const source = html.split('/* FEEDBACK_BEGIN */')[1].split('/* FEEDBACK_END */')[0];
function render(email) {
  const nodes = new Map();
  const get = id => { if (!nodes.has(id)) nodes.set(id, {}); return nodes.get(id); };
  vm.runInNewContext(source, {document:{getElementById:get},APP_CONFIG:{feedbackEmail:email},encodeURIComponent});
  return get;
}
test('configured email and encoded subject create mail draft without note content',()=>{
  const get=render('test@example.com');
  assert.equal(get('feedbackEmailAddress').textContent,'test@example.com');
  const uri=new URL(get('feedbackEmailLink').href);
  assert.equal(uri.protocol,'mailto:');assert.equal(uri.pathname,'test@example.com');
  assert.equal(uri.searchParams.get('subject'),'曜石笔记 · 问题与建议');
  assert.equal(uri.searchParams.has('body'),false);
});
test('feedback remains standalone and removes GitHub, diagnostic and unsupported SDK actions',()=>{
  assert.match(html,/id="settings-tab-feedback"[^>]*aria-controls="settings-feedback"/);
  const section=html.split('<section id="settings-feedback"')[1].split('</section>')[0];
  assert.doesNotMatch(section,/github|feedbackDiagnostics|openSystemFeedbackBtn|Feedback Kit/);
  assert.match(section,/邮件应用/);
});
test('generated configuration agrees with source',()=>{
  const sourceConfig=JSON.parse(fs.readFileSync(new URL('../app_config.json', import.meta.url),'utf8'));
  const context={};vm.runInNewContext(html.split('/* APP_CONFIG_BEGIN */')[1].split('/* APP_CONFIG_END */')[0],context);
  assert.equal(context.APP_CONFIG.feedbackEmail,sourceConfig.feedbackEmail);
});
