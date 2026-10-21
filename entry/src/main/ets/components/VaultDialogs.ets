/**
 * VaultDialogs.ets —— 库操作三对话框（新建 / 改名 / 删除确认，结构照原型 confirm 层）
 *
 * 文案铁律（spec FR-011）：删除弹窗必须明示「不可逆 / 无法恢复」；
 * 绝不出现「建议先导出备份」——zip 导出未实现，写了就是骗用户。
 *
 * 消毒与重名预览共用 model 层同一套逻辑（Vault.sanitizeVaultName +
 * VaultRegistry.uniqueVaultId），对话框与注册表不各写一份，避免两处漂移。
 *
 * 视觉全部走 token（v0.2 §3.5）：数值用 common/Tokens.ets，颜色用
 * $r('app.color.*')（base|dark 两套资源，深色模式自动切换）。
 */
import { sanitizeVaultName } from '../model/Vault';
import { VaultRegistry } from '../model/VaultRegistry';
import { Space, Radius, FontSize, Size } from '../common/Tokens';

/** 非法字符提示（新建/改名共用，照原型 updateHint 文案） */
const BAD_NAME_HINT: string = '名称不能为空，也不能只由 / \\ : * ? " < > | 组成';

/** 新建本地库对话框：TextInput + 消毒结果与目标路径实时预览 + 空名禁用确认 */
@CustomDialog
export struct CreateVaultDialog {
  controller?: CustomDialogController;
  @State rawName: string = '';
  /** 确认回调（传原始输入；注册表侧统一消毒——单一真源） */
  onConfirm: (name: string) => void = (name: string) => {};

  private sanitized(): string {
    return sanitizeVaultName(this.rawName);
  }

  /** 实时预览：消毒结果 + 目标路径（重名自动加后缀，原型行为） */
  private hintText(): string {
    const s: string = this.sanitized();
    if (s.length === 0) {
      return BAD_NAME_HINT;
    }
    const id: string = VaultRegistry.get().uniqueVaultId(s, '');
    if (id !== s) {
      return '目录：vaults/' + id + '（与现有库重名，已自动加后缀）';
    }
    return '目录：vaults/' + id;
  }

  private confirm(): void {
    if (this.sanitized().length === 0) {
      return; // 空名禁用确认（双保险：按钮已 disabled）
    }
    this.controller?.close();
    this.onConfirm(this.rawName);
  }

  build() {
    Column() {
      Text('新建本地笔记库')
        .fontSize(FontSize.body2)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text('在 vaults/ 下新建一个目录，不参与同步，与现有库互不影响。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: Space.s2, bottom: Space.s3 })
      TextInput({ placeholder: '库名称' })
        .height(Size.buttonH)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .padding({ left: Space.s3, right: Space.s3 })
        .backgroundColor($r('app.color.bg_secondary'))
        .borderRadius(Radius.control)
        .onChange((value: string) => {
          this.rawName = value;
        })
      Text(this.hintText())
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ top: Space.s2 })
      Row({ space: Space.s2 }) {
        Text('取消')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_primary'))
          .height(30)
          .padding({ left: Space.s4, right: Space.s4 })
          .textAlign(TextAlign.Center)
          .borderRadius(Radius.icon)
          .border({ width: 1, color: $r('app.color.line') })
          .backgroundColor($r('app.color.bg_secondary'))
          .onClick(() => {
            this.controller?.close();
          })
        Text('创建')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.on_brand'))
          .height(30)
          .padding({ left: Space.s4, right: Space.s4 })
          .textAlign(TextAlign.Center)
          .borderRadius(Radius.icon)
          .backgroundColor($r('app.color.brand'))
          .enabled(this.sanitized().length > 0)
          .opacity(this.sanitized().length > 0 ? 1 : 0.4)
          .onClick(() => {
            this.confirm();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: Space.s4 })
    }
    .width(Size.drawerW)
    .padding(Space.s4)
    .borderRadius(Radius.dialog)
    .backgroundColor($r('app.color.bg_card'))
    .alignItems(HorizontalAlign.Start)
  }
}

/** 改名对话框：同新建结构，预填现名；预览 vaults/旧 → vaults/新 */
@CustomDialog
export struct RenameVaultDialog {
  controller?: CustomDialogController;
  /** 预填现名（= 当前 id，由 Index 在拉起时传入） */
  initialName: string = '';
  @State rawName: string = '';
  onConfirm: (name: string) => void = (name: string) => {};

  private sanitized(): string {
    return sanitizeVaultName(this.rawName);
  }

  /** 实时预览：改名前后路径对照（改名场景下自己原名不算重名） */
  private hintText(): string {
    const s: string = this.sanitized();
    if (s.length === 0) {
      return BAD_NAME_HINT;
    }
    const id: string = VaultRegistry.get().uniqueVaultId(s, this.initialName);
    if (id !== s) {
      return 'vaults/' + this.initialName + ' → vaults/' + id + '（与现有库重名，已自动加后缀）';
    }
    return 'vaults/' + this.initialName + ' → vaults/' + id;
  }

  private confirm(): void {
    if (this.sanitized().length === 0) {
      return;
    }
    this.controller?.close();
    this.onConfirm(this.rawName);
  }

  build() {
    Column() {
      Text('重命名「' + this.initialName + '」')
        .fontSize(FontSize.body2)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text('目录名一起改，库内的笔记不受影响。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: Space.s2, bottom: Space.s3 })
      TextInput({ text: this.initialName, placeholder: '库名称' })
        .height(Size.buttonH)
        .fontSize(FontSize.body2)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .padding({ left: Space.s3, right: Space.s3 })
        .backgroundColor($r('app.color.bg_secondary'))
        .borderRadius(Radius.control)
        .onChange((value: string) => {
          this.rawName = value;
        })
      Text(this.hintText())
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .margin({ top: Space.s2 })
      Row({ space: Space.s2 }) {
        Text('取消')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_primary'))
          .height(30)
          .padding({ left: Space.s4, right: Space.s4 })
          .textAlign(TextAlign.Center)
          .borderRadius(Radius.icon)
          .border({ width: 1, color: $r('app.color.line') })
          .backgroundColor($r('app.color.bg_secondary'))
          .onClick(() => {
            this.controller?.close();
          })
        Text('保存')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.on_brand'))
          .height(30)
          .padding({ left: Space.s4, right: Space.s4 })
          .textAlign(TextAlign.Center)
          .borderRadius(Radius.icon)
          .backgroundColor($r('app.color.brand'))
          .enabled(this.sanitized().length > 0)
          .opacity(this.sanitized().length > 0 ? 1 : 0.4)
          .onClick(() => {
            this.confirm();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: Space.s4 })
    }
    .width(Size.drawerW)
    .padding(Space.s4)
    .borderRadius(Radius.dialog)
    .backgroundColor($r('app.color.bg_card'))
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 删除确认对话框（spec FR-011）：
 * 标题「删除本地笔记？」+ 不可逆/无法恢复明示 + vaults/<id> 路径展示；
 * 不出现「建议先导出备份」（zip 导出未实现）。
 */
@CustomDialog
export struct DeleteVaultDialog {
  controller?: CustomDialogController;
  /** 待删库 id（= 目录名 = 显示名，由 Index 在拉起时传入） */
  vaultId: string = '';
  onConfirm: () => void = () => {};

  private confirm(): void {
    this.controller?.close();
    this.onConfirm();
  }

  build() {
    Column() {
      Text('删除本地笔记？')
        .fontSize(FontSize.body2)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text('该目录下的所有笔记会被永久删除，且无法恢复。')
        .fontSize(FontSize.body3)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: Space.s2, bottom: Space.s3 })
      Text('vaults/' + this.vaultId)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .padding({ left: Space.s2, right: Space.s2, top: 5, bottom: 5 })
        .backgroundColor($r('app.color.bg_secondary'))
        .borderRadius(Radius.icon)
        .margin({ bottom: Space.s3 })
      Row({ space: Space.s2 }) {
        Text('取消')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.text_primary'))
          .height(30)
          .padding({ left: Space.s4, right: Space.s4 })
          .textAlign(TextAlign.Center)
          .borderRadius(Radius.icon)
          .border({ width: 1, color: $r('app.color.line') })
          .backgroundColor($r('app.color.bg_secondary'))
          .onClick(() => {
            this.controller?.close();
          })
        Text('确认删除')
          .fontSize(FontSize.body3)
          .fontColor($r('app.color.danger'))
          .height(30)
          .padding({ left: Space.s4, right: Space.s4 })
          .textAlign(TextAlign.Center)
          .borderRadius(Radius.icon)
          .border({ width: 1, color: $r('app.color.danger') })
          .backgroundColor($r('app.color.danger_bg'))
          .onClick(() => {
            this.confirm();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width(Size.drawerW)
    .padding(Space.s4)
    .borderRadius(Radius.dialog)
    .backgroundColor($r('app.color.bg_card'))
    .alignItems(HorizontalAlign.Start)
  }
}
