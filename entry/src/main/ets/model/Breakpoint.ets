/**
 * Breakpoint.ets —— 三档断点模型（纯逻辑，无 UI / 无系统调用）
 *
 * 断点必须由窗口宽度（vp）计算：`window.on('windowSizeChange')` + `px2vp()`
 * 是官方推荐的统一断点机制（api_notes.md A3 ✅）；
 * 禁止用 `display.getFoldDisplayMode()` 做形态分支 ——
 * 该接口出于兼容考虑不返回全部形态值（api_notes.md A3）。
 *
 * 阈值 600 / 840 vp 出自 `docs/mvp_design.md` §2。
 */

/** 断点档位常量：'sm' | 'md' | 'lg' */
export class Breakpoint {
  /** 单屏（外屏合起）：< 600vp */
  static readonly SM: string = 'sm';
  /** 双屏展开：[600, 840) vp */
  static readonly MD: string = 'md';
  /** 三屏全展开：>= 840vp */
  static readonly LG: string = 'lg';

  /** md 档下限阈值（含）：600vp */
  static readonly MD_THRESHOLD_VP: number = 600;
  /** lg 档下限阈值（含）：840vp */
  static readonly LG_THRESHOLD_VP: number = 840;
}

/**
 * 半开区间判定：sm < 600，md ∈ [600, 840)，lg >= 840。
 * 边界值（恰好 600 / 840）无重叠无遗漏地落入高档（spec.md Edge Cases）。
 */
export function breakpointFromWidthVp(widthVp: number): string {
  if (widthVp < Breakpoint.MD_THRESHOLD_VP) {
    return Breakpoint.SM;
  }
  if (widthVp < Breakpoint.LG_THRESHOLD_VP) {
    return Breakpoint.MD;
  }
  return Breakpoint.LG;
}
