import { hapTasks } from '@ohos/hvigor-ohos-plugin';
import * as fs from 'fs';
import * as path from 'path';

/**
 * 模块级 ABI 本机覆盖：从 .local/local-abi.json 注入 abiFilters。
 *
 * 为什么要有这么一层（2026-10-31 实测）：
 *   仓库提交的 entry/build-profile 永远只有 arm64-v8a —— 真机 XT2 与 Apple Silicon
 *   Mac 上的模拟器都是 arm64。但 **Windows 版 DevEco 只提供 x86_64 模拟器镜像**（实测
 *   -imageList 的 API24 三折叠镜像落盘目录就是 phone_all_x86），arm64-only 的 HAP 装上去
 *   会被 bm install 以 code:9568347 拒绝。
 *
 *   只改命令行脚本不够：**在 IDE 里点「运行」走的是 IDE 自己的 hvigor**，它读
 *   build-profile.json5，不会读我们的脚本参数 → IDE 部署照样失败。所以必须注入到
 *   hvigor pipeline 里，让命令行与 IDE 两条路径行为一致。
 *
 * 机制（已在 DevEco SDK 的 .d.ts 中核实，非凭记忆）：
 *   hvigor-ohos-plugin/src/options/build/hap-ohos-config.d.ts
 *     HapOhosConfig = ModuleOhosConfig = { overrides?: Overrides }
 *     Overrides = { buildOption?: BuildOption }
 *     BuildOption = { externalNativeOptions?: { abiFilters?: string[] } }
 *   与根 hvigorfile.ts 注入 signingConfig 是同一套 overrides 思路，但此处作用于 HAP 模块。
 *   注意 App 级 AppOhosConfig.overrides **只有 appOpt 与 signingConfig** 两个字段，
 *   在那里写 buildOption 会 schema 校验失败 —— 这是必须放在模块级的原因。
 *
 * 交换机：`tools/abi.ps1 -Set x86_64 | -Reset | -Status`，写入 .local/local-abi.json
 * （已在 .gitignore 忽略）。没有该文件时不做任何注入，行为与提交状态完全一致：
 * 另一台 Mac 上不会出现这个文件，也就永远是 arm64。
 */
const LOCAL_ABI_CANDIDATES: string[] = [
  './.local/local-abi.json',
  path.resolve(__dirname, '../.local/local-abi.json')
];

function loadLocalAbiFilters(): string[] {
  for (const file of LOCAL_ABI_CANDIDATES) {
    if (!fs.existsSync(file)) {
      continue;
    }
    try {
      const parsed = JSON.parse(fs.readFileSync(file, 'utf-8')) as { abiFilters?: unknown };
      const abiFilters: unknown = parsed?.['abiFilters'];
      if (Array.isArray(abiFilters) && abiFilters.length > 0 &&
          abiFilters.every((item): boolean => typeof item === 'string')) {
        return abiFilters as string[];
      }
      console.log(`[abi] ${file} 内容不是合法的 abiFilters 数组 —— 本次不注入`);
    } catch (error) {
      console.log(`[abi] 读取 ${file} 失败 —— 本次不注入：${String(error)}`);
    }
    return [];
  }
  return [];
}

const localAbiFilters: string[] = loadLocalAbiFilters();

if (localAbiFilters.length > 0) {
  console.log(`[abi] 已从 .local/local-abi.json 注入 abiFilters=${localAbiFilters.join(',')}`);
  console.log('[abi] ⚠️ 本机覆盖仅供 x86_64 模拟器调试；真机 / arm64 请跑 tools/abi.ps1 -Reset');
} else {
  console.log('[abi] 未设置本机 ABI 覆盖 —— 按 build-profile.json5 的 arm64-v8a 构建');
}

export default {
  system: hapTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [],      /* Custom plugin to extend the functionality of Hvigor. */
  config: {
    ohos: {
      overrides: localAbiFilters.length > 0 ? {
        buildOption: {
          externalNativeOptions: {
            abiFilters: localAbiFilters
          }
        }
      } : {}
    }
  }
}
