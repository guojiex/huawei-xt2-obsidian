/**
 * FocusRequest.ets —— 安全焦点请求（全应用统一收口）。
 *
 * ⚠️ 踩坑（两次 DFX JSCrash 实测：2026-11-06 空栏收焦、2026-11-08 完成编辑收焦）：
 * `UIContext.getFocusController().requestFocus(id)` 在目标组件不存在 / 不可见 / 已禁用时
 * **同步抛 BusinessError 150003**（"The component doesn't exist, is currently invisible,
 * or has been disabled."）。在 onClick 等回调里裸调且未捕获 → 异常直达虚拟机顶层 →
 * JSCrash 进程退出（闪退）。模拟器同样触发（2026-11-08 x86_64 模拟器 jscrash 实证）。
 *
 * v1.46（api_notes L-20，官方答复）：错误码族共三个 ——
 * - 150001 组件本身不可获焦（focusable 为 false 或默认无获焦能力）
 * - 150002 祖先节点不可获焦
 * - 150003 不在树上 / 不存在（id 错误、已销毁、未挂载）
 * ArkTS 侧无「静默返回」安全变体；本兜底即官方推荐的调用侧 try-catch 姿势。
 *
 * 焦点请求只是「尽力而为」的 UX 增强，落空不致命；所有调用点一律经本助手兜底。
 * 日志不记录 focusId：文件树行焦点 id 含笔记路径，按隐私红线（AGENTS.md 硬约束 16）
 * 不让路径进日志；错误码本身不含路径，可记录以便排查。
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export class FocusRequest {
  private static readonly DOMAIN: number = 0x0000;
  private static readonly TAG: string = 'FocusRequest';
  private static readonly CODE_UNFOCUSABLE: number = 150001;
  private static readonly CODE_UNFOCUSABLE_ANCESTOR: number = 150002;
  private static readonly CODE_NOT_ON_TREE: number = 150003;

  /** 请求焦点；按官方错误码族区分失败原因（见文件头注释），吞错不崩溃 */
  static safely(uiContext: UIContext, focusId: string): void {
    try {
      uiContext.getFocusController().requestFocus(focusId);
    } catch (error) {
      const err = error as BusinessError;
      if (err.code === FocusRequest.CODE_UNFOCUSABLE) {
        hilog.warn(FocusRequest.DOMAIN, FocusRequest.TAG, '焦点请求失败：目标组件不可获焦(150001)，已忽略');
      } else if (err.code === FocusRequest.CODE_UNFOCUSABLE_ANCESTOR) {
        hilog.warn(FocusRequest.DOMAIN, FocusRequest.TAG, '焦点请求失败：祖先节点不可获焦(150002)，已忽略');
      } else if (err.code === FocusRequest.CODE_NOT_ON_TREE) {
        hilog.warn(FocusRequest.DOMAIN, FocusRequest.TAG, '焦点请求未命中目标组件(150003 不在树上或不存在)，已忽略');
      } else {
        hilog.warn(FocusRequest.DOMAIN, FocusRequest.TAG, '焦点请求失败 code=%{public}d，已忽略', err.code);
      }
    }
  }
}
