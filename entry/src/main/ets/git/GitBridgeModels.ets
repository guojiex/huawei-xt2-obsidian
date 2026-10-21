/**
 * 桥接层消息模型。
 *
 * 设计约束：JS 侧所有二进制/路径字段一律 base64，避免中文路径、二进制内容
 * 在 JSON / runJavaScript 传参时被转义或编码破坏。
 */

/** fs 单条操作（批量提交时的元素） */
export interface FsOpMsg {
  op: string;
  pathB64: string;
  dataB64?: string;
  newPathB64?: string;
}

/** JS -> ArkTS 的 fs 请求 */
export interface FsRequestMsg {
  op: string;
  pathB64?: string;
  dataB64?: string;
  newPathB64?: string;
  ops?: FsOpMsg[];
}

/** JS -> ArkTS 的 http 请求 */
export interface HttpRequestMsg {
  url: string;
  method: string;
  headers: Record<string, string>;
  bodyB64?: string;
}

/** http 响应（回传给 JS） */
export interface HttpResultMsg {
  url: string;
  method: string;
  headers: Record<string, string>;
  bodyB64: string;
  status: number;
  statusMessage: string;
}

/** fs read 结果 */
export interface FsReadResult {
  dataB64: string;
}

/** fs readdir 结果 */
export interface FsReaddirResult {
  entries: string[];
}

/** fs stat 结果 */
export interface FsStatResult {
  type: string;
  size: number;
}

/** 通用 ok 结果 */
export interface OkResult {
  ok: boolean;
}

/** Web 组件 postMessage 上来的原始消息（字段按需解析） */
export interface BridgeMsg {
  id?: number;
  type?: string;
  name?: string;
  op?: string;
  pathB64?: string;
  dataB64?: string;
  newPathB64?: string;
  ops?: FsOpMsg[];
  url?: string;
  method?: string;
  headers?: Record<string, string>;
  bodyB64?: string;
  phase?: string;
  loaded?: number;
  total?: number;
  ok?: boolean;
  message?: string;
}

/** clone 进度 */
export interface GitProgress {
  phase: string;
  loaded: number;
  total: number;
}
