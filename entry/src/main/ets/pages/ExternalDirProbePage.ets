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
  ExternalDirProbeRunner, ProbeStep, describeProbeStep, displayNameFromUri, selectProbeMarkdown,
  safeDecodeUriComponent
} from '../model/ExternalDirProbe';
import { createDeviceProbeRunner, createVaultDirScanner, createVaultDirFileStore, supportsFolderSelection } from '../model/ExternalDirProbeDevice';
import {
  describeVaultDirError, selectVaultMarkdown as pickVaultMarkdown,
  VaultDirEntry, VaultDirScanResult, VaultDirectoryScanner,
  VaultDirFileStore, VaultDirIoResult, VaultDirReadResult
} from '../model/VaultDirNative';

const DOMAIN: number = 0x5941;
const TAG: string = 'ProbeRunner';

/*
 * 写链路核实只用这一对探针文件：全程新建→改写→改名→删除，末尾自清理。
 * 选中的目录可能是用户真实的 Download，不能碰任何已有笔记，也不能留垃圾。
 * 内容用定长可预测的字符串，便于「写后回读是否一致」做严格相等比较。
 */
const PROBE_FILE: string = '__yaoshi_probe_write.md';
const PROBE_FILE_RENAMED: string = '__yaoshi_probe_renamed.md';
const PROBE_CONTENT_LONG: string = '# 曜石笔记写链路核实\n\n这是一次性探针文件，用于验证 openat 写入。\n0123456789abcdefghijklmnopqrstuvwxyz\n';
const PROBE_CONTENT_SHORT: string = '# short';

@Entry
@Component
struct ExternalDirProbePage {
  @State steps: ProbeStep[] = [];
  @State dirLabel: string = '尚未选择目录';
  @State busy: boolean = false;
  @State markdownCount: number = 0;
  private runner: ExternalDirProbeRunner = createDeviceProbeRunner(
    getContext(this) as common.UIAbilityContext);
  private scanner: VaultDirectoryScanner = createVaultDirScanner();
  private store: VaultDirFileStore = createVaultDirFileStore();
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
      // 完整 URI 直接展示/hilog：路径里只有目录名（页面本来就显示），不含笔记内容
      this.push(describeProbeStep('select', true, 0, 'URI = ' + uri));

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
        return `listFileSync 列出 ${entries.length} 条，其中 Markdown ${markdown.length} 条`;
      });
      // Native 侧 fd 遍历：**无论上面成败都要跑** —— 它才是要回填的答案。
      // 官方答复（2026-10-31）给的通路是「openSync(目录URI) 拿 fd → Native fdopendir」。
      await this.probeNativeList(uri);
      await this.stepOf('atomic', async () => {
        const target: string[] = this.firstMarkdown.length > 0 ? [this.firstMarkdown] : [];
        const step: ProbeStep = await this.runner.probeWrite(uri, target);
        if (!step.ok) {
          throw new Error(step.detail);
        }
        return step.detail;
      });
      await this.probeNativeWrite(uri);
      await this.diagnoseListFailures(uri);
    } finally {
      this.busy = false;
    }
  }

  /**
   * Native fd 遍历核实（2026-10-31 加）：官方答复确认「ArkTS 侧没有基于 fd 的 readdir」，
   * 通路是 openSync(目录URI) 拿 fd → Native fdopendir/openat。这里两级都跑：
   * 单层（证明 fdopendir 能吃这个 fd）+ 递归（证明 openat 能进子目录、授权顺延）。
   *
   * **部分成功也算成功**：命中无权进入的子目录时 native 会带 code 但仍返回已拿到的条目，
   * 这种时候不能判死，要把数量显示出来。
   */
  private async probeNativeList(uri: string): Promise<void> {
    await this.stepOf('native_flat', async () => {
      const result: VaultDirScanResult = this.scanner.scan(uri, false);
      if (!result.ok && result.entries.length === 0) {
        throw new Error(describeVaultDirError(result.code) + ' / ' + result.message);
      }
      const suffix: string = result.ok ? '' : '（部分成功：' + result.message + '）';
      return `单层 fdopendir 拿到 ${result.entries.length} 条` + suffix;
    });

    await this.stepOf('native_recursive', async () => {
      const result: VaultDirScanResult = this.scanner.scan(uri, true);
      if (!result.ok && result.entries.length === 0) {
        throw new Error(describeVaultDirError(result.code) + ' / ' + result.message);
      }
      this.applyScanResult(result);
      let preview: string = '';
      for (let i = 0; i < result.entries.length && i < 6; i++) {
        preview += result.entries[i].path + ' ';
      }
      const suffix: string = result.ok ? '' : '（部分成功：' + result.message + '）';
      return `递归 ${result.entries.length} 条 / Markdown ${this.markdownCount} 条` + suffix + '｜前几条：' + preview;
    });
  }

  /**
   * Native 写链路核实（第二轮答复给的形态）：tmp → fsync → renameat 覆盖，
   * 外加 unlinkat / renameat。全部只作用于探针文件 `PROBE_FILE`，
   * **末尾必须自己删掉** —— 这次选的目录可能是用户真实的 Download，
   * 不能往里丢垃圾，也不碰任何已有笔记。
   */
  private async probeNativeWrite(uri: string): Promise<void> {
    await this.stepOf('native_read', async () => {
      if (this.firstMarkdown.length === 0) {
        return '目录里没有 Markdown，跳过（不影响写链路核实）';
      }
      const result: VaultDirReadResult = this.store.read(uri, this.firstMarkdown);
      if (!result.ok) {
        throw new Error(describeVaultDirError(result.code) + ' / ' + result.message);
      }
      return `读到 ${result.content.length} 字节`;
    });

    await this.stepOf('native_write', async () => {
      const written: VaultDirIoResult = this.store.write(uri, PROBE_FILE, PROBE_CONTENT_LONG);
      if (!written.ok) {
        throw new Error(describeVaultDirError(written.code) + ' / ' + written.message);
      }
      const back: VaultDirReadResult = this.store.read(uri, PROBE_FILE);
      if (!back.ok || back.content !== PROBE_CONTENT_LONG) {
        throw new Error('写后回读不一致（期望 ' + PROBE_CONTENT_LONG.length + ' 字节，实得 ' + back.content.length + '）');
      }
      return `新建并回读一致（${PROBE_CONTENT_LONG.length} 字节）`;
    });

    await this.stepOf('native_overwrite', async () => {
      const written: VaultDirIoResult = this.store.write(uri, PROBE_FILE, PROBE_CONTENT_SHORT);
      if (!written.ok) {
        throw new Error(describeVaultDirError(written.code) + ' / ' + written.message);
      }
      const back: VaultDirReadResult = this.store.read(uri, PROBE_FILE);
      if (!back.ok || back.content !== PROBE_CONTENT_SHORT) {
        throw new Error('覆盖后残留旧内容（实得 ' + back.content.length + ' 字节）');
      }
      return `变短覆盖无残留（${PROBE_CONTENT_LONG.length} → ${PROBE_CONTENT_SHORT.length} 字节）`;
    });

    await this.stepOf('native_rename', async () => {
      const renamed: VaultDirIoResult = this.store.rename(uri, PROBE_FILE, PROBE_FILE_RENAMED);
      if (!renamed.ok) {
        throw new Error(describeVaultDirError(renamed.code) + ' / ' + renamed.message);
      }
      const after: VaultDirReadResult = this.store.read(uri, PROBE_FILE_RENAMED);
      if (!after.ok) {
        throw new Error('改名后按新名读不到：' + describeVaultDirError(after.code));
      }
      return 'renameat 成功，按新名可读';
    });

    await this.stepOf('native_delete', async () => {
      const removed: VaultDirIoResult = this.store.remove(uri, PROBE_FILE_RENAMED);
      if (!removed.ok) {
        throw new Error(describeVaultDirError(removed.code) + ' / ' + removed.message);
      }
      const gone: VaultDirReadResult = this.store.read(uri, PROBE_FILE_RENAMED);
      if (gone.ok) {
        throw new Error('删除后仍能读到，unlinkat 未生效');
      }
      return 'unlinkat 成功，探针文件已清理';
    });
  }

  /** 把遍历结果折算成界面要显示的两个数字 + 第一个可写的 Markdown。 */
  private applyScanResult(result: VaultDirScanResult): void {
    const markdown: string[] = pickVaultMarkdown(result.entries);
    this.markdownCount = markdown.length;
    this.firstMarkdown = markdown.length > 0 ? markdown[0] : '';
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

  /**
   * v1.5 核实诊断（2026-10-31 加）：listFileSync 对 Picker 目录 URI 报 13900002 后，
   * 依次试「解码后 URI 的 listFile」「原样/解码 URI 的 openSync」，把失败形态钉死。
   * 这些步骤成功与否都照常显示 —— 结论回填 api_notes T3 后随临时页一起删除。
   */
  private async diagnoseListFailures(uri: string): Promise<void> {
    const listFailed: boolean = this.steps.some((step: ProbeStep): boolean =>
      step.id === 'list' && !step.ok);
    if (!listFailed) {
      return;
    }
    const decoded: string = safeDecodeUriComponent(uri);
    if (decoded !== uri) {
      await this.stepOf('diag_list_decoded', async () => {
        const entries: string[] = this.runner.listEntries(decoded);
        return '解码后 listFileSync 列出 ' + entries.length + ' 条';
      });
    }
    await this.stepOf('diag_open_raw', async () => {
      const fd: number = this.runner.openDirForDiagnosis(uri);
      this.runner.closeDirForDiagnosis(fd);
      return '原样 openSync 成功（fd 可用）';
    });
    if (decoded !== uri) {
      await this.stepOf('diag_open_decoded', async () => {
        const fd: number = this.runner.openDirForDiagnosis(decoded);
        this.runner.closeDirForDiagnosis(fd);
        return '解码后 openSync 成功（fd 可用）';
      });
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
        return `重启后 listFileSync 列出 ${entries.length} 条`;
      });
      await this.stepOf('native_recursive', async () => {
        const result: VaultDirScanResult = this.scanner.scan(this.currentUri, true);
        if (!result.ok && result.entries.length === 0) {
          throw new Error(describeVaultDirError(result.code) + ' / ' + result.message);
        }
        return `重启后 Native 递归仍拿到 ${result.entries.length} 条（URI 未走 Picker，仅靠持久授权）`;
      });
      await this.stepOf('atomic', async () => {
        const target: string[] = this.firstMarkdown.length > 0 ? [this.firstMarkdown] : [];
        const step: ProbeStep = await this.runner.probeWrite(this.currentUri, target);
        if (!step.ok) {
          throw new Error(step.detail);
        }
        return '重启后原子写：' + step.detail;
      });
      // 写链路也要证明「重激活之后仍然成立」—— 这是 v1.5 每次启动都要做的事，
      // 只验一次会话是不够的。探针文件同样自清理。
      await this.probeNativeWrite(this.currentUri);
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
        }, (step: ProbeStep, index: number): string => index + '-' + step.id)
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
