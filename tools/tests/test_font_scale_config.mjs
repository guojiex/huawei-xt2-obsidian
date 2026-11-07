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
 *    onFontSizeScaleUpdated（since 24）打校准日志；v1.39 39.2/39.7 起
 *    同时发布 fontSizeScale 到 AppStorage，Index 的分栏下限按
 *    k=clamp(值,1,1.45) 实时重算（只钳制布局，不改写已保存比例）。
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

test('v1.39 39.2/39.7: EntryAbility publishes fontSizeScale to AppStorage and Index consumes it', () => {
  const ability = readFileSync(
    resolve(repoRoot, 'entry/src/main/ets/entryability/EntryAbility.ets'), 'utf8');
  // 回调（前台实时）与启动初始值（loadContent 前首帧正确）两条发布路径都要有。
  assert.ok(/onFontSizeScaleUpdated[\s\S]*?AppStorage\.setOrCreate\('fontSizeScale', fontSizeScale\)/.test(ability),
    'onFontSizeScaleUpdated 回调应发布 fontSizeScale 到 AppStorage（39.3 前台实时生效）');
  assert.ok(/AppStorage\.setOrCreate\('fontSizeScale', startFontSizeScale\)/.test(ability),
    'onWindowStageCreate 应在 loadContent 前发布启动字号，页面首帧拿到正确下限');

  const index = readFileSync(
    resolve(repoRoot, 'entry/src/main/ets/pages/Index.ets'), 'utf8');
  assert.ok(/@StorageProp\('fontSizeScale'\) fontSizeScale: number = 1;/.test(index),
    'Index 应以 @StorageProp 订阅 fontSizeScale（默认 1，EntryAbility 未发布时按标准字号）');
  // 分栏调用点把字号传进 PaneLayout（16 处渲染 / 拖动 / 键盘路径）。
  const passThrough = index.match(/this\.fontSizeScale/g) ?? [];
  assert.ok(passThrough.length >= 15,
    `expected >= 15 fontSizeScale pass-through uses in Index, got ${passThrough.length}`);
});
