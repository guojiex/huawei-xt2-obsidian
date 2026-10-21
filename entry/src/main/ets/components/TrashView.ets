/**
 * TrashView.ets —— 回收站视图（v0.2 需求 1.8）
 *
 * 结构照原型 #trashView（.sync 容器）：说明文案 + 条目列表；
 * 条目照原型 .trash-item：flex 行、gap/padding --sp-3、边框 line、圆角 --r-control、
 * 右侧「恢复」按钮。数据源 TrashService.list（.trash 镜像结构，按删除时间倒序）。
 *
 * 交互语义（原型 restoreTrashItem）：
 *  - 「恢复」= 移回原位置（`.trash` 里的相对路径就是原路径）；
 *  - 原位置已有同名文件 → 不覆盖，toast「原位置已有同名文件，请先处理重名」；
 *  - 视图自身不处理撤销条（那是 1.7 删除侧的事，Index 统一持有）。
 *
 * 视觉：内容页限宽 760vp 居中（需求 4.9，与库管理视图同款）；
 * 颜色全走 token，数值走 Space/Radius/FontSize/Size。
 */
import { TrashItem, TrashService } from '../model/TrashService';
import { VaultRegistry } from '../model/VaultRegistry';
import { Space, Radius, FontSize, Size } from '../common/Tokens';
import { Icon } from '../common/Icons';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TRASH_VIEW_DOMAIN: number = 0x0000;
const TRASH_VIEW_TAG: string = 'TrashView';

@Component
export struct TrashView {
  /** 当前库 id（回收站按库隔离：列表只显示本库 `.trash`） */
  @Prop vaultId: string = '';
  /** 重扫信号：父级 +1（删除/恢复/撤销后）→ 重新 list */
  @Prop @Watch('onRefresh') refreshSeq: number = 0;
  /** 「恢复」回调（父级执行 TrashService.restore 并刷树；本组件只回传路径） */
  onRestore: (relPath: string) => void = (relPath: string) => {};

  @State items: TrashItem[] = [];

  aboutToAppear(): void {
    this.reload();
  }

  private onRefresh(): void {
    this.reload();
  }

  private reload(): void {
    if (this.vaultId.length === 0) {
      this.items = [];
      return;
    }
    try {
      this.items = TrashService.list(VaultRegistry.get(), this.vaultId);
    } catch (error) {
      // 回收站列表失败不致命：先给空列表，详情进 hilog
      const err = error as Error;
      hilog.warn(TRASH_VIEW_DOMAIN, TRASH_VIEW_TAG, '列回收站失败: %{public}s', err.message);
      this.items = [];
    }
  }

  build() {
    Scroll() {
      Column() {
        // 原型 .sub 说明文案
        Text('当前库的已删除笔记可恢复。恢复时如果原位置已有同名文件，需要先处理重名。')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ bottom: Space.s5 })

        if (this.items.length === 0) {
          Text('当前库的回收站为空')
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(Space.s4)
        } else {
          ForEach(this.items, (it: TrashItem) => {
            Row({ space: Space.s3 }) {
              Icon('doc', 16, $r('app.color.text_secondary'))
              Text(it.relPath)
                .fontSize(FontSize.body2)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('恢复')
                .fontSize(FontSize.body3)
                .fontColor($r('app.color.text_primary'))
                .height(Size.buttonH)
                .padding({ left: Space.s3, right: Space.s3 })
                .textAlign(TextAlign.Center)
                .borderRadius(Radius.control)
                .border({ width: 1, color: $r('app.color.line') })
                .backgroundColor($r('app.color.bg_secondary'))
                .onClick(() => {
                  this.onRestore(it.relPath);
                })
            }
            .width('100%')
            .padding(Space.s3)
            .margin({ bottom: Space.s2 })
            .border({ width: 1, color: $r('app.color.line') })
            .borderRadius(Radius.control)
            .alignItems(VerticalAlign.Center)
          }, (it: TrashItem) => it.relPath)
        }
      }
      // 需求 4.9：内容页限宽 760vp 居中
      .width('100%')
      .constraintSize({ maxWidth: Size.contentMaxW })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .backgroundColor($r('app.color.bg_page'))
    .scrollBar(BarState.Off)
  }
}
