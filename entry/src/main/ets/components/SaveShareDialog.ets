/**
 * SaveShareDialog.ets —— 接收系统分享的保存确认层（v1.56 56.3）
 *
 * 用户把一段文本 / 一条链接分享给 App 后，先在这里确认「存到哪个库、叫什么名字、
 * 存什么内容」，再落盘（Index.saveSharedNote）。与出站分享预览弹窗
 * （ShareTextPreviewDialog）同族：UtilityDialogShell 模式、全形态复用、token only。
 *
 * 交互（需求文档 56.3）：
 *  - 标题输入：默认值由 ShareIngestService.buildDraft 按标题默认链算好；保存时
 *    标题即文件名（56.4：文件名 = 标题 + .md，唯一命名去重）；
 *  - 目标库行：内联展开库列表（同 CreateNoteDialog 的目录选择器——CustomDialog 上
 *    再挂弹层层级不稳，内联 Column 最稳），默认当前库；
 *  - 内容预览：TextArea 可编辑，默认模板（链接 [title](url) / 文本原文）；
 *  - 取消 / 保存；标题为空或无可写库时保存禁用；保存失败 errorMessage 保留现场可重试。
 */
import { UIUtils } from '@kit.ArkUI';
import { FontSize, Radius, Size, Space } from '../common/Tokens';
import { Icon } from '../common/Icons';
import { VaultEntry } from '../model/Vault';
import { NoteService } from '../model/NoteService';
import { VaultRegistry } from '../model/VaultRegistry';
import { UtilityDialogAction, UtilityDialogShell } from './UtilityDialogShell';

@CustomDialog
export struct SaveShareDialog {
  controller?: CustomDialogController;
  /** 标题默认草稿（ShareIngestService.buildDraft 产物）。 */
  initialTitle: string = '';
  /** 正文默认草稿（链接模板 / 文本原文）。 */
  initialContent: string = '';
  /** 可写目标库（Index 侧已过滤为非空列表）。 */
  vaults: VaultEntry[] = [];
  /** 默认选中的库（当前库）。 */
  defaultVaultId: string = '';
  @Prop windowWidthVp: number = 0;
  @Prop windowHeightVp: number = 0;
  @Prop singleScreen: boolean = false;
  onConfirm: (vaultId: string, rawName: string, content: string) => Promise<void> =
    async (vaultId: string, rawName: string, content: string): Promise<void> => {};
  onCancel: () => void = () => {};
  @State titleDraft: string = '';
  @State contentDraft: string = '';
  @State selectedVaultId: string = '';
  @State vaultPickerOpen: boolean = false;
  @State saving: boolean = false;
  @State errorMessage: string = '';

  aboutToAppear(): void {
    this.titleDraft = this.initialTitle;
    this.contentDraft = this.initialContent;
    this.selectedVaultId = this.defaultVaultId;
    if (!this.containsVault(this.selectedVaultId) && this.vaults.length > 0) {
      this.selectedVaultId = this.vaults[0].id;
    }
  }

  private containsVault(id: string): boolean {
    for (let i = 0; i < this.vaults.length; i++) {
      if (this.vaults[i].id === id) {
        return true;
      }
    }
    return false;
  }

  private close(): void {
    this.controller?.close();
    this.onCancel();
  }

  private async confirm(): Promise<void> {
    if (this.saving || this.vaults.length === 0 || this.titleDraft.trim().length === 0) {
      return;
    }
    this.saving = true;
    this.errorMessage = '';
    try {
      await this.onConfirm(this.selectedVaultId, this.titleDraft, this.contentDraft);
      // 保存成功才关：失败保留现场可重试（56.4）。
      this.controller?.close();
    } catch (error) {
      const err = error as Error;
      this.errorMessage = err.message;
    } finally {
      this.saving = false;
    }
  }

  /** 实时保存预览：目标路径 + 重名加后缀；标题含 `/` 时提示首期固定库根。 */
  private saveHint(): string {
    if (this.titleDraft.trim().length === 0 || this.vaults.length === 0) {
      return '';
    }
    let rel: string;
    try {
      rel = NoteService.normalizeRelPath(this.titleDraft);
    } catch (error) {
      const err = error as Error;
      return err.message;
    }
    if (rel.indexOf('/') >= 0) {
      return '保存位置固定在库根，标题不能包含 /';
    }
    const actual: string = NoteService.uniqueRelPath(
      VaultRegistry.get(), this.selectedVaultId, rel);
    if (actual !== rel) {
      return '将保存为 ' + actual + '（同名已存在，自动加后缀）';
    }
    return '将保存到 ' + this.selectedVaultId + '/' + rel;
  }

  /** 库选择行（与 CreateNoteDialog.DirItem 同款：选中态主色实底，不引入新图标）。 */
  @Builder
  VaultItem(vault: VaultEntry) {
    Row({ space: Space.s2 }) {
      // 全局 @Builder 按值实参不随状态刷新，选中色必须走 if 分支（L-7/Z2）。
      if (this.selectedVaultId === vault.id) {
        Icon('folder', 14, $r('app.color.brand'))
      } else {
        Icon('folder', 14, $r('app.color.text_secondary'))
      }
      Text(vault.id)
        .fontSize(FontSize.body3)
        .fontColor(this.selectedVaultId === vault.id
          ? $r('app.color.brand') : $r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.selectedVaultId === vault.id) {
        Text('当前目标')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.brand'))
      }
    }
    .width('100%')
    .height(Size.touch)
    .padding({ left: Space.s2, right: Space.s2 })
    .borderRadius(Radius.icon)
    .backgroundColor(this.selectedVaultId === vault.id
      ? $r('app.color.brand_bg_solid') : Color.Transparent)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.selectedVaultId = vault.id;
      this.vaultPickerOpen = false;
    })
  }

  @Builder
  DialogContent() {
    Column({ space: Space.s3 }) {
      Text('标题（保存为库根新笔记，重名自动加序号）')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      TextInput({ text: this.titleDraft, placeholder: '笔记标题' })
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.bg_secondary'))
        .padding(Space.s2)
        .borderRadius(Radius.control)
        .border({ width: 1, color: $r('app.color.line') })
        .accessibilityText('分享笔记标题')
        .onChange((value: string): void => {
          this.titleDraft = value;
        })
      if (this.saveHint().length > 0) {
        Text(this.saveHint())
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
      }
      Row({ space: Space.s2 }) {
        Icon('folder', 14, $r('app.color.text_secondary'))
        Text(this.selectedVaultId.length > 0 ? this.selectedVaultId : '选择目标库')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.vaultPickerOpen) {
          Icon('chevronUp', 14, $r('app.color.text_secondary'))
        } else {
          Icon('chevronDown', 14, $r('app.color.text_secondary'))
        }
      }
      .width('100%')
      .height(Size.touch)
      .padding({ left: Space.s2, right: Space.s2 })
      .borderRadius(Radius.control)
      .backgroundColor($r('app.color.bg_secondary'))
      .alignItems(VerticalAlign.Center)
      .accessibilityText('目标知识库')
      .onClick(() => {
        this.vaultPickerOpen = !this.vaultPickerOpen;
      })
      if (this.vaultPickerOpen) {
        Column({ space: Space.s1 }) {
          ForEach(this.vaults, (vault: VaultEntry) => {
            this.VaultItem(vault)
          }, (vault: VaultEntry) => vault.id)
        }
        .width('100%')
      }
      Text('内容（可编辑）')
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
      TextArea({ text: this.contentDraft, placeholder: '笔记内容' })
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.bg_secondary'))
        .padding(Space.s3)
        .height(Size.drawerW * 0.58)
        .borderRadius(Radius.control)
        .border({ width: 1, color: $r('app.color.line') })
        .accessibilityText('分享笔记内容')
        .onChange((value: string): void => {
          this.contentDraft = value;
        })
      if (this.vaults.length === 0) {
        Text('还没有可写入的笔记本，无法保存。')
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.danger'))
          .width('100%')
      }
      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(FontSize.caption)
          .fontColor($r('app.color.danger'))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DialogFooter() {
    Row({ space: Space.s3 }) {
      UtilityDialogAction(UIUtils.makeBinding<string>(() => '取消'), 'secondary', this.singleScreen,
        UIUtils.makeBinding<boolean>(() => !this.saving),
        (): void => {
          this.close();
        }, true)
      UtilityDialogAction(
        UIUtils.makeBinding<string>(() => this.saving ? '正在保存…' : '保存笔记'),
        'primary', this.singleScreen,
        UIUtils.makeBinding<boolean>(() =>
          !this.saving && this.vaults.length > 0 && this.titleDraft.trim().length > 0),
        (): void => {
          void this.confirm();
        }, true)
    }
    .width('100%')
    .justifyContent(this.singleScreen ? FlexAlign.SpaceBetween : FlexAlign.End)
  }

  build() {
    UtilityDialogShell({
      title: '保存分享',
      subtitle: '存入笔记',
      headerIcon: 'share',
      closeLabel: '关闭保存分享',
      singleScreen: this.singleScreen,
      scrollContent: true,
      preferredWidthVp: Size.shareW,
      windowWidthVp: this.windowWidthVp,
      windowHeightVp: this.windowHeightVp,
      onClose: (): void => {
        this.close();
      },
      content: (): void => {
        this.DialogContent();
      },
      footer: (): void => {
        this.DialogFooter();
      }
    })
  }
}
