import { Breakpoint } from './Breakpoint';
import { Size, Space } from '../common/Tokens';

export const DEFAULT_NAV_RATIO: number = 1 / 3;
export const DEFAULT_CONTENT_RATIO: number = 1 / 2;
export const MIN_NAV_RATIO: number = 0.22;
export const MAX_NAV_RATIO: number = 0.46;

/** Window geometry, not fold-status enums or prototype presets, identifies a compact landscape window. */
export function isSingleLandscapeWindow(widthVp: number, heightVp: number): boolean {
  return widthVp >= Breakpoint.MD_THRESHOLD_VP &&
    widthVp < Breakpoint.LG_THRESHOLD_VP &&
    heightVp > 0 && heightVp < Breakpoint.MD_THRESHOLD_VP &&
    widthVp > heightVp;
}

export function navigationWidth(
  widthVp: number,
  savedRatio: number,
  contentPaneCount: number,
  splitterCount: number
): number {
  const ratio: number = savedRatio >= MIN_NAV_RATIO && savedRatio <= MAX_NAV_RATIO
    ? savedRatio : DEFAULT_NAV_RATIO;
  return clampNavigationWidth(widthVp * ratio, widthVp, contentPaneCount, splitterCount);
}

export function clampNavigationWidth(
  candidateVp: number,
  windowWidthVp: number,
  contentPaneCount: number,
  splitterCount: number
): number {
  if (windowWidthVp <= 0) {
    return Size.paneMinW;
  }
  const minPaneTotal: number = (contentPaneCount + 1) * Size.paneMinW + splitterCount * Space.s4;
  if (windowWidthVp < minPaneTotal) {
    return Math.max(0, Math.min(candidateVp, windowWidthVp - contentPaneCount * Size.paneMinW -
      splitterCount * Space.s4));
  }
  const minRatioVp: number = windowWidthVp * MIN_NAV_RATIO;
  const maxByContent: number = windowWidthVp - contentPaneCount * Size.paneMinW - splitterCount * Space.s4;
  const minVp: number = Math.max(Size.paneMinW, minRatioVp);
  const maxVp: number = Math.max(minVp, Math.min(windowWidthVp * MAX_NAV_RATIO, maxByContent));
  return Math.max(minVp, Math.min(maxVp, candidateVp));
}

export interface MdPaneWidths {
  /** 目录栏在屏内的宽度（收起时 0） */
  nav: number;
  /** 左栏宽度 */
  left: number;
  /** 右栏宽度（目录推入时为 0） */
  right: number;
}

/**
 * md（物理双屏）等屏布局的三段宽度。
 *
 * ⚠️ 这里以前是硬编码「目录 50% / 左 50% / 右 50%×(1-progress)」，
 * 既不读 contentRatio，也不读 navigationRatio，导致设置页的「恢复等分栏宽」
 * 在双屏下点了毫无反应（v1.18 前的栏宽 bug 修复）。
 * 现在左右栏按 contentRatio 分配；ratio=0.5（默认值，也是重置后的值）时
 * 与原来的硬编码逐点一致，等屏观感不变。
 */
export function mdPaneWidths(
  windowWidthVp: number,
  navigationWidthVp: number,
  sidebarProgress: number,
  contentRatio: number
): MdPaneWidths {
  if (windowWidthVp <= 0) {
    return { nav: 0, left: 0, right: 0 };
  }
  const progress: number = Math.max(0, Math.min(1, sidebarProgress));
  const nav: number = Math.max(0, navigationWidthVp) * progress;
  const contentWidth: number = Math.max(0, windowWidthVp - nav);
  const ratio: number = clampContentRatio(contentRatio, contentWidth);
  // 目录推入时右栏收起、左栏占满剩余（沿用原 md 的推入语义）。
  const right: number = contentWidth * (1 - ratio) * (1 - progress);
  const left: number = Math.max(0, contentWidth - right);
  return { nav: nav, left: left, right: right };
}

export function clampContentRatio(candidateRatio: number, contentWidthVp: number): number {
  if (contentWidthVp <= 0) {
    return DEFAULT_CONTENT_RATIO;
  }
  const minRatio: number = Size.paneMinW / contentWidthVp;
  if (minRatio >= 0.5) {
    return DEFAULT_CONTENT_RATIO;
  }
  return Math.max(minRatio, Math.min(1 - minRatio, candidateRatio));
}
