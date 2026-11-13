/**
 * ErrorCode.ets —— 从任意错误对象安全读数字 code 的单一真源
 *
 * 捕获侧拿到的可能是 BusinessError（系统接口）、仓库内自定义 Error 子类
 * （AtomicWriteError / ProbeWriteError / VaultAccessError，字段统一叫 `code`）
 * 或不明形状，统一走这里取数字 code，取不到返回 -1。
 */

/** 带数字 code 的错误形状（BusinessError 与仓库内自定义错误类的公共口径）。 */
export interface ErrorCodeCarrier {
  code?: number;
}

/** 从错误对象读数字 code，读不到返回 -1。 */
export function errorCodeOf(error: Object): number {
  const carry: ErrorCodeCarrier = error as ErrorCodeCarrier;
  if (carry !== undefined && carry !== null && typeof carry.code === 'number') {
    return carry.code;
  }
  return -1;
}
