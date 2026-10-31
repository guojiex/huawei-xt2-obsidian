/**
 * ExternalDirProbePage.ets —— v1.5 前置核实的**页面中转站**（临时存在）
 *
 * 为什么要有页面：T3/T4 那些 ❓ 必须在真机上拉起 Picker 才能拿到答案，
 * 单纯的 Node 单测（test_external_dir_probe.mjs）只能证明样例代码的时序，
 * 证明不了系统行为。所以这里提供最小的触发 UI：
 *   选目录 → 持久化 → 查询 → 递归列出 → 读写验证
 * 每一步的真实返回值直接显示在界面上，同时打 hilog（`ProbeRunner` tag）。
 *
 * **不涉及任何产品语义**：不写 VaultRegistry、不改库类型、不碰现有编辑器。
 * v1.5 正式实现（15.1–15.6）落地后本页连同 model 一起删除。
 *
 * 隐私：界面只显示目录名与**文件数量**，不显示笔记正文；打 hilog 的也只有
 * 步骤结论与错误码 —— 硬约束 16 禁止笔记内容上报/记录。
 */
import { router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { FontSize, Radius, Space } from '../common/Tokens';
import {
  ExternalDirProbeRunner, ProbeStep, describeProbeStep, displayNameFromUri, selectProbeMarkdown
} from '../model/ExternalDirProbe';
import { createDeviceProbeRunner, supportsFolderSelection } from '../model/ExternalDirProbeDevice';

const DOMAIN: number = 0x5941;
const TAG: string = 'ProbeRunner';

@Entry
@Component
struct ExternalDirProbePage {
  @State steps: ProbeStep[] = [];
  @State dirLabel: string = '尚未选择目录';
  @State busy: boolean = false;
  @State markdownCount: number = 0;
  private runner: ExternalDirProbeRunner = createDeviceProbeRunner(
    getContext(this) as common.UIAbilityContext);
  private currentUri: string = '';
  private firstMarkdown: string = '';

  private logStep(step: ProbeStep): void {
    hilog.info(DOMAIN, TAG, 'step %{public}s ok=%{public}s detail=%{public}s',
      step.id, String(step.ok), step.detail);
  }

  private push(step: ProbeStep): void {
    this.steps = [...this.steps, step];
    this.logStep(step);
  }

  /** 一步失败就停下，把失败原因显示出来 —— 这就是要回填进 api_notes 的东西。 */
  private async runOnce(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.steps = [];
    try {
      const supported: boolean = supportsFolderSelection();
      this.push(describeProbeStep('syscap', supported, 0,
        supported ? 'canIUse 通过' : 'canIUse 不支持 FolderSelection'));
      if (!supported) {
        return;
      }

      const uri: string = await this.runner.pickDirectory();
      if (uri.length === 0) {
        this.push(describeProbeStep('select', false, 0, '未取到目录（取消或返回非 URI）'));
        return;
      }
      this.currentUri = uri;
      this.dirLabel = displayNameFromUri(uri);
      this.push(describeProbeStep('select', true, 0, 'URI 形如 ' + uri.slice(0, 32) + '…'));

      await this.stepOf('persist', async () => {
        await this.runner.persist(uri);
        return '临时授权已持久化';
      });
      await this.stepOf('check', async () => {
        const ok: boolean = await this.runner.checkPersisted(uri);
        if (!ok) {
          throw new Error('checkPersistentPermission 返回 false');
        }
        return 'checkPersistentPermission 为 true';
      });
      await this.stepOf('activate', async () => {
        await this.runner.activate(uri);
        return 'activatePermission 未抛错';
      });
      await this.stepOf('list', async () => {
        const entries: string[] = this.runner.listEntries(uri);
        const markdown: string[] = selectProbeMarkdown(entries);
        this.markdownCount = markdown.length;
        this.firstMarkdown = markdown.length > 0 ? markdown[0] : '';
        return `列出 ${entries.length} 条，其中 Markdown ${markdown.length} 条`;
      });
      await this.stepOf('atomic', async () => {
        const target: string[] = this.firstMarkdown.length > 0 ? [this.firstMarkdown] : [];
        const step: ProbeStep = await this.runner.probeWrite(uri, target);
        if (!step.ok) {
          throw new Error(step.detail);
        }
        return step.detail;
      });
    } finally {
      this.busy = false;
    }
  }

  /** 把抛异常的每一步收敛成一条失败记录，错误码从 BusinessError 里掏出来。 */
  private async stepOf(id: string, action: () => Promise<string>): Promise<void> {
    try {
      const detail: string = await action();
      this.push(describeProbeStep(id, true, 0, detail));
    } catch (error) {
      const code: number = ExternalDirProbeRunner.errorCodeOf(error);
      this.push(describeProbeStep(id, false, code, '失败'));
    }
  }

  /** 重启后的那一步单独验证：只做激活 + 列出，不再拉 Picker。 */
  private async runAfterRestart(): Promise<void> {
    if (this.busy || this.currentUri.length === 0) {
      return;
    }
    this.busy = true;
    try {
      await this.stepOf('activate', async () => {
        await this.runner.activate(this.currentUri);
        return '重启后 activatePermission 成功';
      });
      await this.stepOf('list', async () => {
        const entries: string[] = this.runner.listEntries(this.currentUri);
        return `重启后仍可递归列出 ${entries.length} 条`;
      });
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(FontSize.body1)
          .onClick(() => {
            if (!this.busy) {
              router.back();
            }
          })
        Blank()
        Text('外部目录核实')
          .fontSize(FontSize.s2)
          .fontWeight(FontWeight.Bold)
        Blank()
        Text('‹ 返回')
          .fontSize(FontSize.body1)
          .fontColor(Color.Transparent)
      }
      .width('100%')
      .margin({ bottom: Space.s2 })

      Text('当前目录：' + this.dirLabel)
        .fontSize(FontSize.caption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ bottom: Space.s2 })

      Row({ space: Space.s2 }) {
        Button('跑一遍完整核实')
          .enabled(!this.busy)
          .onClick(() => {
            void this.runOnce();
          })
        Button('验证重启后仍可用')
          .enabled(!this.busy && this.currentUri.length > 0)
          .onClick(() => {
            void this.runAfterRestart();
          })
      }
      .margin({ bottom: Space.s2 })

      List({ space: Space.s2 }) {
        ForEach(this.steps, (step: ProbeStep) => {
          ListItem() {
            Column({ space: Space.s1 }) {
              Row() {
                Text(step.ok ? '✅' : '❌')
                  .fontSize(FontSize.body2)
                Text(step.label)
                  .fontSize(FontSize.body2)
                  .fontWeight(FontWeight.Bold)
                Blank()
              }
              .width('100%')
              Text(step.detail)
                .fontSize(FontSize.caption)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
            }
            .width('100%')
            .padding(Space.s3)
            .borderRadius(Radius.card)
            .backgroundColor($r('app.color.bg_card'))
          }
        }, (step: ProbeStep) => step.id)
      }
      .width('100%')
      .layoutWeight(1)
    }
    .backgroundColor($r('app.color.bg_page'))
    .padding(Space.s4)
    .width('100%')
    .height('100%')
  }
}
