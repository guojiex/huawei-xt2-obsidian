/**
 * SettingsView.ets —— 设置与关于（原型「设置与关于」面板，v0.2 §4.x）
 *
 * 以内容区整体替换形态挂载在 Index 内容区（与 VaultManagerView 同级）。
 * 返回走 Index 顶栏返回箭头（2.7c 硬要求，本组件不自带返回入口）。
 *
 * 内容（照原型「设置与关于」规格，2026-10-21 对齐设计稿改版）：
 *  - 关于卡：hero（应用名 + 版本号）+ 定位一行 + 开源信息一行小字；
 *    **包名行已删**（设计稿 2026-10-21 拍板：那是开发期对 hdc 日志/签名用的诊断值，用户不需要）；
 *    版本号**运行时从自身包信息读出，不在代码写死常量**（api_notes H-1/H-2：
 *    getBundleInfoForSelfSync 在 try/catch 内调用，失败兜底显示占位，读不到也不崩）；
 *  - 更新日志卡：只列用户可感知的变更，最新在上（v0.1 / v0.2 与设计稿 .chlog 一致）；
 *  - 诊断卡：当前形态 / 断点 / 库目录（真机校准对照）；
 *  - 后续版本才有的设置项在底部灰显占位。
 * 视觉：token 化 + 内容页限宽 760vp 居中（需求 4.9）。
 */
import { bundleManager } from '@kit.AbilityKit';
import { VaultRegistry } from '../model/VaultRegistry';
import { Space, Radius, FontSize, Size } from '../common/Tokens';

/** 更新日志一条（vX.Y）：只列用户可感知的变更，与设计稿 .chlog 同源 */
interface ChlogEntry {
  ver: string;
  date: string;
  items: string[];
}

/** 更新日志数据：新增版本时在头部插入一条（最新在上） */
const CHANGELOG: ChlogEntry[] = [
  {
    ver: 'v0.2',
    date: '开发中',
    items: [
      '文件树：层级引导线、目录选择器新建（笔记 / 文件夹）、左滑三档（重命名 / 移动 / 删除）',
      '回收站：删除入站 + 5 秒撤销条 + 恢复',
      '编辑与保存：CodeMirror 源码编辑、防抖自动保存、原子写入',
      '视觉 token 基线（颜色 / 间距 / 字号统一引用设计 token）'
    ]
  },
  {
    ver: 'v0.1',
    date: '2026-10',
    items: [
      '三形态骨架（单 / 双 / 三屏）与多库注册表、库切换',
      'Git 桥接底层（isomorphic-git 打包进应用、clone 通道部分打通）'
    ]
  }
];

@Component
export struct SettingsView {
  /** 当前断点（从 Index @StorageProp 透传，诊断区显示） */
  @Prop breakpoint: string = '';
  /** 当前库 id（诊断区显示库目录） */
  @Prop currentVaultId: string = '';

  @State versionName: string = '—';
  @State versionCode: number = 0;

  aboutToAppear(): void {
    try {
      // 读自身包信息：同步接口，flag 用 WITH_APPLICATION 即可拿到 version / name 等
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.versionName = info.versionName;
      this.versionCode = info.versionCode;
    } catch (error) {
      // 读不到（权限/接口差异）不崩：留占位，诊断区照常可用
      this.versionName = '（读取失败）';
    }
  }

  /** hero 副行版本文案：读取失败时只显示占位，不拼出「版本 （读取失败）（0）」 */
  private versionText(): string {
    if (this.versionName === '—' || this.versionName === '（读取失败）') {
      return this.versionName;
    }
    return '版本 ' + this.versionName + '（' + this.versionCode.toString() + '）';
  }

  /** 断点 → 形态中文标签（照原型 FORMS） */
  private formLabel(): string {
    if (this.breakpoint === 'sm') {
      return '外屏合起 (380vp)';
    }
    if (this.breakpoint === 'md') {
      return '展开双屏 (709vp)';
    }
    return '三屏展开 (1061vp)';
  }

  /** 当前库绝对目录（从注册表取真实路径，不自己拼 filesDir） */
  private vaultDir(): string {
    if (this.currentVaultId.length === 0) {
      return '（无库）';
    }
    try {
      return VaultRegistry.get().vaultDirOf(this.currentVaultId);
    } catch (error) {
      return 'vaults/' + this.currentVaultId;
    }
  }

  /** 一行「标签 + 值」（诊断/定位行共用） */
  @Builder
  InfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_tertiary'))
        .width(96)
      Text(value)
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .margin({ bottom: Space.s2 })
  }

  /** 更新日志一条：版本号 + 日期 + 变更列表（最新在上） */
  @Builder
  ChlogItem(entry: ChlogEntry) {
    Column() {
      Row() {
        Text(entry.ver)
          .fontSize(FontSize.body2)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Text(entry.date)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ left: Space.s2 })
      }
      .alignItems(VerticalAlign.Bottom)
      .margin({ bottom: Space.s1 })
      ForEach(entry.items, (item: string) => {
        Row() {
          Text('·')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_secondary'))
          Text(item)
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
            .margin({ left: Space.s1 })
        }
        .alignItems(VerticalAlign.Top)
        .margin({ bottom: Space.s1 })
      }, (item: string) => item)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: Space.s3 })
  }

  build() {
    Scroll() {
      Column() {
        Column() {
          Text('设置与关于')
            .fontSize(FontSize.body1)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .margin({ bottom: Space.s4 })

          // 关于卡：hero + 定位 + 开源信息一行小字（包名行已删，2026-10-21）
          Column() {
            Text('关于')
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .margin({ bottom: Space.s3 })
            Row() {
              Text('曜')
                .fontSize(FontSize.s2)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.on_brand'))
                .width(Size.itemH)
                .height(Size.itemH)
                .textAlign(TextAlign.Center)
                .borderRadius(Radius.card)
                .linearGradient({
                  angle: 180,
                  colors: [[$r('app.color.brand'), 0], [$r('app.color.brand_press'), 1]]
                })
              Column() {
                Text('曜石笔记')
                  .fontSize(FontSize.s3)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                Text(this.versionText())
                  .fontSize(FontSize.body3)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ top: Space.s1 })
              }
              .alignItems(HorizontalAlign.Start)
              .margin({ left: Space.s4 })
            }
            .alignItems(VerticalAlign.Center)
            .width('100%')
            .margin({ bottom: Space.s3 })
            this.InfoRow('定位', '为 XT2 三折叠做的本地 Markdown 笔记')
            // 开源信息：压成一行小字（应用 MIT + 打包 isomorphic-git / CodeMirror 等 MIT 组件）
            Text('开源 · MIT · github.com/guojiex/huawei-xt2-obsidian（含 isomorphic-git、CodeMirror 等 MIT 组件）')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .padding({ top: Space.s2 })
              .border({ width: { top: 1 }, color: $r('app.color.line') })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(Space.s4)
          .borderRadius(Radius.card)
          .border({ width: 1, color: $r('app.color.line') })
          .backgroundColor($r('app.color.bg_card'))
          .margin({ bottom: Space.s4 })

          // 更新日志卡：只列用户可感知的变更，最新在上
          Column() {
            Text('更新日志')
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .margin({ bottom: Space.s2 })
            ForEach(CHANGELOG, (entry: ChlogEntry) => {
              this.ChlogItem(entry)
            }, (entry: ChlogEntry) => entry.ver)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(Space.s4)
          .borderRadius(Radius.card)
          .border({ width: 1, color: $r('app.color.line') })
          .backgroundColor($r('app.color.bg_card'))
          .margin({ bottom: Space.s4 })

          // 诊断信息卡：当前形态 / 断点 / 库目录（真机校准对照）
          Column() {
            Text('诊断信息')
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .margin({ bottom: Space.s2 })
            this.InfoRow('当前形态', this.formLabel())
            this.InfoRow('断点', this.breakpoint)
            this.InfoRow('库目录', this.vaultDir())
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(Space.s4)
          .borderRadius(Radius.card)
          .border({ width: 1, color: $r('app.color.line') })
          .backgroundColor($r('app.color.bg_card'))
          .margin({ bottom: Space.s4 })

          // 后续设置项灰显占位（设计稿：后续版本才有的设置在底部灰显）
          Text('更多设置（敬请期待）')
            .fontSize(FontSize.body3)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .height(Size.itemH)
            .textAlign(TextAlign.Center)
            .borderRadius(Radius.card)
            .border({ width: 1, color: $r('app.color.line'), style: BorderStyle.Dashed })
            .opacity(0.5)
        }
        // 需求 4.9：内容页限宽 760vp 居中
        .width('100%')
        .constraintSize({ maxWidth: Size.contentMaxW })
      }
      .width('100%')
      .padding({ left: Space.s5, right: Space.s5, top: Space.s5, bottom: Space.s8 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .backgroundColor($r('app.color.bg_page'))
    .scrollBar(BarState.Off)
  }
}
