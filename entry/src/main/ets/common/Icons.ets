/**
 * Icons.ets —— 统一描边图标（v0.2 §3.5 需求 4.7 的**兜底方案**）
 *
 * ⚠️ 为什么不用 `SymbolGlyph` + `sys.symbol.*`（J-2 核实结论）：
 * 在本地 SDK 里**能核实到的 symbol id 只有 3 个**
 * （`sys.symbol.open_sidebar` / `chevron_down` / `chevron_forward`，见
 *  `sdk/default/openharmony/ets/component/*.d.ts` 的注释示例），
 * 覆盖不了文件树需要的 文件夹 / 文档 / 收起 等图标。
 * 按 AGENTS.md 铁律「禁止凭记忆编 sys.symbol.* 资源 id」，本版本**全部自绘**。
 * 4.7 的硬要求是「风格统一、不混两套」——自绘一套 24 viewBox 描边图标即可满足。
 *
 * ⚠️ 为什么不用 `Shape().viewPort()` 缩放（实测踩坑）：
 * 模拟器实测 viewPort 不缩放子 Path，图标被渲染成几个像素的点（2026-10-18）。
 *
 * ⚠️ 为什么缩放系数要乘 `vp2px(1)`：`Path.commands` 的坐标单位是 **px**，
 * 而 `.width(size)` 的 size 是 **vp**。直接按 24→size 缩放的话，图标只会占容器的一小部分
 * （实测在 460dpi 屏上只有 35% 大小，看起来像个点）。所以系数 = `vp2px(size) / 24`。
 *
 * 所有图标只用直线命令（M/L/H/V/Z，**不用弧线 a/A**）：这样路径里每个数字都是坐标，
 * 可以安全整体乘系数；弧线命令里的 flag 是 0/1，缩放会破坏语义。
 * 约定：**新增图标一律不许用弧线**。
 */

/**
 * 图标路径（24 viewBox，只用直线命令）。
 * 坐标来源：`docs/prototype/index.html` 的内联 SVG（弧线图标已改写为折线）。
 */
const P_MENU: string = 'M4 7h16M4 12h16M4 17h16';
const P_BACK: string = 'M15 5l-7 7 7 7';
const P_CHEVRON_DOWN: string = 'M6 9.5l6 6 6-6';
const P_CHEVRON_UP: string = 'M6 14.5l6-6 6 6';
const P_CHEVRON_RIGHT: string = 'M9 5l7 7-7 7';
// 搜索（放大镜）：圆环用折线近似，遵守本文件不使用弧线的约定
const P_SEARCH: string = 'M10.8 4.3L13.29 4.79L15.39 6.21L16.81 8.31L17.3 10.8L16.81 13.29L15.39 15.39L13.29 16.81L10.8 17.3L8.31 16.81L6.21 15.39L4.79 13.29L4.3 10.8L4.79 8.31L6.21 6.21L8.31 4.79Z M16 16L20.5 20.5';
const P_COLLAPSE: string = 'M11 5l-5 7 5 7M18 5l-5 7 5 7';
const P_FOLDER: string = 'M3 6h6l2 2h10v11H3z';
const P_DOC: string = 'M7 3h6l4 4v14H7zM13 3v7h4';
const P_PLUS: string = 'M12 5v14M5 12h14';
const P_RENAME: string = 'M4 20h4L19 9l-4-4L4 16zM14 6l4 4';
const P_MOVE: string = 'M4 12h16M9 7l-5 5 5 5M15 7l5 5-5 5';
const P_TRASH: string = 'M4 7h16M10 4h4M6 7l1 14h10l1-14M10 11v6M14 11v6';
// 同步（refresh）：3/4 圆环 + 箭头（纯折线逼近，无弧线）
const P_SYNC: string = 'M20 12L17.66 17.66L12 20L6.34 17.66L4 12L6.34 6.34L12 4M12 4L15.5 5.5M12 4L13.5 8.5';
// 设置（sliders）：三条横线 + 三个竖向旋钮（纯直线）
const P_SETTINGS: string = 'M4 7h16M12 4v6M4 12h14M8 9v6M4 17h18M14 14v6';

/** 名字 → 路径；未知名字返回空串（画不出东西，但不会崩） */
function pathOf(name: string): string {
  if (name === 'menu') {
    return P_MENU;
  } else if (name === 'back') {
    return P_BACK;
  } else if (name === 'chevronDown') {
    return P_CHEVRON_DOWN;
  } else if (name === 'chevronUp') {
    return P_CHEVRON_UP;
  } else if (name === 'chevronRight') {
    return P_CHEVRON_RIGHT;
  } else if (name === 'search') {
    return P_SEARCH;
  } else if (name === 'collapse') {
    return P_COLLAPSE;
  } else if (name === 'folder') {
    return P_FOLDER;
  } else if (name === 'doc') {
    return P_DOC;
  } else if (name === 'plus') {
    return P_PLUS;
  } else if (name === 'rename') {
    return P_RENAME;
  } else if (name === 'move') {
    return P_MOVE;
  } else if (name === 'trash') {
    return P_TRASH;
  } else if (name === 'sync') {
    return P_SYNC;
  } else if (name === 'settings') {
    return P_SETTINGS;
  }
  return '';
}

/**
 * 把 24 viewBox 的路径按目标尺寸等比缩放（每个数字 × k）。
 * 仅对「纯直线命令」路径成立 —— 弧线命令的 flag 位（0/1）不能被缩放。
 */
function scalePath(cmd: string, k: number): string {
  const re: RegExp = new RegExp('-?[0-9]+(?:\\.[0-9]+)?', 'g');
  const replaced: string = cmd.replace(re, (m: string): string => {
    const v: number = parseFloat(m) * k;
    return (Math.round(v * 100) / 100).toString();
  });
  return replaced;
}

/**
 * 描边图标。
 * @param name 图标名（见上方 P_* 常量）
 * @param size 边长（vp）。**触控热区由外层容器负责 ≥48**（Size.touch）
 * @param color 颜色，传 `$r('app.color.text_secondary')` 等 token
 * @param strokeWidth 线宽，默认 2（24 viewBox 下的标准描边）
 */
@Builder
export function Icon(name: string, size: number, color: ResourceColor, strokeWidth: number = 2) {
  Path({ commands: scalePath(pathOf(name), vp2px(size) / 24) })
    .width(size)
    .height(size)
    .fillOpacity(0)
    .stroke(color)
    .strokeWidth(strokeWidth)
    .strokeLineCap(LineCapStyle.Round)
    .strokeLineJoin(LineJoinStyle.Round)
}
