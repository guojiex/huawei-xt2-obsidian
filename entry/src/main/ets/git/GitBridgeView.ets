import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { GitFsBackend } from './GitFsBackend';
import { GitHttpBackend } from './GitHttpBackend';
import {
  BridgeMsg,
  FsOpMsg,
  FsReadResult,
  FsReaddirResult,
  FsStatResult,
  GitProgress,
  HttpRequestMsg,
  HttpResultMsg,
  OkResult
} from './GitBridgeModels';

/** 注入到 WebView window.__arkts 的对象：JS -> ArkTS 的唯一入口 */
class GitNativeProxy {
  handler: (msg: string) => void = () => {};

  postMessage(msg: string): void {
    this.handler(msg);
  }
}

/** 桥接层内部实现，由组件在页面就绪后注入 controller */
class GitBridgeImpl {
  private controller: webview.WebviewController;
  private fsBackend: GitFsBackend;
  private base64: util.Base64Helper = new util.Base64Helper();
  private encoder: util.TextEncoder = new util.TextEncoder();

  constructor(controller: webview.WebviewController, fsBackend: GitFsBackend) {
    this.controller = controller;
    this.fsBackend = fsBackend;
  }

  async init(gitDir: string, token: string, username: string): Promise<void> {
    const payload = this.toB64(JSON.stringify({
      gitDir: gitDir,
      token: token,
      username: username
    }));
    await this.controller.runJavaScript(`window.GitBridge.init('${payload}')`);
  }

  async clone(url: string, branch: string, token: string, username: string): Promise<void> {
    const payload = this.toB64(JSON.stringify({
      url: url,
      branch: branch,
      token: token,
      username: username
    }));
    // 结果是异步的，通过 cloneResult 事件回传，这里只负责发起
    await this.controller.runJavaScript(`window.GitBridge.clone('${payload}')`);
  }

  async flush(): Promise<void> {
    await this.controller.runJavaScript('window.GitBridge.flush()');
  }

  private toB64(text: string): string {
    return this.base64.encodeToStringSync(this.encoder.encodeInto(text));
  }
}

/** 父组件持有的句柄：页面就绪前调用会直接失败，由调用方保证时序 */
export class GitBridgeController {
  private impl: GitBridgeImpl | undefined = undefined;
  private readyFlag: boolean = false;

  bind(impl: GitBridgeImpl): void {
    this.impl = impl;
    this.readyFlag = true;
  }

  get ready(): boolean {
    return this.readyFlag;
  }

  async init(gitDir: string, token: string, username: string): Promise<void> {
    await this.impl?.init(gitDir, token, username);
  }

  async clone(url: string, branch: string, token: string, username: string): Promise<void> {
    await this.impl?.clone(url, branch, token, username);
  }

  async flush(): Promise<void> {
    await this.impl?.flush();
  }
}

/**
 * 承载 isomorphic-git 的隐形 Web 组件 + 协议分发。
 *
 * 之所以还能保持轻量：JS 侧只做计算不碰 DOM，因此不需要任何可见区域。
 */
@Component
export struct GitBridgeView {
  @Prop vaultRoot: string = '';
  @Prop gitDir: string = '/vault';
  @Prop token: string = '';
  /** Gitee 自建 GitLab 私有库需要；GitHub 留空即可 */
  @Prop username: string = '';
  bridgeController: GitBridgeController = new GitBridgeController();
  onProgress: (p: GitProgress) => void = () => {};
  onLog: (msg: string) => void = () => {};
  onCloneDone: (ok: boolean, message: string) => void = () => {};

  private controller: webview.WebviewController = new webview.WebviewController();
  private proxy: GitNativeProxy = new GitNativeProxy();
  private httpBackend: GitHttpBackend = new GitHttpBackend();
  private fsBackend: GitFsBackend | undefined = undefined;
  private base64: util.Base64Helper = new util.Base64Helper();
  private encoder: util.TextEncoder = new util.TextEncoder();

  aboutToAppear(): void {
    this.proxy.handler = (msg: string) => {
      this.handleMessage(msg);
    };
  }

  private handleMessage(json: string): void {
    let msg: BridgeMsg = { type: '' };
    try {
      msg = JSON.parse(json) as BridgeMsg;
    } catch (e) {
      this.onLog('桥接消息解析失败: ' + json);
      return;
    }

    if (msg.type === 'event') {
      if (msg.name === 'progress') {
        this.onProgress({
          phase: msg.phase ?? '',
          loaded: msg.loaded ?? 0,
          total: msg.total ?? 0
        });
      } else if (msg.name === 'cloneResult') {
        this.onCloneDone(msg.ok ?? false, msg.message ?? '');
      } else {
        this.onLog('event: ' + (msg.name ?? ''));
      }
      return;
    }

    const id = msg.id ?? 0;
    if (msg.type === 'fs') {
      try {
        this.reply(id, true, this.handleFs(msg));
      } catch (e) {
        this.replyError(id, e);
      }
      return;
    }

    if (msg.type === 'http') {
      const headers: Record<string, string> = msg.headers ? msg.headers : {};
      const request: HttpRequestMsg = {
        url: msg.url ?? '',
        method: msg.method ?? 'GET',
        headers: headers,
        bodyB64: msg.bodyB64
      };
      this.httpBackend.request(request).then((result: HttpResultMsg) => {
        this.reply(id, true, result);
      }).catch((e: Error) => {
        this.replyError(id, e);
      });
    }
  }

  private handleFs(msg: BridgeMsg): Object {
    const backend = this.fsBackend;
    if (!backend) {
      throw new Error('EINIT: fs backend 未初始化');
    }
    const rel = msg.pathB64 ? this.decodePath(msg.pathB64) : '';
    switch (msg.op) {
      case 'read':
        return backend.read(rel) as FsReadResult;
      case 'write':
        return backend.write(rel, msg.dataB64 ?? '') as OkResult;
      case 'mkdir':
        return backend.mkdir(rel) as OkResult;
      case 'unlink':
        return backend.unlink(rel) as OkResult;
      case 'rmdir':
        return backend.rmdir(rel) as OkResult;
      case 'rename':
        return backend.rename(rel, this.decodePath(msg.newPathB64 ?? '')) as OkResult;
      case 'readdir':
        return backend.readdir(rel) as FsReaddirResult;
      case 'stat':
        return backend.stat(rel) as FsStatResult;
      case 'batch':
        return backend.batch((msg.ops ?? []) as FsOpMsg[]) as OkResult;
      default:
        throw new Error('ENOSYS: unsupported fs op ' + (msg.op ?? ''));
    }
  }

  private decodePath(pathB64: string): string {
    const bytes = this.base64.decodeSync(pathB64);
    return new util.TextDecoder().decodeToString(bytes);
  }

  private reply(id: number, ok: boolean, payload: Object): void {
    const b64 = this.base64.encodeToStringSync(this.encoder.encodeInto(JSON.stringify(payload)));
    this.controller.runJavaScript(`window.__gitBridge.onResult(${id}, ${ok}, '${b64}')`);
  }

  /** 失败回包：JS 侧会把 "CODE: msg" 还原成带 code 的 Error */
  private replyError(id: number, e: Error | Object): void {
    const text = e instanceof Error ? (e.message ?? String(e)) : String(e);
    const b64 = this.base64.encodeToStringSync(this.encoder.encodeInto(JSON.stringify(text)));
    this.controller.runJavaScript(`window.__gitBridge.onResult(${id}, false, '${b64}')`);
  }

  build() {
    // 隐形引擎：给它 1x1 的尺寸保证能被创建和加载，但不占可见空间
    Web({ src: $rawfile('gitbridge/index.html'), controller: this.controller })
      .javaScriptProxy({
        object: this.proxy,
        name: '__arkts',
        methodList: ['postMessage'],
        controller: this.controller
      })
      .onPageEnd(() => {
        const backend = new GitFsBackend(this.vaultRoot);
        backend.ensureRoot();
        this.fsBackend = backend;
        this.bridgeController.bind(new GitBridgeImpl(this.controller, backend));
        this.bridgeController.init(this.gitDir, this.token, this.username).then(() => {
          this.onLog('git 桥接层就绪');
        }).catch((e: Error) => {
          this.onLog('初始化失败: ' + e.message);
        });
      })
      .onErrorReceive((event) => {
        this.onLog('Web 加载错误: ' + (event?.error?.getErrorInfo() ?? ''));
      })
      .width(1)
      .height(1)
      .opacity(0)
  }
}
