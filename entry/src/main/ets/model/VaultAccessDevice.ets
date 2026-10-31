/*
 * VaultAccessDevice.ets —— VaultAccess 在**真机上的实现**（ model/VaultAccess 的 IO 端）
 *
 * 这一层只做「把注入契约接到真实系统 API」，不含产品逻辑。与 ExternalDirProbeDevice 同一套路：
 * model 侧保持零系统依赖（能在 Node 里裸跑），所有 @kit.* 只出现在这里。
 *
 * 两张实现（15.3 的关键分界线）：
 *   - SandboxVaultAccess：库目录在 filesDir/vaults/<id>，有绝对路径 → 走 @ohos.file.fs；
 *   - ExternalVaultAccess：库目录是用户授权的外部目录，只有 URI+dirFd → 走 vaultdir_napi。
 *
 * ⚠️ 调用方只能拿到 VaultAccess 接口，不许按 kind 分叉 IO（一层解析器原则，
 *    AGENTS.md 硬约束 14 的延伸）：差异已经全部关在这两个实现里了。
 */
import { fileIo, fileShare, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import nativeVaultDir, {
  VaultDirListResult, VaultDirIoResult, VaultDirReadResult,
  VaultDirStatResult, VaultDirBinaryResult, VaultDirFdResult
} from 'libvaultdir_napi.so';
import { VaultPathResolver } from './VaultPathResolver';
import {
  VaultAccess, VaultRootResolver, SandboxVaultAccess, ExternalVaultAccess,
  SandboxFsLike, SandboxStatLike, SandboxFileHandle,
  SandboxAtomicFileLike, SandboxWriteStreamLike,
  ExternalNativeLike, ExternalFdSource,
  ExternalStringResult, ExternalReadResult, ExternalBinaryResult,
  ExternalIoResult, ExternalStatResult, ExternalFdResult
} from './VaultAccess';

/** 打开目录 fd 的模式位：DIR 是本机 SDK 的目录位（0o200000），官方答复里的 READ_DIR 不存在。 */
const DIR_MODE: number = fileIo.OpenMode.READ_ONLY | fileIo.OpenMode.DIR;

/* ------------------------------------------------------------------------- */
/* 沙箱侧                                                                     */
/* ------------------------------------------------------------------------- */

/**
 * 把 VaultPathResolver 收成 VaultAccess 需要的单参数形状。
 * 硬约束 14 仍然成立：绝对路径的拼接只发生在 VaultPathResolver 内部，
 * 这里只是把 vaultId 固定住，不产生新的拼接规则。
 */
export class SandboxVaultRoot implements VaultRootResolver {
  private resolver: VaultPathResolver;
  private vaultId: string;

  constructor(resolver: VaultPathResolver, vaultId: string) {
    this.resolver = resolver;
    this.vaultId = vaultId;
  }

  resolve(relativePath: string): string {
    return this.resolver.resolve(this.vaultId, relativePath);
  }
}

/** @ohos.file.fs → SandboxFsLike。方法一一对应，不做任何重试或容错语义变更。 */
export class DeviceSandboxFs implements SandboxFsLike {
  listFileSync(abs: string): string[] {
    return fileIo.listFileSync(abs);
  }

  accessSync(abs: string): boolean {
    return fileIo.accessSync(abs);
  }

  mkdirSync(abs: string, recursive?: boolean): void {
    fileIo.mkdirSync(abs, recursive === true);
  }

  renameSync(from: string, to: string): void {
    fileIo.renameSync(from, to);
  }

  unlinkSync(abs: string): void {
    fileIo.unlinkSync(abs);
  }

  rmdirSync(abs: string): void {
    fileIo.rmdirSync(abs);
  }

  readTextSync(abs: string): string {
    return fileIo.readTextSync(abs);
  }

  statSync(abs: string): SandboxStatLike {
    return fileIo.statSync(abs);
  }

  openSync(abs: string, mode: number): SandboxFileHandle {
    return fileIo.openSync(abs, mode);
  }

  writeSync(fd: number, data: string): number {
    return fileIo.writeSync(fd, data);
  }

  readSync(fd: number, buffer: Uint8Array): number {
    return fileIo.readSync(fd, buffer.buffer);
  }

  closeSync(fd: number): void {
    fileIo.closeSync(fd);
  }

  openAtomic(abs: string): SandboxAtomicFileLike {
    return new fileIo.AtomicFile(abs);
  }
}

/** 组装一个「沙箱库」访问对象。相对路径仍在 VaultAccess 层，绝对路径只在解析器里出现。 */
export function createSandboxVaultAccess(resolver: VaultPathResolver, vaultId: string): VaultAccess {
  return new SandboxVaultAccess(new SandboxVaultRoot(resolver, vaultId), new DeviceSandboxFs());
}

/* ------------------------------------------------------------------------- */
/* 外部授权目录侧                                                             */
/* ------------------------------------------------------------------------- */

/** vaultdir_napi → ExternalNativeLike（签名本来就是按 .d.ts 排的，这里是直通转发）。 */
export class DeviceExternalNative implements ExternalNativeLike {
  listDirByFd(fd: number): ExternalStringResult {
    return nativeVaultDir.listDirByFd(fd) as VaultDirListResult;
  }

  listDirRecursiveByFd(fd: number): ExternalStringResult {
    return nativeVaultDir.listDirRecursiveByFd(fd) as VaultDirListResult;
  }

  openDirByFd(fd: number, name: string): ExternalFdResult {
    return nativeVaultDir.openDirByFd(fd, name) as VaultDirFdResult;
  }

  readFileByFd(fd: number, name: string): ExternalReadResult {
    return nativeVaultDir.readFileByFd(fd, name) as VaultDirReadResult;
  }

  readBinaryByFd(fd: number, name: string): ExternalBinaryResult {
    return nativeVaultDir.readBinaryByFd(fd, name) as VaultDirBinaryResult;
  }

  writeFileByFd(fd: number, name: string, content: string): ExternalIoResult {
    return nativeVaultDir.writeFileByFd(fd, name, content) as VaultDirIoResult;
  }

  deleteByFd(fd: number, name: string): ExternalIoResult {
    return nativeVaultDir.deleteByFd(fd, name) as VaultDirIoResult;
  }

  renameByFd(fd: number, oldName: string, newName: string): ExternalIoResult {
    return nativeVaultDir.renameByFd(fd, oldName, newName) as VaultDirIoResult;
  }

  statByFd(fd: number, name: string): ExternalStatResult {
    return nativeVaultDir.statByFd(fd, name) as VaultDirStatResult;
  }

  mkdirByFd(fd: number, name: string): ExternalIoResult {
    return nativeVaultDir.mkdirByFd(fd, name) as VaultDirIoResult;
  }

  removeDirByFd(fd: number, name: string): ExternalIoResult {
    return nativeVaultDir.removeDirByFd(fd, name) as VaultDirIoResult;
  }
}

/**
 * 「授权目录 URI → 目录 fd」。
 *
 * 每次公开调用都现开现关：**不缓存 fd**。理由是真机实测的结论 —— 跨应用重启后
 * 旧 fd 必然失效，长驻缓存只会让「目录被挪走」这类错误晚一步暴露，变成莫名其妙的 EBADF。
 */
export class DeviceExternalFdSource implements ExternalFdSource {
  private uri: string;

  constructor(uri: string) {
    this.uri = uri;
  }

  openRootFd(): number {
    const dirFile: fileIo.File = fileIo.openSync(this.uri, DIR_MODE);
    return dirFile.fd;
  }

  closeFd(fd: number): void {
    fileIo.closeSync(fd);
  }
}

/** 组装一个「外部授权目录库」访问对象。全程只传相对名字，绝不拼 URI。 */
export function createExternalVaultAccess(uri: string): VaultAccess {
  return new ExternalVaultAccess(new DeviceExternalNative(), new DeviceExternalFdSource(uri));
}
