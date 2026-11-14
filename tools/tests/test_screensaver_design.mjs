/**
 * v1.65 常驻屏保 / 台历页：源级契约测试。
 * 覆盖菜单入口、覆盖层与冷启动隔离、名言轮换与退出、档位持久化、红线。
 * 设备目视（进入 / 退出、轮换、深浅色、三屏布局）不能被本文件替代。
 */
import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { readSourceFile } from './lib/source.mjs';

const index = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const mask = readSourceFile(new URL('../../entry/src/main/ets/components/StartupMask.ets', import.meta.url));
const ambience = readSourceFile(new URL('../../entry/src/main/ets/components/StartupAmbience.ets', import.meta.url));
const settings = readSourceFile(new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url));
const tokens = readSourceFile(new URL('../../entry/src/main/ets/common/Tokens.ets', import.meta.url));
const icons = readSourceFile(new URL('../../entry/src/main/ets/common/Icons.ets', import.meta.url));
const store = readSourceFile(new URL('../../entry/src/main/ets/model/ScreenSaverPreferenceStore.ets', import.meta.url));
const moduleJson5 = readFileSync(new URL('../../entry/src/main/module.json5', import.meta.url), 'utf8');

test('65.1 more menu keeps a permanent screen saver entry before settings', () => {
  assert.match(index, /MobileMoreMenuItem\('screenSaver', 'screenSaver', '屏保 \/ 台历', true/);
  const saverAt = index.indexOf("MobileMoreMenuItem('screenSaver'");
  const settingsAt = index.indexOf("MobileMoreMenuItem('settings'");
  assert.ok(saverAt >= 0 && settingsAt > saverAt, 'screen saver entry must precede settings (group tail)');
  assert.match(index, /private openScreenSaver\(\): void \{/);
  assert.match(index, /this\.screenSaverOpen = true;/);
  // 专用图标：纯直线路径常量 + pathOf 分支，不复用无关图标名
  assert.match(icons, /const P_SCREEN_SAVER: string = /);
  assert.match(icons, /name === 'screenSaver'[\s\S]{0,40}return P_SCREEN_SAVER;/);
});

test('65.2 screen saver is a conditional full-screen overlay; cold-start mask stays untouched', () => {
  assert.match(index, /@State screenSaverOpen: boolean = false;/);
  assert.match(index, /if \(this\.screenSaverOpen\) \{/);
  assert.match(index, /screenSaver: true,/);
  assert.match(index, /ready: false,/);
  assert.match(index, /quoteIntervalMs: this\.screenSaverIntervalMs,/);
  assert.match(index, /onExit: \(\): void => \{ this\.closeScreenSaver\(\); \}/);
  // v1.41 41.4 常驻挂载语句保持原样，屏保不替换冷启动遮罩
  assert.match(index, /StartupMask\(\{ ready: this\.workspaceInitialRenderReady \}\)/);
  const coldAt = index.indexOf('StartupMask({ ready: this.workspaceInitialRenderReady })');
  const saverAt = index.indexOf('if (this.screenSaverOpen)');
  assert.ok(saverAt > coldAt, 'screen saver overlay must be above the cold-start mask in the Stack');
  assert.match(index, /private closeScreenSaver\(\): void \{/);
  assert.match(index, /this\.screenSaverOpen = false;[\s\S]{0,60}this\.topView = 'note';/);
});

test('65.3 StartupMask gains a guarded screen-saver mode with recursive quote rotation', () => {
  // 默认参数保证冷启动路径零回归
  assert.match(mask, /@Prop screenSaver: boolean = false;/);
  assert.match(mask, /@Prop quoteIntervalMs: number = ScreenSaver\.defaultIntervalMs;/);
  assert.match(mask, /onExit: \(\) => void = \(\): void => \{\};/);
  assert.match(mask, /@State private quoteGroupOpacity: number = 1;/);
  assert.match(mask, /\.opacity\(this\.quoteGroupOpacity\)/);
  // ready 永不触发屏保自动淡出
  assert.match(mask, /if \(!this\.ready \|\| this\.exiting \|\| this\.screenSaver\) \{/);
  // 轮换链路：首播延时 → 递归排程 → 淡出/换句/逐字浮现 → 出处淡入
  for (const method of ['applyQuote', 'scheduleRotate', 'rotateQuote', 'revealRotatedQuote',
    'clearRotateTimer', 'clearRotateTimers', 'exitScreenSaver']) {
    assert.match(mask, new RegExp(`private ${method}\\(`), `missing ${method}`);
  }
  assert.match(mask, /this\.scheduleRotate\(ScreenSaver\.firstRotateDelay\);/);
  assert.match(mask, /if \(!this\.screenSaver \|\| this\.saverExiting \|\| this\.quoteIntervalMs <= 0\) \{/);
  assert.match(mask, /const next: number = \(this\.quoteIndex \+ 1\) % QUOTES\.length;/);
  assert.match(mask, /this\.revealRotatedQuote\(\);/);
  assert.match(mask, /this\.scheduleRotate\(this\.quoteIntervalMs\);/);
  assert.equal((mask.match(/setInterval/g) ?? []).length, 0, 'no periodic polling timer');
  // 台历元素与退出提示只在屏保模式显示
  assert.match(mask, /if \(this\.screenSaver\) \{[\s\S]{0,300}Text\(ScreenSaver\.hintText\)/);
  assert.match(mask, /this\.screenSaver \? ScreenSaver\.dateSize : FontSize\.caption/);
  // 动画起播时机（api_notes U4）：aboutToAppear 内不得直接调用动画 API
  const lifecycle = mask.match(/aboutToAppear\(\): void \{([\s\S]*?)\n  \}/);
  assert.ok(lifecycle, 'missing aboutToAppear');
  assert.doesNotMatch(lifecycle[1], /\.(?:keyframe)?[Aa]nimateTo\(/);
});

test('65.4 tapping anywhere fades out, stops loops and clears every timer', () => {
  assert.match(mask, /\.onClick\(\(\): void => \{[\s\S]{0,160}if \(this\.screenSaver\) \{\s*\n\s*this\.exitScreenSaver\(\);/);
  assert.match(mask, /private saverExiting: boolean = false;/);
  assert.match(mask, /if \(!this\.screenSaver \|\| this\.saverExiting\) \{/);
  assert.match(mask, /this\.saverExiting = true;/);
  const exitBody = mask.slice(mask.indexOf('private exitScreenSaver(): void {'));
  assert.match(exitBody, /this\.clearEnterTimers\(\);/);
  assert.match(exitBody, /this\.clearRotateTimers\(\);/);
  assert.match(exitBody, /this\.stopBrandLoops\(\);/);
  assert.match(exitBody, /onFinish: \(\): void => \{\s*\n\s*this\.onExit\(\);/);
  assert.match(exitBody, /duration: Startup\.exitDur,/);
  // 组件销毁时同样清理
  assert.match(mask, /aboutToDisappear\(\): void \{[\s\S]{0,160}this\.clearRotateTimers\(\);/);
  assert.match(mask, /private clearRotateTimers\(\): void \{[\s\S]{0,260}clearTimeout\(this\.rotateTimers\[i\]\);/);
});

test('65.5 quote interval is a persisted app-level preference with a token source of truth', () => {
  assert.match(tokens, /export class ScreenSaver \{/);
  assert.match(tokens, /static readonly defaultIntervalMs: number = 30000;/);
  assert.match(tokens, /static readonly intervalOptions: number\[\] = \[0, 15000, 30000, 60000, 180000, 300000\];/);
  assert.match(tokens, /static readonly intervalLabels: string\[\] = \['不轮换', '15 秒', '30 秒', '1 分钟', '3 分钟', '5 分钟'\];/);
  assert.match(tokens, /static isValidInterval\(ms: number\): boolean \{/);
  assert.match(tokens, /static readonly firstRotateDelay: number = Startup\.minHold \+ Startup\.enterDur;/);

  assert.match(store, /export class ScreenSaverPreferenceStore \{/);
  assert.match(store, /private static readonly PREF_NAME: string = 'screensaver_preferences';/);
  assert.match(store, /private static readonly INTERVAL_KEY: string = 'quote_interval_ms';/);
  assert.match(store, /intervalMs\(\): number \{/);
  assert.match(store, /saveIntervalMs\(ms: number\): void \{/);
  assert.match(store, /ScreenSaver\.isValidInterval\(value\)/);
  assert.match(store, /ScreenSaver\.defaultIntervalMs/);

  assert.match(index, /import \{ ScreenSaverPreferenceStore \} from '\.\.\/model\/ScreenSaverPreferenceStore';/);
  assert.match(index, /@State screenSaverIntervalMs: number = ScreenSaver\.defaultIntervalMs;/);
  assert.match(index, /private ensureScreenSaverPreferenceStore\(\): void \{/);
  assert.match(index, /\.intervalMs\(\);/);
  assert.match(index, /private setScreenSaverInterval\(ms: number\): void \{/);
  assert.match(index, /\.saveIntervalMs\(ms\);/);
  assert.match(index, /screenSaverIntervalMs: this\.screenSaverIntervalMs,/);
  assert.match(index, /onScreenSaverIntervalChange: \(ms: number\): void =>/);

  assert.match(settings, /@Prop screenSaverIntervalMs: number = ScreenSaver\.defaultIntervalMs;/);
  assert.match(settings, /onScreenSaverIntervalChange: \(ms: number\) => void/);
  assert.match(settings, /this\.GroupTitle\('屏保 \/ 台历'\)/);
  assert.match(settings, /ScreenSaverIntervalRow\(\)/);
  assert.match(settings, /ForEach\(ScreenSaver\.intervalOptions/);
  assert.match(settings, /this\.onScreenSaverIntervalChange\(ms\);/);
  assert.match(settings, /ScreenSaver\.intervalShortLabels\[index\]/);
  assert.match(settings, /ScreenSaver\.intervalLabels\[index\]/);
});

test('65.6 red lines: no new permission, no tracking/network, no prototype change', () => {
  assert.doesNotMatch(moduleJson5, /ohos\.permission\.[A-Z_]+/g.test(moduleJson5)
    ? /ohos\.permission\.SCREEN_SAVER/ : /never-match-screen-saver-permission/);
  for (const src of [mask, ambience, store]) {
    for (const banned of ['hilog', 'hiAppEvent', '@kit.NetworkKit', 'fetch(']) {
      assert.ok(!src.includes(banned), `screen saver layer must not reference ${banned}`);
    }
  }
  // 装饰层仍不拦截命中 / 不参与读屏
  assert.match(mask, /\.accessibilityLevel\('no'\)/);
  assert.match(ambience, /\.hitTestBehavior\(HitTestMode\.None\)/);
  // 冷启动关键编排未被改写
  assert.match(mask, /this\.holdMs = Math\.max\(Startup\.minHold, this\.sourceAt \+ Startup\.enterDur/);
  assert.match(mask, /Math\.floor\(Math\.random\(\) \* QUOTES\.length\)/);
  assert.equal((mask.match(/const QUOTES: QuoteEntry\[\]/g) ?? []).length, 1);
});
