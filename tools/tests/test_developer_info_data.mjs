import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

const root = new URL('../../', import.meta.url);
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

test('native about card shows the generated feedback email without a developer name', () => {
  assert.equal(generatedString(nativeConfig, 'DEVELOPER_NAME'), config.developerName);
  assert.equal(generatedString(nativeConfig, 'FEEDBACK_EMAIL'), config.feedbackEmail);
  assert.match(nativeSettings, /import \{ FEEDBACK_EMAIL \} from '\.\.\/model\/AppConfig';/);
  assert.match(nativeSettings, /Span\('反馈邮箱 '\)[\s\S]*Span\(FEEDBACK_EMAIL\)/);
  assert.doesNotMatch(nativeSettings, /DEVELOPER_NAME|应用由\s*开发/);
});

test('v2 about card shows the generated feedback email and does not render a developer name', () => {
  const settings = prototypeSettingsData();
  assert.equal(settings.developerName, config.developerName);
  assert.equal(settings.feedbackEmail, config.feedbackEmail);
  assert.match(prototype, /反馈邮箱<\/span>[\s\S]*?<a id="aboutContactEmail"/);
  assert.doesNotMatch(prototype, /id="settingsDeveloper"|textContent=settingsData\.developerName/);
  assert.match(prototype, /id="aboutContactEmail"/);
  assert.match(prototype, /\$\('aboutContactEmail'\)\.textContent=settingsData\.feedbackEmail/);
});
