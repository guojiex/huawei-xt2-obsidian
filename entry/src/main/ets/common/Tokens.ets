/**
 * Tokens.ets —— 设计 token 的**数值部分**（v0.2 §3.5 需求 4.1 / 4.3 / 4.4 / 4.5 / 4.10）
 *
 * 真源：`docs/prototype/index.html` 的 `:root`。
 *   - **颜色**不放这里**：颜色是要跟随系统深色切换的，必须走资源
 *     `entry/src/main/resources/base|dark/element/color.json`，用 `$r('app.color.*')` 引用。
 *     这样深色模式是「另一套 token」而不是浅色反色（需求 4.2）。
 *   - **数值**（间距/圆角/字号/尺寸/动效）放这里：ArkTS 里要做算术（如树缩进 = 层级 × 24），
 *     资源 `$r()` 是 Resource 不能参与运算，所以统一用常量模块。
 *
 * 改值规矩（AGENTS.md 硬约束 17）：改这里必须同步改原型 `:root`，两边不许漂。
 */

/** 间距：4vp 栅格（4.4）—— 不允许出现 5 / 7 / 9 这类非栅格值 */
export class Space {
  static readonly s1: number = 4;
  static readonly s2: number = 8;
  static readonly s3: number = 12;
  static readonly s4: number = 16;
  static readonly s5: number = 20;
  static readonly s6: number = 24;
  static readonly s8: number = 32;
  static readonly s12: number = 48;
}

/** 圆角：按场景取值（4.3）—— 同类控件圆角必须一致 */
export class Radius {
  static readonly chip: number = 4;      // 徽标 / 小标签
  static readonly icon: number = 10;     // 图标按钮
  static readonly control: number = 12;  // 列表项 / 输入框 / 网格
  static readonly card: number = 16;     // 卡片 / 弹窗
  static readonly button: number = 20;   // 按钮 / 菜单
  static readonly menu: number = 20;
  static readonly dialog: number = 16;
  static readonly snack: number = 18;    // SnackBar
  static readonly full: number = 999;    // 全圆（头像 / 圆形按钮）
}

/** 字号阶梯（4.5）—— 三档形态下保持一致，不随断点跳号 */
export class FontSize {
  static readonly caption: number = 12;
  static readonly body3: number = 12;
  static readonly body2: number = 14;
  static readonly body1: number = 16;    // 正文
  static readonly s3: number = 18;
  static readonly s2: number = 20;       // 顶栏标题
  static readonly s1: number = 24;
}

/** 尺寸 */
export class Size {
  static readonly appbarH: number = 56;    // 顶栏（4.5）
  static readonly appbarWideH: number = 72;
  static readonly paneHeadH: number = 40;  // 栏头
  static readonly itemH: number = 56;      // 列表项（HdsListItem 观感，4.6）
  static readonly buttonH: number = 40;
  static readonly statusbarH: number = 28;
  static readonly sidebarW: number = 240;  // 侧栏最小宽（宽屏按等分，见 Index）
  static readonly drawerW: number = 300;
  static readonly paneMinW: number = 240;
  /** 触控热区下限：图标按钮视觉 24，热区必须 ≥48（v0.1 遗留缺陷，4.x 修正） */
  static readonly touch: number = 48;
  /** 目录树每级缩进（1.5）—— 原实现 32/48/64/80 级差 16 太窄 */
  static readonly treeIndent: number = 24;
  /** 内容页限宽（4.9）：三屏 1061vp 下不把设置项拉成一整行 */
  static readonly contentMaxW: number = 760;
  /**
   * 左滑三档（1.6）：操作条完全滑出后**再滑这么多**进入删除区（原型 DEL_EXTRA = 36）。
   * 配合 ListItem.swipeAction 的 actionAreaDistance；越过即触发 onAction（文件 → 移入回收站）。
   */
  static readonly swipeDelExtra: number = 36;
}

/** 动效（4.10）—— 与系统观感一致 */
export class Motion {
  static readonly durFast: number = 120;
  static readonly durBase: number = 200;
  static readonly durSlow: number = 300;
  /** 撤销条（1.7）：滑到底删除后的后悔药显示时长（原型 showToast 5 秒） */
  static readonly snack: number = 5000;
}

/** 正文行高（4.5：正文 16fp + 行高 1.65） */
export const LINE_HEIGHT_BODY: number = 1.65;
