import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { HttpRequestMsg, HttpResultMsg } from './GitBridgeModels';

/**
 * 桥接层的 http 后端。
 *
 * 存在的意义：github.com 的 git 服务端点不返回 CORS 头，WebView 内 fetch 会被拦；
 * 这里改用原生 @ohos.net.http 发请求，天然不受同源策略限制。
 */
export class GitHttpBackend {
  private base64: util.Base64Helper = new util.Base64Helper();

  async request(msg: HttpRequestMsg): Promise<HttpResultMsg> {
    const req = http.createHttp();
    try {
      // ArkTS 要求对象字面量有显式类型，不能直接写 ?? {}
      const headers: Record<string, string> = msg.headers ? msg.headers : {};
      const options: http.HttpRequestOptions = {
        method: this.toMethod(msg.method),
        header: headers,
        // git 报文是二进制，必须按 ARRAY_BUFFER 取，否则会被当字符串解码破坏
        expectDataType: http.HttpDataType.ARRAY_BUFFER
      };
      if (msg.bodyB64 && msg.bodyB64.length > 0) {
        options.extraData = this.base64.decodeSync(msg.bodyB64).buffer;
      }

      const resp = await req.request(msg.url, options);
      let body = new Uint8Array(0);
      if (resp.result instanceof ArrayBuffer) {
        body = new Uint8Array(resp.result);
      }
      return {
        url: msg.url,
        method: msg.method,
        headers: this.toRecord(resp.header),
        bodyB64: this.base64.encodeToStringSync(body),
        status: resp.responseCode,
        statusMessage: ''
      };
    } finally {
      req.destroy();
    }
  }

  private toMethod(method: string): http.RequestMethod {
    switch (method) {
      case 'POST':
        return http.RequestMethod.POST;
      case 'PUT':
        return http.RequestMethod.PUT;
      case 'HEAD':
        return http.RequestMethod.HEAD;
      case 'DELETE':
        return http.RequestMethod.DELETE;
      default:
        return http.RequestMethod.GET;
    }
  }

  private toRecord(header: Object): Record<string, string> {
    const out: Record<string, string> = {};
    const src = header as Record<string, Object>;
    for (const key of Object.keys(src)) {
      const value = src[key];
      out[key] = value === undefined || value === null ? '' : String(value);
    }
    return out;
  }
}
