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
