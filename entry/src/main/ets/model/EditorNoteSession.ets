/**
 * EditorNoteSession —— 「编辑器当前持有的文档」的配对账本。
 *
 * 背景（2026-11-08 真机实锤的跨笔记串写，Index.ets 保存链重构）：
 * 编辑器正文住在 Web（另一进程），文件身份原来记在 ArkTS 的 6 个散落字段里
 * （committedXxxPath / committedXxxVaultId / lastSavedText / rightLastSavedText）。
 * 「加载笔记」是多步异步流程，中途被打断（被更新的打开请求取代）时字段组合撕裂：
 * 编辑器已持有 B 笔记正文、账本仍写着 A 文件，而保存路径无条件信任账本，
 * 于是把 B 的正文逐字节写进了 A 文件（任务清单 372B → 快速上手.md）。
 *
 * 现在的配对方式：
 * - EditorBridge.setContent 返回本次下发的 documentRevision；Web 侧把 revision 与正文
 *   存在同一线程同一批次（requestContent 回包同时携带 b64 与 revision）——
 *   内容与身份在持有内容的一侧原子绑定，编辑器是自己正文的权威；
 * - 本会话在 setContent 完成后立刻创建（或镜像同步后更新 revision），
 *   记录 {vaultId, path, baseline, revision}；
 * - 保存（flushSave / flushRightSave）必须同时满足：
 *   ① 目标 (vaultId, path) 与当前会话一致；
 *   ② 编辑器回包的 revision === 会话记录的 revision；
 *   ③ 会话对象仍是当前栏的活动会话。
 *   任一不满足 → 拒绝写入。撕裂窗口内的任何时序都退化为「少一次自动保存」，
 *   绝不会「存错文件」——不一致从危险降级为无害。
 *
 * 修改纪律：
 * - path / vaultId 只读：换文档 = 换会话对象，禁止原地改；
 * - baseline 只在「读到磁盘版本」或「保存成功」时更新；
 * - revision 只在 setContent（加载 / 镜像同步）后更新为该次返回值。
 */
export class EditorNoteSession {
  readonly vaultId: string;
  readonly path: string;
  /** 最近一次「已落盘或已从磁盘读取」的全文镜像（旧 lastSavedText / rightLastSavedText）。 */
  baseline: string;
  /** 加载（或镜像同步）该内容时 setContent 下发并回响的 documentRevision。 */
  revision: number;

  constructor(vaultId: string, path: string, baseline: string, revision: number) {
    this.vaultId = vaultId;
    this.path = path;
    this.baseline = baseline;
    this.revision = revision;
  }

  isFor(vaultId: string, path: string): boolean {
    return this.vaultId === vaultId && this.path === path;
  }
}
