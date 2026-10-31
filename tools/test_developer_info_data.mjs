import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

const root = new URL('../', import.meta.url);
const read = (path) => readSourceFile(new URL(path, root));
const config = JSON.parse(read('app_config.json'));
const nativeConfig = read('entry/src/main/ets/model/AppConfig.ets');
const nativeSettings = read('entry/src/main/ets/components/SettingsView.ets');
const prototype = read('docs/prototype/v2/index.html');

function generatedString(source, name) {
  const match = source.match(new RegExp(`export const ${name}: string = (.+);`));
  assert.ok(match, `${name} must be generated in AppConfig.ets`);
  return JSON.parse(match[1]);
}

function prototypeSettingsData() {
  const line = prototype.split('\n').find((item) => item.startsWith('const settingsData = '));
  assert.ok(line, 'v2 prototype must contain generated settings data');
  return JSON.parse(line.slice('const settingsData = '.length).replace(/;$/, ''));
}

test('native about card uses generated developer and feedback configuration', () => {
  assert.equal(generatedString(nativeConfig, 'DEVELOPER_NAME'), config.developerName);
  assert.equal(generatedString(nativeConfig, 'FEEDBACK_EMAIL'), config.feedbackEmail);
  assert.match(nativeSettings, /import \{ FEEDBACK_EMAIL, DEVELOPER_NAME \} from '\.\.\/model\/AppConfig';/);
  assert.match(nativeSettings, /Span\('应用由 '\)[\s\S]*Span\(DEVELOPER_NAME\)[\s\S]*Span\(' 开发，联系方式 '\)[\s\S]*Span\(FEEDBACK_EMAIL\)/);
});

test('v2 about card uses generated settings data for the developer and email', () => {
  const settings = prototypeSettingsData();
  assert.equal(settings.developerName, config.developerName);
  assert.equal(settings.feedbackEmail, config.feedbackEmail);
  assert.match(prototype, /应用由 <strong id="settingsDeveloper"><\/strong> 开发，联系方式 <a id="aboutContactEmail"><\/a>/);
  assert.match(prototype, /id="settingsDeveloper"/);
  assert.match(prototype, /id="aboutContactEmail"/);
  assert.match(prototype, /\$\('settingsDeveloper'\)\.textContent=settingsData\.developerName/);
  assert.match(prototype, /\$\('aboutContactEmail'\)\.textContent=settingsData\.feedbackEmail/);
});
