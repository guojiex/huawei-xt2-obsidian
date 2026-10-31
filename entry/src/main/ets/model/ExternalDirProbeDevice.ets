/**
 * ExternalDirProbeDevice.ets —— 最小样例在**真机上的实现**（model/ExternalDirProbe 的 IO 端）
 *
 * 这一层只做「把三个注入契约接到真实系统 API 上」，不掺任何产品逻辑。
 * 每个 API 都对着本机 API 26 SDK 的 .d.ts 核实过，不是凭记忆：
 *
 * | 用途 | API | 声明位置 | 版本 |
 * | --- | --- | --- | --- |
 * | 选目录 | `picker.DocumentViewPicker.select(options?)` → `Promise<Array<string>>` | @ohos.file.picker | since 9 |
 * | 目录模式 | `picker.DocumentSelectMode.FOLDER = 1` | 同上 | since 11 |
 * | 持久化 | `fileShare.persistPermission(policies)` | @ohos.fileshare | since 11 |
 * | 激活 | `fileShare.activatePermission(policies)` | 同上 | since 11 |
 * | 查询 | `fileShare.checkPersistentPermission(policies)` | 同上 | since 17 |
 * | 递归列出 | `fileIo.listFileSync(path, options)` | @ohos.file.fs | since 9（recursion since 11） |
 * | 读文本 | `fileIo.readText(filePath, options?)` → `Promise<string>` | 同上 | since 9 |
 * | 原子写 | `fileIo.AtomicFile` + `startWrite()` / `finishWrite()` / `failWrite()` | 同上 | since 15 |
 *
 * 三个类均由 `@kit.CoreFileKit` 导入（该 kit 已确认导出 fileIo / fileShare / picker）。
 * `DocumentViewPicker` 推荐用带 UIAbilityContext 的构造函数（since 12），
 * 无参构造（since 12）官方注释写着有失败风险，这里不用。
 */
import { fileIo, fileShare, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  FileShareLike, ExternalDirPickerLike, ProbeFsLike, ProbePolicy, ProbeListOptions,
  ProbeWriteError, ExternalDirProbeRunner
} from './ExternalDirProbe';

/** 选目录依赖的系统能力；实施前必须用 canIUse 判一遍（P1 前置项的要求）。 */
export const FOLDER_SELECTION_SYSCAP: string = 'SystemCapability.FileManagement.UserFileService.FolderSelection';

/** 设备是否支持目录选择 —— 不支持时样例直接给出结论，不去猜。 */
export function supportsFolderSelection(): boolean {
  return canIUse(FOLDER_SELECTION_SYSCAP);
}

/** Picker 侧：真实的目录选择。 */
export class DeviceDirPicker implements ExternalDirPickerLike {
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async selectFolder(): Promise<string[]> {
    const options: picker.DocumentSelectOptions = {
      maxSelectNumber: 1,           // 目录一次只能选一个（SDK 注释明示）
      selectMode: picker.DocumentSelectMode.FOLDER
    };
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context);
    return await documentPicker.select(options);
  }
}

/** fileshare 侧：持久授权三件套（全部要求 FILE_ACCESS_PERSIST，已声明且实测已授予）。 */
export class DeviceFileShare implements FileShareLike {
  async persistPermission(policies: ProbePolicy[]): Promise<void> {
    await fileShare.persistPermission(policies);
  }

  async activatePermission(policies: ProbePolicy[]): Promise<void> {
    await fileShare.activatePermission(policies);
  }

  async checkPersistentPermission(policies: ProbePolicy[]): Promise<boolean[]> {
    return await fileShare.checkPersistentPermission(policies);
  }
}

/** fs 侧：递归列出 / 读文本 / 原子写。 */
export class DeviceProbeFs implements ProbeFsLike {
  listFileSync(uri: string, options: ProbeListOptions): string[] {
    return fileIo.listFileSync(uri, options);
  }

  async readText(uri: string): Promise<string> {
    return await fileIo.readText(uri);
  }

  /**
   * 更新外部目录里的已有文件。沿用仓库硬约束 10 / 15 的 AtomicFile 语义：
   * 写失败调 `failWrite()` 回滚，不自己拼 tmp + rename。
   * 写入回调写法照 `git/GitFsBackend.ets` 已验证的那套（WriteStream 没有 writeSync/closeSync）。
   */
  writeAtomic(uri: string, content: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const atomicFile: fileIo.AtomicFile = new fileIo.AtomicFile(uri);
      const fail = (stage: string, error: Object): void => {
        try {
          atomicFile.failWrite();
        } catch (rollbackError) {
          // 回滚本身也失败时保留原始异常
        }
        reject(new ProbeWriteError((error as BusinessError).code ?? -1, stage + ' 失败'));
      };
      let stream: fileIo.WriteStream;
      try {
        stream = atomicFile.startWrite();
      } catch (error) {
        fail('startWrite', error as Object);
        return;
      }
      const commit = (): void => {
        try {
          stream.close();
          atomicFile.finishWrite();
        } catch (error) {
          fail('finishWrite', error as Object);
          return;
        }
        resolve();
      };
      if (content.length === 0) {
        commit();
        return;
      }
      try {
        // 第二个参数是 encoding 字符串（SDK 重载如此），不是 WriteOptions 对象
        stream.write(content, 'utf-8', (error?: BusinessError): void => {
          if (error !== undefined && error !== null) {
            fail('write', error as Object);
            return;
          }
          commit();
        });
      } catch (error) {
        fail('write', error as Object);
      }
    });
  }
}

/** 组装一个跑在真机上的样例 runner。 */
export function createDeviceProbeRunner(context: common.UIAbilityContext): ExternalDirProbeRunner {
  return new ExternalDirProbeRunner(
    new DeviceDirPicker(context),
    new DeviceFileShare(),
    new DeviceProbeFs()
  );
}
