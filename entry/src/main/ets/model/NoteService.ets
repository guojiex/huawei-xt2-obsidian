/**
 * NoteService.ets —— 笔记文件本身的读写与生命周期（v0.2 起）
 *
 * 为什么单独一层，而不塞进 VaultRegistry：
 * VaultRegistry 管的是「有哪些库」，NoteService 管的是「某个库里有哪些笔记文件」。
 * 两者写在一起，M2 的保存 / M3 的读取 / 1.6 的重命名移动删除都会往同一个类里堆，
 * 很快变成什么都管的 God Object。分层依据 AGENTS.md「单一职责」。
 *
 * 路径铁律（硬约束 #14）：本文件**不拼任何沙箱路径**，
 * 绝对路径一律经 `VaultRegistry.absoluteIn()`（内部才是唯一的 VaultPathResolver）。
 *
 * 本文件当前实现：新建（M1 验证前提）、读取（M2/M3 共用）、**保存（M2 自动保存，
 * AtomicFile 原子写，C1 硬约束）**、重命名 / 移动 / 删除（1.6 / 方案 A 已落）。
 */
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { sanitizeVaultName } from './Vault';
import { VaultRegistry } from './VaultRegistry';

const NOTE_DOMAIN: number = 0x0003;
const NOTE_TAG: string = 'NoteService';

export class NoteService {
  /** 笔记扩展名（v0.2 只认这一个；`.markdown` 已在 FileTree 里被接受但不新建） */
  static readonly EXT: string = '.md';

  /**
   * 用户输入（可能是「名字」，也可能是「目录/目录/名字」）→ 库内相对路径。
   * - 每段按 `sanitizeVaultName` 消毒（去非法字符、去前导点、去空白）——所以段里输 `/` 会被吞掉，
   *   想建子目录请用 `/` 显式分隔；`..` 也到不了上级目录（前导点被去掉，且 Resolver 会拒绝）；
   * - 末段自动补 `.md`：笔记就该是 md，不补会在文件树里直接看不见（FileTree 只收 md）；
   * - 全部为空 → 抛错，由调用方禁用确认按钮；
   * - **末段为空**（路径以 `/` 结尾，如目录行 + 预填 `工程/` 后还没输名字）→ 抛错：
   *   否则空段会被跳过，静默建出 `工程.md` 这种**根目录文件**，与用户意图正相反
   *   （2026-10-18 加 initialDir 预填时发现的坑）。
   */
  static normalizeRelPath(raw: string): string {
    const parts: string[] = raw.split('/');
    const segs: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const seg: string = sanitizeVaultName(parts[i]);
      if (seg.length > 0) {
        segs.push(seg);
      }
    }
    if (segs.length === 0) {
      throw new Error('笔记名为空');
    }
    // 末段为空 = 只给了目录没给名字（预填 initialDir 后的初始态就是这种）
    if (parts[parts.length - 1].trim().length === 0) {
      throw new Error('请填写笔记名称');
    }
    const last: string = segs[segs.length - 1].toLowerCase();
    if (!last.endsWith(NoteService.EXT) && !last.endsWith('.markdown')) {
      segs[segs.length - 1] = segs[segs.length - 1] + NoteService.EXT;
    }
    return segs.join('/');
  }

  /** 目标笔记是否已存在（用于重名加后缀与「不再-path exists」判定） */
  static exists(registry: VaultRegistry, vaultId: string, relPath: string): boolean {
    try {
      return fileIo.accessSync(registry.absoluteIn(vaultId, relPath));
    } catch (error) {
      return false;
    }
  }

  /**
   * 重名处理：与库的 `uniqueVaultId` 同策略 —— 存在就在**扩展名前**加 -2/-3…，
   * 不覆盖已有笔记（覆盖等于静默删掉用户写过的东西，是本应用最不能犯的错）。
   */
  static uniqueRelPath(registry: VaultRegistry, vaultId: string, relPath: string): string {
    if (!NoteService.exists(registry, vaultId, relPath)) {
      return relPath;
    }
    const dot: number = relPath.lastIndexOf('.');
    const stem: string = dot > 0 ? relPath.substring(0, dot) : relPath;
    const ext: string = dot > 0 ? relPath.substring(dot) : '';
    let n: number = 2;
    let candidate: string = stem + '-' + n + ext;
    while (NoteService.exists(registry, vaultId, candidate)) {
      n++;
      candidate = stem + '-' + n + ext;
    }
    return candidate;
  }

  /**
   * 新建笔记：逐级补建父目录 → 写空文件 → 返回实际落地的相对路径。
   * 失败一律抛错且**不留半状态**：父目录建成功了但文件写失败，只会留下空目录，
   * 而空目录在树的 next 扫描里会正常显示为一个可展开的空文件夹，不是脏数据。
   */
  static createNote(registry: VaultRegistry, vaultId: string, relPath: string): string {
    const target: string = NoteService.uniqueRelPath(registry, vaultId, relPath);

    const segs: string[] = target.split('/');
    for (let i = 1; i < segs.length; i++) {
      const dirRel: string = segs.slice(0, i).join('/');
      const dirAbs: string = registry.absoluteIn(vaultId, dirRel);
      if (!fileIo.accessSync(dirAbs)) {
        fileIo.mkdirSync(dirAbs);
      }
    }

    // API 24 的 openSync 返回 **File 对象**（不是 fd number，早期版本才是 number）；
    // closeSync 两个都收，writeSync 只收 fd → 从 file.fd 取。
    const abs: string = registry.absoluteIn(vaultId, target);
    const file: fileIo.File = fileIo.openSync(abs, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
    try {
      fileIo.writeSync(file.fd, '');
    } finally {
      fileIo.closeSync(file);
    }
    hilog.info(NOTE_DOMAIN, NOTE_TAG, '新建笔记 %{public}s', target);
    return target;
  }

  /**
   * 读取笔记全文（M3 预览 / M2 编辑器加载用）。
   * 读失败返回空串而不是抛错：调用方是 UI 层，读不到时给个空编辑器比崩掉好，
   * 详情进 hilog。⚠️ 二进制/超大文件不在此考虑范围内（库只收 md，人为上限）。
   */
  static readNote(registry: VaultRegistry, vaultId: string, relPath: string): string {
    try {
      const abs: string = registry.absoluteIn(vaultId, relPath);
      const text: string = fileIo.readTextSync(abs);
      hilog.info(NOTE_DOMAIN, NOTE_TAG, '读取笔记 %{public}s（%{public}d 字）', relPath, text.length);
      return text;
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(NOTE_DOMAIN, NOTE_TAG, '读取笔记失败 %{public}s: %{public}s', relPath, err.message);
      return '';
    }
  }

  /**
   * 保存笔记全文（M2 自动保存 / 2.3）。
   * 用**官方 `AtomicFile`**（api_notes C1 ✅，API 24 可用）做原子写：
   * `startWrite()` 返回 `WriteStream`，写用 `stream.write(str)`（继承自 stream.Writable，
   * 返回 boolean、无 callback 即同步缓冲写），收尾用 `stream.close(): void`（同步 flush+关），
   * 全部成功才 `finishWrite()` 落到目标——崩溃/中断时原文件完好、绝不写出半截内容；
   * 失败 `failWrite()` 回滚不留 .tmp 残留。
   * ⚠️ WriteStream 没有 `writeSync` / `closeSync`（那是 File 的方法），写/关只能用
   * `write` / `close`。失败抛 `Error`：调用方（Index 自动保存）据此 toast。
   */
  static saveNote(registry: VaultRegistry, vaultId: string, relPath: string, content: string): void {
    const abs: string = registry.absoluteIn(vaultId, relPath);
    const atomicFile: fileIo.AtomicFile = new fileIo.AtomicFile(abs);
    try {
      const stream = atomicFile.startWrite();
      stream.write(content);
      stream.close();
      atomicFile.finishWrite();
      hilog.info(NOTE_DOMAIN, NOTE_TAG, '保存笔记 %{public}s（%{public}d 字）', relPath, content.length);
    } catch (error) {
      try {
        atomicFile.failWrite();
      } catch (e) {
        hilog.warn(NOTE_DOMAIN, NOTE_TAG, 'saveNote 回滚 failWrite 失败（忽略）');
      }
      const err = error as BusinessError;
      hilog.error(NOTE_DOMAIN, NOTE_TAG, '保存笔记失败 %{public}s: %{public}s', relPath, err.message);
      throw new Error('保存笔记失败: ' + err.message);
    }
  }

  // ===== 2026-10-18 方案 A：显式新建文件夹 + 目录删除 =====
  // 背景：用户拍板原话「设计稿里面我要怎么新建文件夹？？？」—— 原先只能靠笔记名
  // 带 / 隐式建目录，建不了空文件夹；而建了文件夹却没有删除入口（行尾只有
  // rename/move）。本组方法把两者补齐，与 createNote/ normalizeRelPath 同一套消毒。

  /**
   * 文件夹路径归一化：与 normalizeRelPath 同款分段消毒，但**不补 .md**。
   * - 末段为空（路径以 `/` 结尾）→ 抛错：用户想建的「只要目录/」没有文件名，
   *   静默跳过空段会建出 `只要目录.md` 这种根目录文件，与意图正相反；
   * - 全空 → 抛错，由调用方禁用确认按钮。
   */
  static normalizeDirPath(raw: string): string {
    const parts: string[] = raw.split('/');
    const segs: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const seg: string = sanitizeVaultName(parts[i]);
      if (seg.length > 0) {
        segs.push(seg);
      }
    }
    if (segs.length === 0) {
      throw new Error('文件夹名为空');
    }
    if (parts[parts.length - 1].trim().length === 0) {
      throw new Error('请填写文件夹名称');
    }
    return segs.join('/');
  }

  /** 重名目录：已存在就在末段加 -2/-3…（与 uniqueRelPath 同策略，不覆盖） */
  static uniqueDirPath(registry: VaultRegistry, vaultId: string, relPath: string): string {
    if (!NoteService.exists(registry, vaultId, relPath)) {
      return relPath;
    }
    let n: number = 2;
    let candidate: string = relPath + '-' + n;
    while (NoteService.exists(registry, vaultId, candidate)) {
      n++;
      candidate = relPath + '-' + n;
    }
    return candidate;
  }

  /**
   * 新建空文件夹：逐级补建父目录 → 建末级目录 → 返回实际落地的相对路径。
   * 中间目录缺失时一并建出（用户可一次输 `甲/乙/丙` 建三层）。
   */
  static createFolder(registry: VaultRegistry, vaultId: string, relPath: string): string {
    const target: string = NoteService.uniqueDirPath(registry, vaultId, relPath);

    const segs: string[] = target.split('/');
    for (let i = 1; i < segs.length; i++) {
      const dirRel: string = segs.slice(0, i).join('/');
      const dirAbs: string = registry.absoluteIn(vaultId, dirRel);
      if (!fileIo.accessSync(dirAbs)) {
        fileIo.mkdirSync(dirAbs);
      }
    }
    const abs: string = registry.absoluteIn(vaultId, target);
    if (!fileIo.accessSync(abs)) {
      fileIo.mkdirSync(abs);
    }
    hilog.info(NOTE_DOMAIN, NOTE_TAG, '新建文件夹 %{public}s', target);
    return target;
  }

  /**
   * 删除文件或整棵目录（方案 A 配套：建了文件夹要能删）。
   * 目录递归：先删子项再 rmdir（与 GitFsBackend 的 rmdir 前清空同一约束）。
   * ⚠️ 不可恢复 —— 调用方必须先过确认对话框；回收站是需求池 B 组，v0.2 没有。
   */
  static deletePath(registry: VaultRegistry, vaultId: string, relPath: string): void {
    const abs: string = registry.absoluteIn(vaultId, relPath);
    const stat = fileIo.statSync(abs);
    if (stat.isDirectory()) {
      const names: string[] = fileIo.listFileSync(abs);
      for (let i = 0; i < names.length; i++) {
        NoteService.deletePath(registry, vaultId, relPath + '/' + names[i]);
      }
      fileIo.rmdirSync(abs);
    } else {
      fileIo.unlinkSync(abs);
    }
    hilog.info(NOTE_DOMAIN, NOTE_TAG, '删除 %{public}s', relPath);
  }
}
