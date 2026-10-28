/**
 * TrashView.ets —— 文件侧栏底部的可展开回收站目录（v0.2 需求 1.8）。
 * 数据继续由 TrashService 按库读取；恢复由父级执行并刷新文件树。
 */
import { TrashItem, TrashService } from '../model/TrashService';
import { VaultRegistry } from '../model/VaultRegistry';
import { Space, FontSize, Size } from '../common/Tokens';
import { Icon } from '../common/Icons';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { KeyCode } from '@ohos.multimodalInput.keyCode';

const TRASH_VIEW_DOMAIN: number = 0x0000;
const TRASH_VIEW_TAG: string = 'TrashView';

@Component
export struct TrashView {
  /** 当前库 id（回收站按库隔离） */
  @Prop @Watch('onVaultChanged') vaultId: string = '';
  /** 删除 / 恢复 / 撤销后由父级递增，触发重新读取 */
  @Prop @Watch('onRefresh') refreshSeq: number = 0;
  /** 「恢复」回调（父级执行 TrashService.restore 并刷新树） */
  onRestore: (relPath: string) => void = (relPath: string) => {};

  @State items: TrashItem[] = [];
  @State expandedVaultIds: string[] = [];
  @State loadFailed: boolean = false;

  aboutToAppear(): void {
    this.reload();
  }

  private onVaultChanged(): void {
    this.reload();
  }

  private onRefresh(): void {
    this.reload();
  }

  private reload(): void {
    this.loadFailed = false;
    if (this.vaultId.length === 0) {
      this.items = [];
      return;
    }
    try {
      this.items = TrashService.list(VaultRegistry.get(), this.vaultId);
      if (this.items.length === 0) {
        this.expandedVaultIds = this.expandedVaultIds.filter((id: string) => id !== this.vaultId);
      }
    } catch (error) {
      const err = error as Error;
      hilog.warn(TRASH_VIEW_DOMAIN, TRASH_VIEW_TAG, '列回收站失败: %{public}s', err.message);
      this.items = [];
      this.loadFailed = true;
    }
  }

  private isExpanded(): boolean {
    return this.expandedVaultIds.indexOf(this.vaultId) >= 0;
  }

  private toggleExpanded(): void {
    const next: string[] = this.expandedVaultIds.filter((id: string) => id !== this.vaultId);
    if (!this.isExpanded()) {
      next.push(this.vaultId);
    }
    this.expandedVaultIds = next;
  }

  private onHeaderKey(event: KeyEvent): void {
    if (event.type !== KeyType.Down) {
      return;
    }
    if (event.keyCode === KeyCode.KEYCODE_DPAD_RIGHT && !this.isExpanded()) {
      this.toggleExpanded();
    } else if (event.keyCode === KeyCode.KEYCODE_DPAD_LEFT && this.isExpanded()) {
      this.toggleExpanded();
    }
  }

  private displayName(item: TrashItem): string {
    const name: string = item.name;
    const lowerName: string = name.toLowerCase();
    if (lowerName.endsWith('.markdown')) {
      return name.substring(0, name.length - '.markdown'.length);
    }
    if (lowerName.endsWith('.md')) {
      return name.substring(0, name.length - '.md'.length);
    }
    return name;
  }

  private originFolder(item: TrashItem): string {
    const slash: number = item.relPath.lastIndexOf('/');
    return slash >= 0 ? item.relPath.substring(0, slash) : '根目录';
  }

  private originLabel(item: TrashItem): string {
    return '原位置：' + this.vaultId + ' / ' + this.originFolder(item);
  }

  @Builder
  ItemRow(item: TrashItem) {
    Row({ space: Space.s2 }) {
      Icon('doc', 18, $r('app.color.text_tertiary'))
      Column({ space: Space.s1 }) {
        Text(this.displayName(item))
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.originLabel(item))
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .accessibilityText(this.originLabel(item))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Row() {
        Icon('restore', 20, $r('app.color.brand'))
      }
      .width(Size.touch)
      .height(Size.touch)
      .justifyContent(FlexAlign.Center)
      .focusable(true)
      .accessibilityText('恢复 ' + this.displayName(item) + ' 到 ' +
        this.vaultId + ' / ' + this.originFolder(item))
      .onClick((): void => { this.onRestore(item.relPath); })
    }
    .width('100%')
    .height(Size.touch)
    .padding({ left: Space.s2, right: Space.s2 })
  }

  build() {
    Column() {
      if (this.items.length > 0 || this.loadFailed) {
        Row({ space: Space.s2 }) {
          Icon(this.isExpanded() ? 'chevronDown' : 'chevronRight',
            14, $r('app.color.text_tertiary'))
          Icon('trash', 18, $r('app.color.text_tertiary'))
          Text('回收站')
            .fontSize(FontSize.body2)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          if (this.items.length > 0) {
            Text(this.items.length.toString())
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
          }
        }
        .width('100%')
        .height(Size.touch)
        .padding({ left: Space.s3, right: Space.s3 })
        .focusable(true)
        .onKeyEvent((event: KeyEvent): void => { this.onHeaderKey(event); })
        .onClick((): void => { this.toggleExpanded(); })

        if (this.isExpanded()) {
          if (this.loadFailed) {
            Text('回收站暂时无法读取')
              .fontSize(FontSize.caption)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .padding({ left: Space.s8, right: Space.s2, top: Space.s2, bottom: Space.s2 })
          } else {
            Scroll() {
              Column() {
                ForEach(this.items, (item: TrashItem) => {
                  this.ItemRow(item)
                }, (item: TrashItem) => item.relPath)
              }
              .width('100%')
              .padding({ left: Space.s4 })
            }
            .width('100%')
            .height(Math.min(this.items.length, 3) * Size.touch)
            .constraintSize({ maxHeight: Size.touch * 3 })
            .scrollBar(BarState.Auto)
          }
        }
      }
    }
    .width('100%')
  }
}
