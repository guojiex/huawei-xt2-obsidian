/**
 * CrashGuard.ets —— 全局未捕获 JS 异常兜底（v1.46，api_notes L-20）。
 *
 * 背景：两次 DFX JSCrash（2026-11-06 a849690、2026-11-08 完成编辑收焦，api_notes L-19）
 * 都是裸调同步抛错 API 未捕获直达虚拟机顶层。调用侧 try-catch（如 FocusRequest.safely）
 * 是第一防线；本类是**崩溃发生后的兜底与观测**（官方定位），不替代就地捕获。
 *
 * 实现（官方示例结构 + 本机 SDK 声明复核，声明行号见 qa/2026-11-08 归档）：
 * - `errorManager.setDefaultErrorHandler(handler)` since 21（API 24 可用），
 *   **仅主线程**（子线程抛 16000205）→ 只能在 EntryAbility.onCreate 安装；
 *   返回**上一次注册的处理器**，发生 JS_CRASH 时链式回调；
 * - 无前序处理器时按官方示例用 `process.ProcessManager().exit(0)` 同步退出
 *   （吞掉异常继续跑会让应用带病运行，对笔记应用比崩溃更危险）。
 *
 * 🔴 隐私红线（AGENTS.md 硬约束 16）：兜底日志只进本地 hilog 诊断，
 * 禁止接入 hiAppEvent / 埋点 / 第三方上报；reason.message 可能含路径等运行时数据，
 * 不得复制进埋点载荷。
 */
import { errorManager } from '@kit.AbilityKit';
import { process } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class CrashGuard {
  private static readonly DOMAIN: number = 0x0000;
  private static readonly TAG: string = 'CrashGuard';
  private static previousHandler: errorManager.ErrorHandler | undefined = undefined;
  private static installed: boolean = false;

  /** 在主线程（EntryAbility.onCreate）安装全局 JS_CRASH 兜底；重复调用只装一次 */
  static install(): void {
    if (CrashGuard.installed) {
      return;
    }
    try {
      CrashGuard.previousHandler = errorManager.setDefaultErrorHandler((reason: Error): void => {
        hilog.error(CrashGuard.DOMAIN, CrashGuard.TAG,
          '未捕获 JS 异常 name=%{public}s message=%{public}s（详见 faultlogger）',
          reason.name, reason.message);
        if (typeof CrashGuard.previousHandler === 'function') {
          CrashGuard.previousHandler(reason);
        } else {
          // 官方示例：无前序处理器时同步退出，不让异常被吞后带病运行
          const processManager = new process.ProcessManager();
          processManager.exit(0);
        }
      });
      CrashGuard.installed = true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(CrashGuard.DOMAIN, CrashGuard.TAG, '全局异常兜底注册失败 code=%{public}d，保持系统默认崩溃处理', err.code);
    }
  }
}
