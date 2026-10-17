import { appTasks } from '@ohos/hvigor-ohos-plugin';
import * as fs from 'fs';

/**
 * 签名配置：从本地文件注入，不走 build-profile.json5。
 *
 * 为什么这么写：DevEco「自动签名」会把**密码明文 + 本机绝对路径**回写进
 * build-profile.json5（见 AGENTS.md 硬约束 19）。本仓库是公开仓库，那个文件必须入库
 * （hvigor 找不到它就报 00304035 Not Found），所以不能靠 ignore 解决，只能把凭据挪出去。
 *
 * 机制（已在 DevEco SDK 的 .d.ts 中核实，非凭记忆）：
 *   hvigor-ohos-plugin/src/options/build/app-ohos-config.d.ts
 *     AppOhosConfig = { overrides?: { appOpt?, signingConfig?: SigningConfigBuildOpt } }
 *   hvigor-ohos-plugin/src/tasks/sign/sign-util.d.ts
 *     mergeSigningConfig(signingConfig, signingConfigFromHvigorfile)  ← overrides 优先级更高
 *   src/options/options.d.ts: RequiredNamed { name: string }
 *
 * ⚠️ 但**运行时 schema 比 .d.ts 更严**（2026-10-17 实测，别在 signingConfig 里写 name）：
 *   ERROR 00303038 Schema validate failed, at file: hvigorfile.ts
 *     instancePath '/overrides/signingConfig', keyword 'enum',
 *       params: { allowedValues: [ 'material', 'type' ] }
 *     instancePath '/overrides/signingConfig', keyword 'propertyNames',
 *       params: { propertyName: 'name' } → 'property name must be valid'
 *   → signingConfig 只接受 material / type 两个字段，写 name 直接构建失败。
 *     类型定义与运行时校验冲突时**以运行时为准**。
 *
 * 因此 build-profile.json5 保持 "signingConfigs": []，凭据只存在于
 * .local/local-signing.json（已在 .gitignore 中忽略）。
 * 没有该文件时（例如别人 clone 后首次构建）不注入，产物为 unsigned，构建不报错。
 */
const LOCAL_SIGNING_FILE: string = './.local/local-signing.json';

function loadLocalSigning(): Record<string, string> {
  if (fs.existsSync(LOCAL_SIGNING_FILE)) {
    return JSON.parse(fs.readFileSync(LOCAL_SIGNING_FILE, 'utf-8')) as Record<string, string>;
  }
  return {};
}

const signingMaterial: Record<string, string> = loadLocalSigning();
const hasSigning: boolean = Object.keys(signingMaterial).length > 0;

if (hasSigning) {
  console.log('[signing] 已从 .local/local-signing.json 注入签名配置（build-profile.json5 保持干净）');
} else {
  console.log('[signing] 未找到 .local/local-signing.json —— 本次构建不签名（产物为 -unsigned.hap）');
}

export default {
  system: appTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [],      /* Custom plugin to extend the functionality of Hvigor. */
  config: {
    ohos: {
      overrides: hasSigning ? {
        // ⚠️ 不要写 name：schema 只接受 material / type（见文件头注释的实测报错）
        signingConfig: {
          type: 'HarmonyOS',
          material: {
            certpath: signingMaterial['certpath'] ?? '',
            storeFile: signingMaterial['storeFile'] ?? '',
            storePassword: signingMaterial['storePassword'] ?? '',
            keyAlias: signingMaterial['keyAlias'] ?? '',
            keyPassword: signingMaterial['keyPassword'] ?? '',
            profile: signingMaterial['profile'] ?? '',
            signAlg: signingMaterial['signAlg'] ?? 'SHA256withECDSA'
          }
        }
      } : {}
    }
  }
}
