/**
 * PageGutter.ets —— 页面级左右留白（一多缩进，纯逻辑，无 UI / 无系统调用）。
 *
 * 宽屏留白随断点递增：窄屏沿用调用方原有值（不改变手机观感），
 * md（折叠屏展开 / 中宽窗口）24vp，lg（平板 / 阔折叠 / 三屏）32vp。
 * 断点来源与 Breakpoint.ets 一致：只按窗口宽度（vp）判档，不用折叠形态接口。
 */

import { Breakpoint } from './Breakpoint';
import { Space } from '../common/Tokens';

/** md 档页面左右留白：24vp */
export const PAGE_GUTTER_MD: number = Space.s6;
/** lg 档页面左右留白：32vp */
export const PAGE_GUTTER_LG: number = Space.s8;

/**
 * @param breakpoint 当前断点（AppStorage 'breakpoint' 或页面透传）
 * @param windowHeightVp 窗口高度（vp）；矮窗口（<480）与窄屏一样沿用紧凑值
 * @param compactGutter 窄屏 / 矮屏下该页面原有的左右留白
 */
export function pageGutter(breakpoint: string, windowHeightVp: number, compactGutter: number): number {
  if (breakpoint === Breakpoint.SM || (windowHeightVp > 0 && windowHeightVp < 480)) {
    return compactGutter;
  }
  return breakpoint === Breakpoint.LG ? PAGE_GUTTER_LG : PAGE_GUTTER_MD;
}
