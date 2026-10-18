/**
 * SettingsView.ets —— 设置与关于（原型「设置与关于」面板，v0.2 §4.x）
 *
 * 以内容区整体替换形态挂载在 Index 内容区（与 VaultManagerView 同级）。
 * 返回走 Index 顶栏返回箭头（2.7c 硬要求，本组件不自带返回入口）。
 *
 * 内容（照原型「设置与关于」规格，需求文档 4.x / 设计稿 index.html line 1088）：
 *  - 版本号 / 版本码 / 包名：运行时从**自身包信息**读出，不在代码写死常量
 *    （api_notes H-1/H-2：getBundleInfoForSelfSync 在 try/catch 内调用，失败兜底显示占位，
 *     读不到也不崩；实测确认该同步接口在 API 24 可用、读自身包无需额外权限）；
 *  - 当前形态 / 断点 / 库目录：诊断信息，真机校准时对着看；
 *  - 后续版本才有的设置项在底部灰显占位。
 * 视觉：token 化 + 内容页限宽 760vp 居中（需求 4.9）。
 */
import { bundleManager } from '@kit.AbilityKit';
import { VaultRegistry } from '../model/VaultRegistry';
import { Space, Radius, FontSize, Size } from '../common/Tokens';

@Component
export struct SettingsView {
  /** 当前断点（从 Index @StorageProp 透传，诊断区显示） */
  @Prop breakpoint: string = '';
  /** 当前库 id（诊断区显示库目录） */
  @Prop currentVaultId: string = '';

  @State versionName: string = '—';
  @State versionCode: number = 0;
  @State bundleName: string = '—';

  aboutToAppear(): void {
    try {
      // 读自身包信息：同步接口，flag 用 WITH_APPLICATION 即可拿到 version / name 等
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.versionName = info.versionName;
      this.versionCode = info.versionCode;
      this.bundleName = info.name;
    } catch (error) {
      // 读不到（权限/接口差异）不崩：留占位，诊断区照常可用
      this.versionName = '（读取失败）';
    }
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

  /** 一行「标签 + 值」（诊断/应用信息共用） */
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

          // 应用信息卡：版本号 / 版本码 / 包名（运行时读，不写死）
          Column() {
            Text('应用信息')
              .fontSize(FontSize.body3)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .margin({ bottom: Space.s2 })
            this.InfoRow('版本号', this.versionName)
            this.InfoRow('版本码', this.versionCode.toString())
            this.InfoRow('包名', this.bundleName)
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
