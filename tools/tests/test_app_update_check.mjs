import assert from 'node:assert/strict';
import test from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// v1.17 应用内检测更新（方向 A）：接口一律以 docs/harmonyos/api_notes.md V 组为准 ——
// V1 checkAppUpdate（API 12、无权限、形参只有 context）、V2 只取 updateAvailable 语义、
// V3 不读 versionName/versionCode、V4 showUpdateDialog 系统弹框接管、
// V5 官方限流阈值未记载（应用内冷却 5 分钟为工程选择，D-3 已定）、
// V6 错误码四类 + 通用，检查与弹框抛错列表分开（弹框不含 1009400003）。
// D-2：仅用户主动点击触发，进入关于页不自动请求。
const read = (rel) => readSourceFile(new URL(rel, import.meta.url));
const service = read('../../entry/src/main/ets/model/AppUpdateCheck.ets');
const settings = read('../../entry/src/main/ets/components/SettingsView.ets');
const moduleJson = read('../../entry/src/main/module.json5');

test('17.1 服务层：接口来自 @kit.AppGalleryKit，形参只有 context（V1，零新增权限）', () => {
  assert.match(service, /import \{ updateManager \} from '@kit\.AppGalleryKit'/);
  assert.match(service, /updateManager\.checkAppUpdate\(context\)/);
  assert.match(service, /updateManager\.showUpdateDialog\(context\)/);
  // 无权限要求（V1）：module.json5 不因本功能新增权限 ——
  // 既有集为 INTERNET + v1.5 已拍板例外 FILE_ACCESS_PERSIST（硬约束 13，见 api_notes T2）
  assert.doesNotMatch(moduleJson, /ohos\.permission\.(?!INTERNET|FILE_ACCESS_PERSIST)/);
});

test('17.2 隐私红线：不读市场版本号、不做客户端版本比较（V3）', () => {
  assert.match(service, /result\.updateAvailable ===\s*\n?\s*updateManager\.UpdateAvailableCode\.LATER_VERSION_EXIST/);
  assert.doesNotMatch(service, /result\.versionName/);
  assert.doesNotMatch(service, /result\.versionCode/);
  assert.doesNotMatch(service, /versionNotAfter/);
  // 界面不出现「发现 x.y.z 版本」类市场版本号文案
  assert.doesNotMatch(settings, /发现\s?\d+\.\d+/);
});

test('17.3 错误分类：V6 四类 + 通用（纯函数，检查分支专用）', () => {
  assert.match(service, /export function classifyCheckError\(code: number\)/);
  for (const [code, kind] of [[1009400003, 'network'], [1009400004, 'background'],
    [1009400005, 'privacy'], [1009400006, 'limited']]) {
    assert.match(service, new RegExp(`if \\(code === ${code}\\) \\{\\s*return '${kind}';`));
  }
  assert.match(service, /return 'generic';/);
});

test('17.4 检查与弹框分支分开：弹框 catch 不走 classifyCheckError、不含 1009400003（V6）', () => {
  const dialogFn = service.slice(service.indexOf('async function showSystemUpdateDialog'));
  assert.ok(dialogFn.length > 0, 'showSystemUpdateDialog exists');
  assert.doesNotMatch(dialogFn, /classifyCheckError/);
  assert.doesNotMatch(dialogFn, /1009400003/);
  // 检查分支的 catch 使用 classifyCheckError，与弹框分支不共用
  const checkFn = service.slice(service.indexOf('export async function runAppUpdateCheck'),
    service.indexOf('async function showSystemUpdateDialog'));
  assert.match(checkFn, /classifyCheckError\(err\.code\)/);
});

test('17.5 冷却：5 分钟工程选择、跨会话持久化、冷却期不联网（D-3 / V5）', () => {
  assert.match(service, /export const APP_UPDATE_COOLDOWN_MS: number = 5 \* 60 \* 1000;/);
  assert.match(service, /export function cooldownActive\(lastCheckMs: number, nowMs: number\): boolean/);
  // 持久化：Preferences 'app_update_check'（lastCheckMs / lastOutcome）
  assert.match(service, /PREF_NAME: string = 'app_update_check'/);
  assert.match(service, /KEY_LAST_CHECK_MS: string = 'lastCheckMs'/);
  // 冷却判定先于任何联网调用（不联网）
  const flow = service.slice(service.indexOf('export async function runAppUpdateCheck'));
  assert.ok(flow.indexOf('cooldownActive') < flow.indexOf('updateManager.checkAppUpdate'),
    'cooldown gate runs before checkAppUpdate');
  // 冷却期内点按不联网：limited 直接返回
  assert.match(service, /return \{ phase: 'limited', lastCheckClock: formatCheckClock\(lastCheckMs\) \};/);
});

test('17.6 仅手动触发：进入关于页不自动请求（D-2 / V5）', () => {
  // startAppUpdateCheck 只由按钮 onClick 调用
  assert.match(settings, /private startAppUpdateCheck\(\): void/);
  assert.match(settings, /\.onClick\(\(\): void => \{ this\.startAppUpdateCheck\(\); \}\)/);
  // aboutToAppear / onAppear 不触发检查更新
  const autoCalls = settings.match(/(?:aboutToAppear|onAppear)\([^)]*\)(?:\s*=>\s*)?\{[\s\S]{0,200}?startAppUpdateCheck/g);
  assert.equal(autoCalls, null, 'no automatic check on page appear');
  // 检查中禁用重复点击（§3.1）
  assert.match(settings, /if \(this\.appUpdatePhase === 'checking'\) \{\s*return;\s*\}/);
  assert.match(settings, /\.enabled\(this\.appUpdatePhase !== 'checking'\)/);
});

test('17.7 界面文案：八态 + 弹框失败兜底，不显示市场版本号（§3.3）', () => {
  for (const text of ['正在检查…', '发现可用更新。', '网络不可用，检查失败。请检查网络后重试。',
    '应用当前不在前台，请返回后重试。', '请先在华为应用市场完成隐私协议确认，再重试。',
    '刚刚检查过：当前没有可用更新（上次检查 ', '5 分钟后可再次联网检查。',
    '暂时无法打开系统更新弹框，请稍后重试，或自行打开华为应用市场完成更新。',
    '继续操作将由系统升级弹框接管；弹框由系统显示。']) {
    assert.ok(settings.includes(text), `missing copy: ${text}`);
  }
  // latest 态避免绝对承诺并附最近一次检查时间（V6 无「未上架」专用码）
  assert.match(settings, /'当前没有可用更新。上次检查：' \+ this\.appUpdateClock/);
});

test('17.8 token 引用与系统弹框边界（V4，硬约束 17）', () => {
  const aboutStart = settings.indexOf('  AboutTab() {');
  const aboutEnd = settings.indexOf('\n  @Builder\n', aboutStart + 1);
  const about = settings.slice(aboutStart, aboutEnd);
  const cardStart = about.indexOf('v1.17：检查更新组');
  const card = about.slice(cardStart, about.indexOf("this.GroupTitle('更新日志')"));
  assert.ok(cardStart > 0, 'update-check card present in AboutTab');
  // 颜色 / 圆角 / 间距 / 字号只引用 token（硬约束 17）
  for (const token of [/\$r\('app\.color\.text_primary'\)/, /\$r\('app\.color\.text_tertiary'\)/,
    /\$r\('app\.color\.brand'\)/, /\$r\('app\.color\.bg_navigation'\)/,
    /Space\.s4/, /Space\.s5/, /Radius\.card/, /FontSize\.caption/, /FontSize\.body1/, /FontSize\.body2/]) {
    assert.match(card, token);
  }
  // 不自定义 / 不临摹系统升级弹框（V4）：界面只保留 handoff 说明行
  assert.doesNotMatch(card, /CustomDialog/);
});
