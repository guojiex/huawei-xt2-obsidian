import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readSourceFile } from './lib/source.mjs';

// 防回归：2026-11-19 双包共存（方案三·多 product）
// dev product（com.jxg.huaweiobsidian.dev）让开发调试包与应用市场线上包同机共存，
// 消除真机覆盖安装报 9568286（app source not match）。
// 本测试守卫四条线：product 声明、签名分流、脚本参数、运行时守卫。
// 对应机制（SDK .d.ts 核实，见 docs/harmonyos/api_notes.md）：ProductBuildOpt.bundleName。

const rootProfile = readSourceFile(new URL('../../build-profile.json5', import.meta.url));
const hvigorFile = readSourceFile(new URL('../../hvigorfile.ts', import.meta.url));
const buildPs1 = readSourceFile(new URL('../../tools/build.ps1', import.meta.url));
const installPs1 = readSourceFile(new URL('../../tools/install.ps1', import.meta.url));
const settingsView = readSourceFile(new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url));

test('root build-profile declares dev product with dev bundleName', () => {
  // dev product 必须覆盖包名，否则与线上包同名同签名，双包共存失效。
  // default product 没有 bundleName 字段，所以从 "dev" 出发非贪婪匹配到的一定是 dev 自己的。
  assert.match(rootProfile, /"name":\s*"dev"[\s\S]*?"bundleName":\s*"com\.jxg\.huaweiobsidian\.dev"/);
});

test('default product stays untouched (no bundleName override)', () => {
  const defaultProduct = rootProfile.match(/"products":\s*\[\s*\{[\s\S]*?\n\s*\},/);
  assert.ok(defaultProduct, 'products 第一项应为 default');
  assert.match(defaultProduct[0], /"name":\s*"default"/);
  assert.doesNotMatch(defaultProduct[0], /bundleName/, 'default product 不加 bundleName 覆盖');
});

test('entry module targets map both products', () => {
  // modules[].targets[].applyToProducts 必须把 default / dev 两个 product 都映射到 entry 模块
  const applies = [...rootProfile.matchAll(/"applyToProducts":\s*\[([\s\S]*?)\]/g)];
  assert.ok(applies.length >= 2, 'applyToProducts 应有 default / dev 两条映射');
  const joined = applies.map((m) => m[1]).join('|');
  assert.match(joined, /"default"/);
  assert.match(joined, /"dev"/);
});

test('dev product label override resource exists', () => {
  const devres = readSourceFile(new URL('../../entry/src/devres/base/element/string.json', import.meta.url));
  const parsed = JSON.parse(devres);
  const label = parsed.string.find((s) => s.name === 'EntryAbility_label');
  assert.ok(label, 'devres 应覆盖 EntryAbility_label');
  assert.equal(label.value, '曜石笔记开发版');
});

test('hvigorfile routes dev product to dev-signing.json', () => {
  // dev 凭据入口：证书与 default 调试凭据同源，仅 profile 换 dev 包名调试 p7b
  assert.match(hvigorFile, /dev:\s*'\.\/\.local\/dev-signing\.json'/);
  // 按 hvigor 当前 product 自动选择（官方 find-target-product.js 同款读法；
  // hvigor 走 daemon，process.argv 里没有 CLI 参数，不能从 argv 探测）
  assert.match(hvigorFile, /getExtraConfig\(\)/);
  assert.match(hvigorFile, /get\('product'\)/);
  assert.match(hvigorFile, /selectSigningProfileKey/);
});

test('dev product does not use product-level resource.directories (AppScope killer)', () => {
  // product 级 resource.directories[0] 会**替换** AppScope 资源目录（process-resource.js
  // getAppResourceDir 实测），导致 $string:app_name 失联 —— 名称覆盖必须走 entry 模块 target。
  const devProduct = rootProfile.match(/"name":\s*"dev"[\s\S]*?"bundleName":\s*"com\.jxg\.huaweiobsidian\.dev"/);
  assert.ok(devProduct, 'products 里应有 name 为 dev 的 product');
  assert.doesNotMatch(devProduct[0], /"resource"/, 'dev product 不得配置 resource.directories');
});

test('entry module dev target overrides resources via module-level target', () => {
  const entryProfile = readSourceFile(new URL('../../entry/build-profile.json5', import.meta.url));
  // 模块 target 的 resource.directories 是**替换式**语义：main 与 devres 两个目录都要列全
  const devTarget = entryProfile.match(/"name":\s*"dev"[\s\S]*?"directories":\s*\[[\s\S]*?\]/);
  assert.ok(devTarget, 'entry 模块应有 dev target 且带 resource.directories');
  assert.match(devTarget[0], /"\.\/src\/main\/resources"/);
  assert.match(devTarget[0], /"\.\/src\/devres"/);
});

test('build.ps1 wires -Product parameter through to hvigor', () => {
  assert.match(buildPs1, /\[ValidateSet\('default',\s*'dev'\)\]/);
  assert.match(buildPs1, /-p product=\$Product/);
  // -Release 只支持 default（防误打 dev 的 .app 上架包）
  assert.match(buildPs1, /-Release 只支持 default product/);
});

test('install.ps1 wires -Product parameter and resolves bundle from BuildProfile', () => {
  assert.match(installPs1, /\[ValidateSet\('default',\s*'dev'\)\]/);
  // -Run 的 bundleName 从生成的 BuildProfile.ets 解析（dev 与线上包不同），失败回退硬编码
  assert.match(installPs1, /BuildProfile\.ets/);
  assert.match(installPs1, /com\.jxg\.huaweiobsidian\.dev/);
});

test('artifact paths are per-product (no cross-product fallback)', () => {
  // 2026-11-20 实测：构建目录与产物目录都按 product 分 ——
  // entry\build\<Product>\outputs\<Product>，BuildProfile.ets 在
  // entry\build\<Product>\generated\profile\<Product>\。
  // 跨 product 兜底会把 default 的旧产物误报/误装给 dev（dev 只出 unsigned 时尤其误导）。
  assert.match(buildPs1, /entry\\build\\\$Product\\outputs\\\$Product/);
  assert.match(installPs1, /entry\\build\\\$Product\\outputs\\\$Product/);
  assert.match(installPs1, /entry\\build\\\$Product\\generated\\profile\\\$Product\\BuildProfile\.ets/);
  assert.doesNotMatch(buildPs1, /['"]entry\\build\\default\\outputs/);
  assert.doesNotMatch(installPs1, /['"]entry\\build\\default\\outputs/);
});

test('SettingsView hides update check group on dev product', () => {
  // dev 包不上 AGC，「检查更新」必然失败 → 整组隐藏。
  // PRODUCT_NAME 生成常量是字面量类型，先经 string 成员 productNameOfBuild 放宽（否则 no-overlap 编译错）
  const guard = settingsView.match(/productNameOfBuild !== 'dev'/);
  assert.ok(guard, 'SettingsView 应有 dev product 守卫');
  assert.match(settingsView, /private readonly productNameOfBuild: string = BuildProfile\.PRODUCT_NAME/);
  const around = settingsView.substring(Math.max(0, guard.index - 400), guard.index + 1200);
  assert.match(around, /检查更新/, '守卫应包住检查更新组');
});
