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
 * 本文件当前只实现「新建」（v0.2 M1 的验证前提）；
 * 保存 / 读取 / 重命名 / 移动 / 删除分别在 M2、1.6 落到这里。
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
   * - 全部为空 → 抛错，由调用方禁用确认按钮。
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
}
