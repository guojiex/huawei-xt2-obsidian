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
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { sanitizeVaultName } from './Vault';
import { VaultRegistry } from './VaultRegistry';
import { FileTree } from './FileTree';
import { NoteDraftService } from './NoteDraftService';
import { FullTextSearchService } from './FullTextSearchService';
import { WikiLinkService, WikiLinkUpdateReport } from './WikiLinkService';

const NOTE_DOMAIN: number = 0x0003;
const NOTE_TAG: string = 'NoteService';

export interface NotePathMutationResult {
  path: string;
  referenceUpdates: WikiLinkUpdateReport;
}

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

  /** 预计算一个尚未占用的笔记路径，供 Agent 先持久化操作意图再执行写入。 */
  static previewCreatePath(registry: VaultRegistry, vaultId: string, relPath: string): string {
    return NoteService.uniqueRelPath(registry, vaultId, relPath);
  }

  /** 在已确认未占用的精确路径写入新笔记正文，避免空文件先于 Agent 操作账落盘。 */
  static async createNoteWithContent(registry: VaultRegistry, vaultId: string, relPath: string,
    content: string): Promise<void> {
    if (NoteService.exists(registry, vaultId, relPath)) {
      throw new Error('CREATE_CONFLICT：目标笔记路径已被占用，未覆盖现有文件。');
    }
    NoteService.ensureParentDirectories(registry, vaultId, relPath);
    await NoteService.enqueueSaveNote(registry, vaultId, relPath, content, null, true);
    hilog.info(NOTE_DOMAIN, NOTE_TAG, '新建笔记 %{public}s', relPath);
  }

  /**
   * 新建笔记：逐级补建父目录 → 写空文件 → 返回实际落地的相对路径。
   * 失败一律抛错且**不留半状态**：父目录建成功了但文件写失败，只会留下空目录，
   * 而空目录在树的 next 扫描里会正常显示为一个可展开的空文件夹，不是脏数据。
   */
  static createNote(registry: VaultRegistry, vaultId: string, relPath: string): string {
    const target: string = NoteService.uniqueRelPath(registry, vaultId, relPath);
    NoteService.ensureParentDirectories(registry, vaultId, target);

    // API 24 的 openSync 返回 **File 对象**（不是 fd number，早期版本才是 number）；
    // closeSync 两个都收，writeSync 只收 fd → 从 file.fd 取。
    const abs: string = registry.absoluteIn(vaultId, target);
    const file: fileIo.File = fileIo.openSync(abs, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
    try {
      fileIo.writeSync(file.fd, '');
    } finally {
      fileIo.closeSync(file);
    }
    FullTextSearchService.noteSaved(vaultId, target, '');
    WikiLinkService.pathAdded(vaultId);
    hilog.info(NOTE_DOMAIN, NOTE_TAG, '新建笔记 %{public}s', target);
    return target;
  }

  private static ensureParentDirectories(registry: VaultRegistry, vaultId: string, relPath: string): void {
    const segs: string[] = relPath.split('/');
    for (let i = 1; i < segs.length; i++) {
      const dirRel: string = segs.slice(0, i).join('/');
      const dirAbs: string = registry.absoluteIn(vaultId, dirRel);
      if (!fileIo.accessSync(dirAbs)) {
        fileIo.mkdirSync(dirAbs);
      }
    }
  }

  /**
   * 读取笔记全文（M3 预览 / M2 编辑器加载用）。
   * 读失败返回空串而不是抛错：调用方是 UI 层，读不到时给个空编辑器比崩掉好，
   * 详情进 hilog。⚠️ 二进制/超大文件不在此考虑范围内（库只收 md，人为上限）。
   */
  static readNote(registry: VaultRegistry, vaultId: string, relPath: string): string {
    const text: string | null = NoteService.tryReadNote(registry, vaultId, relPath);
    return text === null ? '' : text;
  }

  /** 与 readNote 相同，但保留失败状态，供 v0.4 只记录成功打开项。 */
  static tryReadNote(registry: VaultRegistry, vaultId: string, relPath: string): string | null {
    try {
      const abs: string = registry.absoluteIn(vaultId, relPath);
      const text: string = fileIo.readTextSync(abs);
      hilog.info(NOTE_DOMAIN, NOTE_TAG, '读取笔记 %{public}s（%{public}d 字）', relPath, text.length);
      return text;
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(NOTE_DOMAIN, NOTE_TAG, '读取笔记失败 %{public}s: %{public}s', relPath, err.message);
      return null;
    }
  }

  /** 串行化所有原子写：flushSave 可能并发（防抖到点 + 切文件），同一 tmp 文件不能交叉写 */
  private static saveChain: Promise<void> = Promise.resolve();

  /**
   * 保存笔记全文（M2 自动保存 / 2.3）。
   * 用**官方 `AtomicFile`**（api_notes C1 ✅，API 24 可用）做原子写，**严格照官方示例流**：
   * `startWrite()` → `stream.write(content, 'utf-8', 回调)` → 回调里 `finishWrite()` 落盘。
   * ⚠️ **绝不能在 finishWrite 前调 `stream.close()`**（2026-10-18 真机 cppcrash SIGSEGV 实证：
   * close+finishWrite 双重释放 native 侧引用，崩溃栈 napi_delete_reference ← free，见
   * api_notes C1）。`write` 只把数据写进缓冲区，**回调触发才是落盘完成点**，finishWrite
   * 必须等它；官方示例正是把 finishWrite 放在 write 回调里。
   * - 空内容**不调 write**（Writable.write 禁空串会抛 401）：startWrite 已建空 tmp，
   *   直接 finishWrite 即把文件截断为 0 字节；
   * - 3s 超时兜底：write 回调不触发时 failWrite 回滚并拒绝，不让 flushSave 永久挂起；
   * - 失败 `failWrite()` 回滚不留 .tmp 残留；崩溃/中断时原文件完好。
   * 返回 Promise：flushSave await 它，失败 reject `Error`（调用方据此 toast）。
   */
  static saveNote(registry: VaultRegistry, vaultId: string, relPath: string, content: string): Promise<void> {
    return NoteService.enqueueSaveNote(registry, vaultId, relPath, content, null, false);
  }

  /**
   * 按读取版本条件保存。比较发生在与普通自动保存相同的写队列内，避免读后、排队期间
   * 有另一笔 App 保存先落盘后再被本次工具覆盖。
   */
  static saveNoteIfUnchanged(registry: VaultRegistry, vaultId: string, relPath: string,
    expectedContent: string, content: string): Promise<void> {
    return NoteService.enqueueSaveNote(registry, vaultId, relPath, content, expectedContent, false);
  }

  private static enqueueSaveNote(registry: VaultRegistry, vaultId: string, relPath: string,
    content: string, expectedContent: string | null, mustBeNew: boolean): Promise<void> {
    const abs: string = registry.absoluteIn(vaultId, relPath);
    const job: Promise<void> = NoteService.saveChain.then((): Promise<void> => {
      if (mustBeNew && NoteService.exists(registry, vaultId, relPath)) {
        throw new Error('CREATE_CONFLICT：目标笔记路径已被占用，未覆盖现有文件。');
      }
      if (expectedContent !== null) {
        const current: string | null = NoteService.tryReadNote(registry, vaultId, relPath);
        if (current === null || current !== expectedContent) {
          throw new Error('STALE_CONTENT：笔记已变化，未覆盖新内容。');
        }
      }
      return NoteService.runAtomicSave(abs, relPath, content);
    }).then((): void => {
      FullTextSearchService.noteSaved(vaultId, relPath, content);
      WikiLinkService.noteSaved(vaultId, relPath, content);
    });
    // 链上吞掉 rejection：单个保存失败不能断掉后续保存的排队
    NoteService.saveChain = job.then((): void => {
    }, (): void => {
    });
    return job;
  }

  /** 撤销本次创建时，只有文件仍等于操作结果才从库中移除。 */
  static deleteNoteIfUnchanged(registry: VaultRegistry, vaultId: string, relPath: string,
    expectedContent: string): Promise<void> {
    const job: Promise<void> = NoteService.saveChain.then(async (): Promise<void> => {
      const current: string | null = NoteService.tryReadNote(registry, vaultId, relPath);
      if (current === null || current !== expectedContent) {
        throw new Error('UNDO_CONFLICT：笔记已有后续修改，未删除。');
      }
      const abs: string = registry.absoluteIn(vaultId, relPath);
      const stat: fileIo.Stat = fileIo.statSync(abs);
      if (stat.isDirectory()) {
        throw new Error('UNDO_CONFLICT：目标已不是笔记文件，未删除。');
      }
      fileIo.unlinkSync(abs);
      FullTextSearchService.noteRemoved(vaultId, relPath, false);
      WikiLinkService.pathRemoved(vaultId);
      await NoteDraftService.discardPath(registry, vaultId, relPath);
      hilog.info(NOTE_DOMAIN, NOTE_TAG, '撤销创建笔记 %{public}s', relPath);
    });
    NoteService.saveChain = job.then((): void => {
    }, (): void => {
    });
    return job;
  }

  /** 单次原子写（saveNote 经 saveChain 串行调用）；resolve=已落盘，reject=已回滚 */
  private static runAtomicSave(abs: string, relPath: string, content: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const atomicFile: fileIo.AtomicFile = new fileIo.AtomicFile(abs);
      let settled: boolean = false;
      let timerId: number = -1;
      const fail = (msg: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timerId !== -1) {
          clearTimeout(timerId);
        }
        try {
          atomicFile.failWrite();
        } catch (e) {
          hilog.warn(NOTE_DOMAIN, NOTE_TAG, 'runAtomicSave 回滚 failWrite 失败（忽略）');
        }
        hilog.error(NOTE_DOMAIN, NOTE_TAG, '保存笔记失败 %{public}s: %{public}s', relPath, msg);
        reject(new Error('保存笔记失败: ' + msg));
      };
      const commit = (): void => {
        if (settled) {
          return;
        }
        if (timerId !== -1) {
          clearTimeout(timerId);
        }
        try {
          atomicFile.finishWrite();
        } catch (error) {
          const err = error as BusinessError;
          fail(err.message);
          return;
        }
        settled = true;
        hilog.info(NOTE_DOMAIN, NOTE_TAG, '保存笔记 %{public}s（%{public}d 字）', relPath, content.length);
        resolve();
      };
      try {
        const stream: fileIo.WriteStream = atomicFile.startWrite();
        timerId = setTimeout((): void => {
          fail('write 回调 3s 未触发');
        }, 3000);
        if (content.length === 0) {
          commit();
        } else {
          stream.write(content, 'utf-8', (err?: BusinessError): void => {
            if (err !== undefined && err !== null) {
              fail(err.message);
              return;
            }
            commit();
          });
        }
      } catch (error) {
        const err = error as BusinessError;
        fail(err.message);
      }
    });
  }

  /**
   * 读取库内图片等附件 → data URI（M3 预览「图片」项）。
   * 给 PreviewWebView 的 `readAsset` 桥用：vault 沙箱文件 WebView 拿不到
   * （resource://rawfile 跨域被禁，api_notes B4），经 JS→ArkTS 同步桥换成 data URI。
   * 只放行图片扩展名白名单（防笔记里嵌 <img src="笔记.md"> 之类把任意文件泄给页面）；
   * 读不到 / 不在白名单返回空串，Web 侧显示「图片不存在」。
   */
  static readAssetDataUri(registry: VaultRegistry, vaultId: string, relPath: string): string {
    const lower: string = relPath.toLowerCase();
    const exts: string[] = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg'];
    let ext: string = '';
    for (let i = 0; i < exts.length; i++) {
      if (lower.endsWith(exts[i])) {
        ext = exts[i];
        break;
      }
    }
    if (ext.length === 0) {
      return '';
    }
    const mimes: Record<string, string> = {
      '.png': 'image/png',
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.gif': 'image/gif',
      '.webp': 'image/webp',
      '.svg': 'image/svg+xml'
    };
    try {
      const abs: string = registry.absoluteIn(vaultId, relPath);
      const file: fileIo.File = fileIo.openSync(abs, fileIo.OpenMode.READ_ONLY);
      try {
        const size: number = fileIo.statSync(abs).size;
        const buf: ArrayBuffer = new ArrayBuffer(size);
        fileIo.readSync(file.fd, buf);
        const helper: util.Base64Helper = new util.Base64Helper();
        const b64: string = helper.encodeToStringSync(new Uint8Array(buf));
        return 'data:' + mimes[ext] + ';base64,' + b64;
      } finally {
        fileIo.closeSync(file);
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.warn(NOTE_DOMAIN, NOTE_TAG, '读取附件失败 %{public}s: %{public}s', relPath, err.message);
      return '';
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
  static async deletePath(registry: VaultRegistry, vaultId: string, relPath: string): Promise<void> {
    const abs: string = registry.absoluteIn(vaultId, relPath);
    const stat = fileIo.statSync(abs);
    if (stat.isDirectory()) {
      const names: string[] = fileIo.listFileSync(abs);
      for (let i = 0; i < names.length; i++) {
        await NoteService.deletePath(registry, vaultId, relPath + '/' + names[i]);
      }
      fileIo.rmdirSync(abs);
    } else {
      fileIo.unlinkSync(abs);
    }
    FullTextSearchService.noteRemoved(vaultId, relPath, stat.isDirectory());
    WikiLinkService.pathRemoved(vaultId);
    await NoteDraftService.discardPath(registry, vaultId, relPath);
    hilog.info(NOTE_DOMAIN, NOTE_TAG, '删除 %{public}s', relPath);
  }

  // ===== 1.6 左滑三档：重命名 / 移动 =====

  /**
   * 重命名文件或目录（只改最后一段，父路径不动）。
   * - 名称走 `sanitizeVaultName` 消毒；文件自动补 `.md`（原型：输入框预填去掉 .md 的名字）；
   * - 目标已存在 → 扩展名前加 -2/-3（同 uniqueRelPath 策略，不覆盖）；
   * - 消毒后与原名相同 → 无操作返回原路径（改名框不做「必须不同」校验，原地保存不算错）；
   * - renameSync 原子完成；返回实际落地的新相对路径（调用方据此更新 currentFilePath）。
   */
  static async renamePath(registry: VaultRegistry, vaultId: string, relPath: string,
    newName: string, isDir: boolean): Promise<NotePathMutationResult> {
    let base: string = sanitizeVaultName(newName);
    if (base.length === 0) {
      throw new Error('名称不能为空');
    }
    if (!isDir) {
      const lower: string = base.toLowerCase();
      if (!lower.endsWith(NoteService.EXT) && !lower.endsWith('.markdown')) {
        base = base + NoteService.EXT;
      }
    }
    const parent: string = FileTree.parentOf(relPath);
    const target: string = parent.length > 0 ? parent + '/' + base : base;
    if (target === relPath) {
      return { path: relPath, referenceUpdates: { updatedPaths: [], failedPaths: [], scanFailed: false } };
    }
    const unique: string = isDir
      ? NoteService.uniqueDirPath(registry, vaultId, target)
      : NoteService.uniqueRelPath(registry, vaultId, target);
    const copiedDrafts: boolean = await NoteDraftService.copySubtree(
      registry, vaultId, relPath, vaultId, unique, isDir);
    try {
      fileIo.renameSync(registry.absoluteIn(vaultId, relPath),
        registry.absoluteIn(vaultId, unique));
    } catch (error) {
      if (copiedDrafts) {
        NoteDraftService.cleanupOrphans(registry);
      }
      const err = error as Error;
      throw new Error(err.message);
    }
    try {
      await NoteDraftService.discardPath(registry, vaultId, relPath);
    } catch (error) {
      // 新路径草稿已先写好；下次启动会清理正式源文件已不存在的旧草稿。
    }
    FullTextSearchService.pathRetargeted(vaultId, relPath, unique, isDir);
    WikiLinkService.pathRetargeted(vaultId);
    const referenceUpdates: WikiLinkUpdateReport = await WikiLinkService.rewriteReferences(
      registry, vaultId, relPath, unique, isDir, async (path: string, content: string): Promise<void> => {
        await NoteService.saveNote(registry, vaultId, path, content);
      });
    hilog.info(NOTE_DOMAIN, NOTE_TAG, '重命名 %{public}s → %{public}s', relPath, unique);
    return { path: unique, referenceUpdates: referenceUpdates };
  }

  /**
   * 移动文件或目录到目标目录（目录选择器语义：destDir 为空串 = 库根目录）。
   * - 只换父路径，不改名；目标已存在 → 同策略加后缀（不覆盖）；
   * - 目录不允许移进自己或自己的子树（对话框侧已过滤候选，这里兜底再拦一次）；
   * - 目标目录缺失时逐级补建（把笔记移进「刚被清空的目录」不至于失败）；
   * - 返回实际落地的新相对路径（调用方据此更新 currentFilePath / revealPath）。
   */
  static async movePath(registry: VaultRegistry, vaultId: string, relPath: string,
    destDir: string, isDir: boolean): Promise<NotePathMutationResult> {
    if (isDir && (destDir === relPath || destDir.startsWith(relPath + '/'))) {
      throw new Error('不能移动到自身内部');
    }
    const name: string = relPath.substring(relPath.lastIndexOf('/') + 1);
    const target: string = destDir.length > 0 ? destDir + '/' + name : name;
    if (target === relPath) {
      return { path: relPath, referenceUpdates: { updatedPaths: [], failedPaths: [], scanFailed: false } };
    }
    // 补建目标目录（含中间层；已存在的段跳过）
    if (destDir.length > 0) {
      const segs: string[] = destDir.split('/');
      for (let i = 1; i <= segs.length; i++) {
        const dirRel: string = segs.slice(0, i).join('/');
        const dirAbs: string = registry.absoluteIn(vaultId, dirRel);
        if (!fileIo.accessSync(dirAbs)) {
          fileIo.mkdirSync(dirAbs);
        }
      }
    }
    const unique: string = isDir
      ? NoteService.uniqueDirPath(registry, vaultId, target)
      : NoteService.uniqueRelPath(registry, vaultId, target);
    const copiedDrafts: boolean = await NoteDraftService.copySubtree(
      registry, vaultId, relPath, vaultId, unique, isDir);
    try {
      fileIo.renameSync(registry.absoluteIn(vaultId, relPath),
        registry.absoluteIn(vaultId, unique));
    } catch (error) {
      if (copiedDrafts) {
        NoteDraftService.cleanupOrphans(registry);
      }
      const err = error as Error;
      throw new Error(err.message);
    }
    try {
      await NoteDraftService.discardPath(registry, vaultId, relPath);
    } catch (error) {
      // 新路径草稿已先写好；下次启动会清理正式源文件已不存在的旧草稿。
    }
    FullTextSearchService.pathRetargeted(vaultId, relPath, unique, isDir);
    WikiLinkService.pathRetargeted(vaultId);
    const referenceUpdates: WikiLinkUpdateReport = await WikiLinkService.rewriteReferences(
      registry, vaultId, relPath, unique, isDir, async (path: string, content: string): Promise<void> => {
        await NoteService.saveNote(registry, vaultId, path, content);
      });
    hilog.info(NOTE_DOMAIN, NOTE_TAG, '移动 %{public}s → %{public}s', relPath, unique);
    return { path: unique, referenceUpdates: referenceUpdates };
  }
}
