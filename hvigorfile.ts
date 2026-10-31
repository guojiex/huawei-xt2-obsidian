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
/**
 * 调试 / 发布两套凭据分开（2026-10-31 上架需要）：
 *   默认读 local-signing.json（DevEco 自动签名的调试凭据，日常装机调试用）；
 *   设置环境变量 OHOS_SIGNING_PROFILE=release 时改读 release-signing.json（AGC 申请的
 *   发布证书 + 发布 Profile），对应 tools/build.ps1 -Release。
 * 两者**不能混用**：发布签名的包装不上真机（只能上架），调试签名上不了架。
 * 不设环境变量时行为与过去完全一致 —— IDE 点「运行」不受影响。
 */
const LOCAL_SIGNING_FILES: Record<string, string> = {
  default: './.local/local-signing.json',
  release: './.local/release-signing.json',
  // v1.5 外部目录持久授权需要含 FILE_ACCESS_PERSIST 的 profile（同源见下）。
  // ⚠️ 启用前提：该 profile 的 development-certificate 必须与 certpath/storeFile
  // 是同一个开发证书，否则 `bm install` 报 9568322 not trusted app source
  // （2026-10-31 实测：证书 SHA1 65E4… 与本机 keystore C7FA… 不同源）。
  'file-access': './.local/file-access-signing.json'
};

const signingProfileKey: string = (process.env['OHOS_SIGNING_PROFILE'] ?? 'default').trim();
const LOCAL_SIGNING_FILE: string = LOCAL_SIGNING_FILES[signingProfileKey] ?? LOCAL_SIGNING_FILES['default'];

function loadLocalSigning(): Record<string, string> {
  if (fs.existsSync(LOCAL_SIGNING_FILE)) {
    return JSON.parse(fs.readFileSync(LOCAL_SIGNING_FILE, 'utf-8')) as Record<string, string>;
  }
  return {};
}

const signingMaterial: Record<string, string> = loadLocalSigning();
const hasSigning: boolean = Object.keys(signingMaterial).length > 0;

if (hasSigning) {
  console.log(`[signing] 已从 ${LOCAL_SIGNING_FILE}（profile=${signingProfileKey}）注入签名配置（build-profile.json5 保持干净）`);
} else {
  console.log(`[signing] 未找到 ${LOCAL_SIGNING_FILE}（profile=${signingProfileKey}）—— 本次构建不签名（产物为 -unsigned.hap）`);
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
