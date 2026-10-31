import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

// 为什么单独拎出来：Windows 的 core.autocrlf=true 会把工作树里的 .ets / .html 全部签出为 CRLF，
// 而这些 Node 测试用 \n 做源码切片、正则与 import 剥离，CRLF 会让定位失败并把残留 import
// 交给 esbuild 变成 require —— 在 vm 里报 "require is not defined"。统一在这里归一到 LF，
// 避免每个测试各写一遍替换。（同一问题已在 test_sample_vault.mjs 修过一次。）
export function readSourceFile(url) {
  return fs.readFileSync(url, 'utf8').replace(/\r\n/g, '\n');
}

// new URL(...).pathname 在 Windows 上会得到 "/E:/github/..." 这种 esbuild 无法解析的路径，
// 交给 esbuild 的 entryPoints 必须用 fileURLToPath。
export function resolveSourcePath(url) {
  return fileURLToPath(url);
}
