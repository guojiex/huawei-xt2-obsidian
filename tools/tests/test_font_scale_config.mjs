/**
 * v1.10 基础无障碍 —— 系统字号 followSystem 配置回归。
 *
 * 依据 api_notes.md AA1/AA2（2026-11-07 官方问答）：
 *  - 应用字体默认**不**跟随系统字号；必须在
 *    AppScope/resources/base/profile/configuration.json 写
 *    "fontSizeScale": "followSystem"，并在 AppScope/app.json5 用
 *    "configuration": "$profile:configuration" 引用，fp 字号才跟随缩放。
 *  - 应用级钳制上限 fontSizeMaxScale 取适老化指南建议值 "1.75"
 *    （schema 枚举见 SDK toolchains/modulecheck/configuration.json）。
 *  - EntryAbility 用 systemConfiguration.UpdatedCallback 的
 *    onFontSizeScaleUpdated（since 24）打校准日志，不做布局计算。
 *
 * 删掉或改掉这些配置会让系统字号缩放整体失效（设置里拖滑条应用毫无反应），
 * 所以用源码断言钉住。
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

test('configuration.json enables followSystem font scaling with the 1.75 cap', () => {
  const path = resolve(repoRoot, 'AppScope/resources/base/profile/configuration.json');
  const config = JSON.parse(readFileSync(path, 'utf8'));
  assert.equal(config.configuration.fontSizeScale, 'followSystem',
    'fontSizeScale 必须是 followSystem（api_notes AA1）');
  assert.equal(config.configuration.fontSizeMaxScale, '1.75',
    '应用级字号上限取适老化指南建议 1.75（api_notes AA1）');
});

test('app.json5 references the configuration profile', () => {
  const appJson = readFileSync(resolve(repoRoot, 'AppScope/app.json5'), 'utf8');
  assert.ok(/"configuration"\s*:\s*"\$profile:configuration"/.test(appJson),
    'app.json5 缺少 "configuration": "$profile:configuration" 引用，followSystem 不生效');
});

test('fontSizeMaxScale value is allowed by the local SDK schema', () => {
  const schemaPath = 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/modulecheck/configuration.json';
  if (!existsSync(schemaPath)) {
    return; // 非 Windows 宿主跳过：与 test_screen_reader_labels 的 SDK 路径口径一致，此处不新增 Mac 失败
  }
  const schema = JSON.parse(readFileSync(schemaPath, 'utf8'));
  const allowed = schema.properties.configuration.properties.fontSizeMaxScale.enum;
  const config = JSON.parse(
    readFileSync(resolve(repoRoot, 'AppScope/resources/base/profile/configuration.json'), 'utf8'));
  assert.ok(allowed.includes(config.configuration.fontSizeMaxScale),
    `fontSizeMaxScale 取值必须在 SDK schema 枚举内：${allowed.join(' / ')}`);
});

test('EntryAbility observes and logs font scale changes (AA2, since 24)', () => {
  const source = readFileSync(
    resolve(repoRoot, 'entry/src/main/ets/entryability/EntryAbility.ets'), 'utf8');
  assert.ok(/onFontSizeScaleUpdated\?: \(fontSizeScale: number\) => void/.test(source),
    'ColorModeObserver 应声明可选 onFontSizeScaleUpdated 成员（systemConfiguration.UpdatedCallback）');
  assert.ok(/onFontSizeScaleUpdated: \(fontSizeScale: number\): void =>/.test(source),
    'observer 实例应实现 onFontSizeScaleUpdated 回调');
  assert.ok(/启动系统字号缩放 fontSizeScale=/.test(source),
    'onWindowStageCreate 应打一次启动字号缩放日志（供模拟器/真机核对 followSystem 生效）');
});
