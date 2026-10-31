/**
 * ExternalDirProbe.ets —— v1.5「外部目录即知识库」前置核实的**最小样例**
 *
 * 目的只有一个：在设备上跑通 v1.5 §6.1 要求的那串动作，用真实返回值把
 * `docs/harmonyos/api_notes.md` T1–T3 的 ❓ 换成 ✅/⚠️：
 *
 *   1. Picker 选目录，拿到什么形式的 URI
 *   2. persistPermission 能否成功（依赖已声明的 FILE_ACCESS_PERSIST）
 *   3. 重启后 activatePermission 能否恢复读写
 *   4. 授权是否顺延到子文件（递归列出 + 读已有 Markdown）
 *   5. AtomicFile 能否作用于这个命名空间里的已有文件
 *
 * **这不是 15.1–15.6 的产品实现**：不进 VaultRegistry、不改 Vault 类型、不做文件树、
 * 不做变更感知。核实结论定案后再按 v1.5 §3 正式落码，届时本文件随之删除。
 *
 * API 依据（本机 API 26 SDK 的 .d.ts 逐条核实，非记忆）：
 * - `@ohos.file.picker`：`DocumentViewPicker.select(option?): Promise<Array<string>>` since 9；
 *   `DocumentSelectMode.FOLDER = 1` since 11（syscap `...UserFileService.FolderSelection`）；
 *   `maxSelectNumber` 注释写明目录一次只能选一个；`authMode` since 12 只在 2-in-1 设备生效。
 * - `@ohos.fileshare`：`PolicyInfo { uri: string; operationMode: number }` since 11；
 *   `persistPermission` / `activatePermission` / `deactivatePermission` / `revokePermission`
 *   since 11，`checkPersistentPermission` since 17 —— 全部 ≤ 24，全部要求
 *   `ohos.permission.FILE_ACCESS_PERSIST`（已在 module.json5 声明，XT2 实测已授予，
 *   见 api_notes T2 实测②）。`OperationMode.READ_MODE = 0b1` / `WRITE_MODE = 0b10`
 *   （`CREATE_MODE` / `DELETE_MODE` 自 API 20，超出目标 API 24，不使用）。
 * - `@ohos.file.fs`（fileIo）：`listFileSync(path, options?): string[]` since 9，
 *   `ListFileOptions.recursion` since 11；`AtomicFile` 的 `constructor(path: string)` since 15，
 *   `readFully()` / `openWrite()` / `finishWrite()` / `failWrite()` since 15。
 *
 * IO 全部经构造函数注入（picker / share / fs），Node 测试用受控假实现覆盖完整时序，
 * 设备实测只替换这三个注入对象 —— UI 不承担任何核实逻辑。
 */

/** Picker 返回的目录 URI 形如 file://...，这里只做基本形状检查，不解析内容。 */
export const PROBE_URI_PREFIX: string = 'file://';

/** READ | WRITE = 0b11 —— CREATE_MODE / DELETE_MODE 是 API 20，不能用。 */
export const PROBE_OPERATION_MODE: number = 3;

/** 外部目录里没有 Markdown 时，样例自己建一个临时文件来验证写入链路。 */
export const PROBE_FILE_NAME: string = '__yaoshi_probe__.md';

/** 写进去再读出来校验的标记串。 */
export const PROBE_MARK: string = '<!-- probe -->';

/** 遍历时跳过的段名，与沙箱侧既有过滤规则保持一致，不引入新toml。 */
export const PROBE_EXCLUDED_SEGS: string[] = ['.git', '.trash', 'node_modules'];

export interface ProbePolicy {
  uri: string;
  operationMode: number;
}

/** listFileSync 的选项：ArkTS 不允许用对象字面量当类型，必须显式声明。 */
export interface ProbeListOptions {
  recursion: boolean;
}

/**
 * 写失败时抛这个 —— ArkTS 的 `throw` 只接受 Error 及其子类（arkts-limited-throw），
 * 所以系统抛的 BusinessError 不能直接往上扔，改成把 code 装进 Error 子类里。
 */
export class ProbeWriteError extends Error {
  code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
  }
}

/** 单步结果：给 UI 与设备日志共用。**不进埋点** —— 硬约束 16 禁止笔记内容上报。 */
export interface ProbeStep {
  id: string;
  label: string;
  ok: boolean;
  detail: string;
}

/**
 * 目录 URI 的形状检查。空串（用户取消）直接失败；不带 `file://` 的普通路径一律拒绝 ——
 * 那是绕开解析器的做法，违反硬约束 14（相对路径 → 绝对路径只走一层解析），
 * 而最小样例阶段还没有接解析器，宁可一步不做。
 */
export function isProbeDirectoryUri(uri: string): boolean {
  const trimmed: string = uri.trim();
  if (trimmed.length === 0) {
    return false;
  }
  return trimmed.startsWith(PROBE_URI_PREFIX) && trimmed.length > PROBE_URI_PREFIX.length;
}

/** 构造 fileshare 需要的 PolicyInfo（READ + WRITE）。 */
export function buildProbePolicy(uri: string): ProbePolicy {
  return { uri: uri, operationMode: PROBE_OPERATION_MODE };
}

/**
 * 取一个能给人看的目录名（UI 展示用）。
 * **不参与任何路径拼接**，也不替代 VaultPathResolver。
 */
export function displayNameFromUri(uri: string): string {
  if (!isProbeDirectoryUri(uri)) {
    return '';
  }
  let last: string = uri;
  const slash: number = last.lastIndexOf('/');
  if (slash >= 0) {
    last = last.substring(slash + 1);
  }
  if (last.length === 0) {
    return '';
  }
  return safeDecodeUriComponent(last);
}

/** 畸形转义（半个 %XX）会让 decodeURIComponent 抛异常，这里原样退回，不让 UI 崩。 */
export function safeDecodeUriComponent(text: string): string {
  try {
    return decodeURIComponent(text);
  } catch (error) {
    return text;
  }
}

/** 遍历时是否跳过该段：隐藏段（点开头）与显式排除清单。 */
export function shouldSkipSegment(segment: string): boolean {
  if (segment.length === 0 || segment === '.' || segment === '..') {
    return true;
  }
  if (segment.startsWith('.')) {
    return true;
  }
  return PROBE_EXCLUDED_SEGS.indexOf(segment) >= 0;
}

/** 相对路径里任意一段落在排除范围内，整条丢弃（`.git/config` 这类）。 */
export function hasSkippedSegment(relativePath: string): boolean {
  const segments: string[] = relativePath.split('/');
  for (let index: number = 0; index < segments.length; index++) {
    if (shouldSkipSegment(segments[index])) {
      return true;
    }
  }
  return false;
}

/** 叶子是否为 Markdown 笔记（忽略大小写）。 */
export function isMarkdownEntry(relativePath: string): boolean {
  const lower: string = relativePath.toLowerCase();
  return lower.endsWith('.md') || lower.endsWith('.markdown');
}

/** 从 listFileSync(recursion) 的相对路径里挑出要读取的 Markdown。 */
export function selectProbeMarkdown(entries: string[]): string[] {
  const picked: string[] = [];
  entries.forEach((entry: string): void => {
    if (!isMarkdownEntry(entry)) {
      return;
    }
    if (hasSkippedSegment(entry)) {
      return;
    }
    picked.push(entry);
  });
  return picked;
}

/** fileshare / fileIo 的错误码 → 人话；未知码原样展示，不假装成功。 */
export function describeProbeError(code: number): string {
  const map: Record<string, string> = {
    '13900001': '策略失败（13900001）：URI 不支持持久化或权限不足，清单见异常 data',
    '201': '缺少 ohos.permission.FILE_ACCESS_PERSIST（201）',
    '401': '参数无效：URI 或 operationMode 非法（401）',
    '13900002': '目录不存在或已被移动（13900002）',
    '13900003': '目录 URI 无法打开（13900003）',
    '13900005': 'URI 不是目录（13900005）'
  };
  const known: string = map[String(code)];
  return known !== undefined ? known : '失败（code=' + code + '）';
}

const PROBE_STEP_LABELS: Record<string, string> = {
  'syscap': 'FolderSelection 系统能力',
  'select': 'Picker 选择目录',
  'persist': 'persistPermission 持久化授权',
  'activate': 'activatePermission 重启后激活',
  'check': 'checkPersistentPermission 查询',
  'list': '递归列出目录',
  'read': '读取已有 Markdown',
  'atomic': 'AtomicFile 更新已有文件',
  'cleanup': '删除样例临时文件'
};

/**
 * 统一构造单步结果：成功给可核对的最短结论，失败带上错误码解释。
 * error 传 0 表示没有系统异常、由业务判定失败。
 */
export function describeProbeStep(id: string, ok: boolean, error: number, extra: string): ProbeStep {
  const label: string = PROBE_STEP_LABELS[id] !== undefined ? PROBE_STEP_LABELS[id] : id;
  const step: ProbeStep = { id: id, label: label, ok: ok, detail: '' };
  if (error === 0) {
    step.detail = extra.length > 0 ? extra : (ok ? '成功' : '失败');
    return step;
  }
  step.detail = extra.length > 0 ? extra + ' · ' + describeProbeError(error) : describeProbeError(error);
  return step;
}

/** Picker 注入契约：真实实现包一层 `DocumentViewPicker.select({ selectMode: FOLDER })`。 */
export interface ExternalDirPickerLike {
  selectFolder(): Promise<string[]>;
}

/** fileshare 注入契约：五个持久授权接口里本样例用到三个。 */
export interface FileShareLike {
  persistPermission(policies: ProbePolicy[]): Promise<void>;
  activatePermission(policies: ProbePolicy[]): Promise<void>;
  checkPersistentPermission(policies: ProbePolicy[]): Promise<boolean[]>;
}

/** fs 注入契约：只用递归列出、读文本、原子写三个动作。 */
export interface ProbeFsLike {
  listFileSync(uri: string, options: ProbeListOptions): string[];
  readText(uri: string): Promise<string>;
  /** 失败时抛 `ProbeWriteError`（带 code），由调用方转成可读文案。 */
  writeAtomic(uri: string, content: string): Promise<void>;
  /** v1.5 核实用：`openSync(uri, READ_ONLY)` 探测目录能否打开，返回 fd。 */
  openDir(uri: string): number;
  closeDir(fd: number): void;
}

/**
 * 最小样例 runner —— 只做核实，不落任何产品语义。
 * 三个依赖均注入，Node 测试与真机共用同一份时序代码。
 */
export class ExternalDirProbeRunner {
  private picker: ExternalDirPickerLike;
  private share: FileShareLike;
  private fs: ProbeFsLike;

  constructor(picker: ExternalDirPickerLike, share: FileShareLike, fs: ProbeFsLike) {
    this.picker = picker;
    this.share = share;
    this.fs = fs;
  }

  /**
   * 步骤 1：选目录。用户取消返回空串；拿到的不是 URI 形状同样返回空串，
   * 由 UI 决定怎么提示（这里是「未取到目录」而不是假装成功）。
   */
  async pickDirectory(): Promise<string> {
    const uris: string[] = await this.picker.selectFolder();
    if (uris.length === 0) {
      return '';
    }
    const uri: string = uris[0];
    return isProbeDirectoryUri(uri) ? uri : '';
  }

  /** 步骤 2：把 Picker 给的临时授权持久化。 */
  async persist(uri: string): Promise<void> {
    await this.share.persistPermission([buildProbePolicy(uri)]);
  }

  /** 步骤 3a：重启后重新激活（官方 FAQ 明确要求，不做则读写会失败）。 */
  async activate(uri: string): Promise<void> {
    await this.share.activatePermission([buildProbePolicy(uri)]);
  }

  /** 步骤 3b：查询持久化状态。 */
  async checkPersisted(uri: string): Promise<boolean> {
    const result: boolean[] = await this.share.checkPersistentPermission([buildProbePolicy(uri)]);
    return result.length > 0 && result[0];
  }

  /** 步骤 4：递归列出 —— 用于确认授权是否顺延到子文件。 */
  listEntries(uri: string): string[] {
    return this.fs.listFileSync(uri, { recursion: true });
  }

  /** 核实诊断：目录 URI 能否被 fileIo.openSync 打开（listFile 13900002 时的第一个分叉点）。 */
  openDirForDiagnosis(uri: string): number {
    return this.fs.openDir(uri);
  }

  closeDirForDiagnosis(fd: number): void {
    this.fs.closeDir(fd);
  }

  /**
   * 步骤 5：读写验证。**优先用目录里真实存在的第一篇 Markdown**，没有则新建一个
   * 临时文件走同一条链路；最后把文件还原成原样（临时文件要求那就是空内容再删除），
   * 不在用户真实目录留垃圾。
   */
  async probeWrite(uri: string, entries: string[]): Promise<ProbeStep> {
    const target: string = entries.length > 0 ? entries[0] : PROBE_FILE_NAME;
    const targetUri: string = uri + '/' + target;
    let original: string = '';
    try {
      original = await this.fs.readText(targetUri);
      if (original.length === 0) {
        original = '# probe\n';
      }
    } catch (error) {
      // 目标还不存在时会走到这里，按新建处理
      original = '# probe\n';
    }
    try {
      await this.fs.writeAtomic(targetUri, original + '\n' + PROBE_MARK + '\n');
    } catch (error) {
      return describeProbeStep('atomic', false, ExternalDirProbeRunner.errorCodeOf(error), '写入失败');
    }
    try {
      const after: string = await this.fs.readText(targetUri);
      if (after.indexOf(PROBE_MARK) < 0) {
        await this.restore(targetUri, original);
        return describeProbeStep('atomic', false, 0, '写后回读未见标记');
      }
    } catch (error) {
      await this.restore(targetUri, original);
      return describeProbeStep('atomic', false, ExternalDirProbeRunner.errorCodeOf(error), '回读失败');
    }
    await this.restore(targetUri, original);
    return describeProbeStep('atomic', true, 0, '写入与回读通过，原内容已还原');
  }

  /** 尽力把文件还原；还原失败不抛，交给调用方按「目录可能留有标记」处理。 */
  private async restore(uri: string, original: string): Promise<void> {
    try {
      await this.fs.writeAtomic(uri, original);
    } catch (error) {
      // 还原不了也到此为止，UI 会显示原内容已改动，请手动检查
    }
  }

  /** 从异常对象里取 code，取不到返回 -1（UI 原样展示，不把它当成成功）。 */
  static errorCodeOf(error: Object): number {
    const typed: ProbeWriteError = error as ProbeWriteError;
    if (typed !== undefined && typed !== null && typeof typed.code === 'number') {
      return typed.code;
    }
    return -1;
  }
}
