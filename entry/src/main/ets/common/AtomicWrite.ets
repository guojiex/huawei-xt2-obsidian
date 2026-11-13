/**
 * AtomicWrite.ets —— `fileIo.AtomicFile` 原子写公共工具（单一真源）
 *
 * 统一各模型服务此前的 7 份手抄样板，语义以 NoteService.saveNote 的实测结论为准：
 * - 严格照官方示例流：`startWrite()` → `stream.end(content, 'utf-8', 回调)` → 回调里 `finishWrite()`；
 * - ⚠️ **绝不在 finishWrite 前调 `stream.close()`**（2026-10-18 真机 cppcrash SIGSEGV 实证，
 *   close+finishWrite 双重释放 native 引用，见 api_notes C1）；
 * - **用 `end` 而非 `write` 收尾**（2026-11-07 API26 x86_64 模拟器实测：write 的回调先于
 *   数据落盘触发，end 的回调才是数据写完点）；
 * - 空内容**不调 end**（Writable.end 禁空串抛 401）：直接 finishWrite 截断为 0 字节；
 * - 超时兜底：写回调超时不触发时 `failWrite()` 回滚并拒绝，不让调用方永久挂起；
 * - 失败一律 `failWrite()` 回滚，不留 .tmp 残留；崩溃/中断时原文件完好。
 */
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 默认写回调超时（ms）。 */
const ATOMIC_WRITE_TIMEOUT_MS: number = 3000;

/**
 * 写失败错误：保留系统 BusinessError 的 code（有则带上），供调用方映射自己的错误类型。
 * 字段名对齐 BusinessError / ProbeWriteError 的 `code`，wrapError 里可直接读。
 */
export class AtomicWriteError extends Error {
  code: number;

  constructor(message: string, code: number = -1) {
    super(message);
    this.code = code;
  }
}

export interface AtomicWriteOptions {
  /** 写回调超时兜底，默认 3000ms。 */
  timeoutMs?: number;
  /** 超时错误文案（用于区分调用场景）。 */
  timeoutMessage?: string;
  /** 把内部阶段错误包装成调用方自己的错误类型；stage ∈ {'startWrite','write','finishWrite'}。 */
  wrapError?: (stage: string, error: Error) => Error;
}

/**
 * 把内部捕获的错误转成 `Error`（带返回类型的工厂：检查器不允许 Error 子类的
 * new 表达式直接出现在 Error 类型的赋值/实参位置）。
 */
function atomicWriteErrorOf(error: Error): Error {
  const err = error as BusinessError;
  return atomicError(err.message, err.code ?? -1);
}

/**
 * 以 `Error` 静态类型直返 `AtomicWriteError`：`new` 子类表达式直接传给显式标注
 * `error: Error` 的形参会触发 arkts-no-structural-typing（ArkTS 的 `Error` 是接口，
 * 子类与 Error 只能结构兼容，见 api_notes.md T9）；经直返包装后静态类型即 Error，语义不变。
 */
function atomicError(message: string, errorCode: number): Error {
  return new AtomicWriteError(message, errorCode);
}

/**
 * 用 AtomicFile 原子写文本。成功 resolve（finishWrite 已完成），失败 reject `Error`
 * （默认 `AtomicWriteError`，可经 wrapError 转成调用方自己的形状），原文件保持完好。
 */
export function atomicWriteText(path: string, content: string,
  options?: AtomicWriteOptions): Promise<void> {
  const timeoutMs: number = options?.timeoutMs ?? ATOMIC_WRITE_TIMEOUT_MS;
  const timeoutMessage: string = options?.timeoutMessage ?? 'AtomicFile 写入回调超时';
  return new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
    const atomicFile: fileIo.AtomicFile = new fileIo.AtomicFile(path);
    let settled: boolean = false;
    let timerId: number = -1;
    const emit = (stage: string, error: Error): void => {
      const wrapped: Error = options?.wrapError !== undefined
        ? options.wrapError(stage, error)
        : error;
      reject(wrapped);
    };
    const fail = (stage: string, error: Error): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (timerId !== -1) {
        clearTimeout(timerId);
      }
      try {
        atomicFile.failWrite();
      } catch (rollbackError) {
        // 回滚本身失败时保留原始写入错误。
      }
      emit(stage, error);
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
        fail('finishWrite', atomicWriteErrorOf(error));
        return;
      }
      settled = true;
      resolve();
    };
    let stream: fileIo.WriteStream;
    try {
      stream = atomicFile.startWrite();
    } catch (error) {
      fail('startWrite', atomicWriteErrorOf(error));
      return;
    }
    timerId = setTimeout((): void => {
      fail('write', new Error(timeoutMessage));
    }, timeoutMs);
    if (content.length === 0) {
      // 空内容不调 end（Writable.end 禁空串会抛 401），直接 finishWrite 即截断为 0 字节。
      commit();
      return;
    }
    try {
      stream.end(content, 'utf-8', (err?: BusinessError): void => {
        if (err !== undefined && err !== null) {
          fail('write', atomicWriteErrorOf(err));
          return;
        }
        commit();
      });
    } catch (error) {
      fail('write', atomicWriteErrorOf(error));
    }
  });
}
