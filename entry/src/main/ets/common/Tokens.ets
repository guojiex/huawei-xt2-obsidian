/**
 * Tokens.ets —— 设计 token 的**数值部分**（v0.2 §3.5 需求 4.1 / 4.3 / 4.4 / 4.5 / 4.10）
 *
 * 真源：`docs/prototype/v2/index.html` 的 `:root`。
 *   - **颜色**不放这里**：颜色是要跟随系统深色切换的，必须走资源
 *     `entry/src/main/resources/base|dark/element/color.json`，用 `$r('app.color.*')` 引用。
 *     这样深色模式是「另一套 token」而不是浅色反色（需求 4.2）。
 *   - **数值**（间距/圆角/字号/尺寸/动效）放这里：ArkTS 里要做算术（如树缩进 = 层级 × 24），
 *     资源 `$r()` 是 Resource 不能参与运算，所以统一用常量模块。
 *
 * 改值规矩（AGENTS.md 硬约束 17）：改这里必须同步改 v2 原型 `:root`，两边不许漂。
 */
import { curves } from '@kit.ArkUI';

/** 间距：4vp 栅格（4.4）—— 不允许出现 5 / 7 / 9 这类非栅格值 */
export class Space {
  static readonly s1: number = 4;
  static readonly s2: number = 8;
  static readonly s3: number = 12;
  static readonly s4: number = 16;
  static readonly s5: number = 20;
  static readonly s6: number = 24;
  static readonly s8: number = 32;
  static readonly s10: number = 40;
  static readonly s12: number = 48;
  static readonly s16: number = 64;
}

/** 圆角：按场景取值（4.3）—— 同类控件圆角必须一致 */
export class Radius {
  static readonly chip: number = 4;      // 徽标 / 小标签
  static readonly icon: number = 10;     // 图标按钮
  static readonly control: number = 10;  // v2 --small-r
  static readonly card: number = 16;     // 卡片 / 弹窗
  static readonly button: number = 20;   // 按钮 / 菜单
  static readonly menu: number = 16;    // v2 --r
  static readonly dialog: number = 16;
  static readonly snack: number = 18;    // SnackBar
  static readonly full: number = 999;    // 全圆（头像 / 圆形按钮）
}

/** 阴影：映射 v2 `--float-shadow` 的模糊半径。 */
export class Shadow {
  static readonly floatBlur: number = 28;
}

/** 字号阶梯（4.5）—— 三档形态下保持一致，不随断点跳号 */
export class FontSize {
  static readonly caption: number = 12;
  static readonly body3: number = 12;
  static readonly body2: number = 14;
  static readonly body1: number = 16;    // 正文
  static readonly s3: number = 20;       // v2 --large
  static readonly s2: number = 20;       // 顶栏标题
  static readonly s1: number = 24;
  static readonly heading: number = 32;  // v2 --heading（关于 hero 图标字）
}

/** 尺寸 */
export class Size {
  static readonly appbarH: number = 56;    // 顶栏（4.5）
  static readonly appbarWideH: number = 72;
  static readonly paneHeadH: number = 48;  // v2 --s12
  static readonly itemH: number = 48;      // v2 --touch
  static readonly buttonH: number = 48;    // v2 默认触控高度
  static readonly statusbarH: number = 28;
  static readonly sidebarW: number = 240;  // 侧栏最小宽（宽屏按等分，见 Index）
  static readonly drawerW: number = 300;
  static readonly utilityDialogW: number = 560; // v2 --panel-width
  static readonly importDialogW: number = 480; // v2 --import-width
  static readonly shareW: number = 520;
  static readonly paneMinW: number = 240;
  /** v1.39 39.1：目录栏基准下限（内容栏仍是 paneMinW 240）；对应原型 --pane-min-nav */
  static readonly paneMinNavW: number = 200;
  static readonly paneClose: number = Space.s10;
  static readonly paneEmptyMaxW: number = Space.s16 * 5.5;
  static readonly paneEmptyTopMax: number = Space.s16 * 1.5;
  static readonly paneEmptyTopRatio: number = 0.14;
  static readonly paneEmptyBrandTracking: number = FontSize.caption * 0.12;
  static readonly paneEmptyRecentRowH: number = Space.s12 + Space.s1;
  static readonly paneEmptyTitleWeight: number = 600;
  static readonly paneEmptyTitleWide: number = FontSize.s3 + Space.s2;
  static readonly paneEmptyTitleSingle: number = FontSize.s3 + Space.s1;
  static readonly paneEmptyTitleRight: number = FontSize.s3;
  static readonly formatMenuW: number = 360;  // Aa 浮层宽度（v2 --format-width）
  static readonly blockPanelW: number = 380;
  static readonly blockSourceW: number = 480;
  /** PDF 分页预览缩略图宽度（53.7）：520vp 分享弹窗内每行两列 */
  static readonly pdfThumbW: number = 200;
  /** 触控热区下限：图标按钮视觉 24，热区必须 ≥48（v0.1 遗留缺陷，4.x 修正） */
  static readonly touch: number = 48;
  /** 浮层最大高度：映射 v2 `--window-min`，用于 vault-menu 这类可滚动下拉（超出即内部滚动） */
  static readonly menuMaxH: number = 620;
  /** 目录树每级缩进（1.5）—— 原实现 32/48/64/80 级差 16 太窄 */
  static readonly treeIndent: number = 24;
  /** 文件树图标尺寸：映射 v2 `--tree-icon`。 */
  static readonly treeIcon: number = 18;
  /** 内容页限宽（4.9）：三屏 1061vp 下不把设置项拉成一整行 */
  static readonly contentMaxW: number = 760;
  /** 分栏把手胶囊高度：映射 v2 `--split-height`（宽度用 `Space.s1`，命中区用 `Space.s4` = `--split-hit`） */
  static readonly splitHandleH: number = 40;
  static readonly splitGripW: number = 12;
  static readonly splitGripH: number = 56;
  static readonly splitGripDot: number = 3;
  static readonly splitTouchHitW: number = 36;
  static readonly splitMouseHitW: number = 24;
  static readonly splitRailW: number = 2;
  /**
   * 设置行（v2 .hs-row）整行最小高度：min-height: calc(var(--s12) + var(--s2)) = 56，
   * 行内上下边距用 Space.s2（对应原型 padding: var(--s2) var(--s4) 的纵向半边）。
   */
  static readonly hsRowMinH: number = Space.s12 + Space.s2;
  /**
   * 左滑三档（1.6）：操作条完全滑出后**再滑这么多**进入删除区（原型 DEL_EXTRA = 36）。
   * 配合 ListItem.swipeAction 的 actionAreaDistance；越过即触发 onAction（文件 → 移入回收站）。
   */
  static readonly swipeDelExtra: number = 36;
}

/** 动效（4.10）—— 与系统观感一致 */
export class Motion {
  static readonly durFast: number = 120;
  static readonly durBase: number = 180;   // v2 --ease
  static readonly durSlow: number = 300;
  /** 文件列表展开/收起的推动动画时长（v2 --nav-duration）：汉堡按钮触发，比 --ease 慢 */
  static readonly durNav: number = 240;    // v2 --nav-duration
  /** 推动动画曲线（v2 --nav-curve） */
  static readonly navCurve: curves.ICurve = curves.cubicBezierCurve(0.2, 0, 0, 1);
  /** 撤销条（1.7）：滑到底删除后的后悔药显示时长（原型 showToast 5 秒） */
  static readonly snack: number = 5000;
}

/** 正文行高（v2 --leading：1.85） */
export const LINE_HEIGHT_BODY: number = 1.85; // v2 --leading

/**
 * 启动页品牌遮罩（v1.41）—— 数值真源：v2 原型 `.startup-*`
 * （docs/prototype/v2/启动页设计.md）；颜色仍走 `$r('app.color.*')`。
 * 入场为分组错峰浮现（本版拍板：不逐字、不做持续氛围动画，见 v1.41 §2）。
 */
export class Startup {
  /** 应用图标尺寸：原型 `.startup-emblem` 96px */
  static readonly iconSize: number = 96;
  /** 图标圆角：原型 `calc(var(--r) + var(--s2))` = 16 + 8 */
  static readonly iconRadius: number = Radius.menu + Space.s2;
  /** 光晕外扩：原型 `.startup-halo` `inset: calc(-1 * var(--s10))` */
  static readonly haloPad: number = Space.s10;
  /** 光晕透明度：原型 `--sp-glow` = brand 26% */
  static readonly haloOpacity: number = 0.26;
  /** 品牌名字号：原型 `calc(var(--large) * 1.4)` = 20 × 1.4 */
  static readonly nameSize: number = FontSize.s3 * 1.4;
  /** 品牌名字距（em）：原型 `letter-spacing:.32em`（末字空隙用 offset 半宽补偿居中） */
  static readonly nameTrackingRatio: number = 0.32;
  /** 眉题字距（em）：原型 `.42em` */
  static readonly eyebrowTrackingRatio: number = 0.42;
  /** 名言字号：原型 `clamp(17px, 1.2vw + 9px, 23px)`，本版拍板取 `--large`（20） */
  static readonly quoteSize: number = FontSize.s3;
  /** 名言行高：原型 `line-height: 1.9` */
  static readonly quoteLeading: number = 1.9;
  /** 名言字距（em）：原型 `.1em` */
  static readonly quoteTrackingRatio: number = 0.1;
  /** 行尾中文标点悬挂在正文之外，居中时向右补偿半字。 */
  static readonly quotePunctuationOffsetRatio: number = 0.5;
  /** 名言最大宽：原型 `max-width: 32em`（按名言字号折算） */
  static readonly quoteMaxW: number = FontSize.s3 * 32;
  /** 出处字号：原型 `--small`（14） */
  static readonly sourceSize: number = FontSize.body2;
  /** 发丝线宽：原型 `.startup-rule` `width: var(--s16)` */
  static readonly ruleW: number = Space.s16;
  /** 发丝线描边宽：原型 `--stroke` */
  static readonly ruleStroke: number = 1;
  /** 页脚距底：原型 `.startup-foot` `bottom: var(--s10)` */
  static readonly footBottom: number = Space.s10;
  /** 页脚字距（em）：原型 `.24em` */
  static readonly footTrackingRatio: number = 0.24;
  /** 入场错峰时刻（ms）：图标 → 品牌名 → 眉题 → 发丝线 → 名言 → 出处 → 页脚 */
  static readonly enterIconDelay: number = 0;
  static readonly enterNameDelay: number = 350;
  static readonly enterEyebrowDelay: number = 1000;
  static readonly enterRuleDelay: number = 1100;
  static readonly enterQuoteDelay: number = 1400;
  static readonly enterSourceDelay: number = 1750;
  static readonly enterFootDelay: number = 2200;
  /** 入场单组时长（ms）：原型 `startup-in` 0.7–0.9s 的轻量档 */
  static readonly enterDur: number = 800;
  /** 最短驻留（ms）：就绪也不提前淡出，等入场编排播完（末组 2200 + 时长 800）——2026-11-08 拍板：动画要看完整段 */
  static readonly minHold: number = Startup.enterFootDelay + Startup.enterDur;
  /** 入场上浮行程（vp）：原型图标 14px / 文字 6–8px */
  static readonly iconEnterFromY: number = 14;
  static readonly nameEnterFromY: number = 8;
  static readonly quoteEnterFromY: number = 6;
  /** 入场起始缩放：原型图标 `scale(.9)` */
  static readonly iconEnterFromScale: number = 0.9;
  /** 退出淡出时长与放大终值：原型 `--nav-duration`（240ms）+ `scale(1.03)` */
  static readonly exitDur: number = Motion.durNav;
  static readonly exitScaleTo: number = 1.03;
}
