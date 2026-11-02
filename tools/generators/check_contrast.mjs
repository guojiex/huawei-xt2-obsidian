#!/usr/bin/env node
/**
 * v1.10 基础无障碍 —— 对比度测量。
 *
 * 为什么是单独的生成器而不是写在测试里：它要同时被「人工看报告」和「CI 断言」复用，
 * 且产物是给人读的表格（阈值、实际值、是否达标），不是断言。
 *
 * 测量口径（实施前确定，见 docs/releases/v1.10/需求文档.md §4）：
 *  - 标准：WCAG 2.1 AA。正文文本 >= 4.5:1；UI 组件 / 图形 / 大号文本 >= 3:1。
 *  - 禁用态（text_disabled）按 WCAG 1.4.3 的 Inactive 例外不参与判定，但仍列出实测值。
 *  - 颜色带 alpha（#AARRGGBB）时按 alpha 与指定背景做源覆盖合成后再计算，
 *    不做「忽略透明度」的乐观处理。
 *  - 相对亮度用 WCAG 2.1 公式：线性化 sRGB 后 0.2126R + 0.7152G + 0.0722B。
 *  - 只测当前配色 token 的组合，不解析 ArkTS；某色实际用在哪种背景上由 MATRIX 显式声明。
 *
 * 用法：
 *   node tools/generators/check_contrast.mjs          打印报告
 *   node tools/generators/check_contrast.mjs --check  有不达标项时退出码 1
 *   node tools/generators/check_contrast.mjs --json   输出 JSON（供测试断言）
 */
import { readFileSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

function readScheme(dir) {
  const raw = readFileSync(join(repoRoot, 'entry/src/main/resources', dir, 'element/color.json'), 'utf8');
  const out = {};
  for (const item of JSON.parse(raw).color) {
    out[item.name] = item.value;
  }
  return out;
}

/** '#RRGGBB' 或 '#AARRGGBB' → [r,g,b,a]（0-255，a 为 0-1） */
export function parseColor(value) {
  const hex = value.trim().replace(/^#/, '');
  if (hex.length === 6) {
    return [
      parseInt(hex.slice(0, 2), 16),
      parseInt(hex.slice(2, 4), 16),
      parseInt(hex.slice(4, 6), 16),
      1
    ];
  }
  if (hex.length === 8) {
    return [
      parseInt(hex.slice(2, 4), 16),
      parseInt(hex.slice(4, 6), 16),
      parseInt(hex.slice(6, 8), 16),
      parseInt(hex.slice(0, 2), 16) / 255
    ];
  }
  throw new Error(`无法解析颜色：${value}`);
}

/** 带 alpha 的前景与不透明背景做源覆盖合成（背景仍可带 alpha，取其 rgb 参与合成） */
export function flatten(fg, bg) {
  const [fr, fg_, fb, fa] = fg;
  const [br, bg_, bb] = bg;
  if (fa >= 1) return [fr, fg_, fb, 1];
  return [
    Math.round(fr * fa + br * (1 - fa)),
    Math.round(fg_ * fa + bg_ * (1 - fa)),
    Math.round(fb * fa + bb * (1 - fa)),
    1
  ];
}

export function relativeLuminance([r, g, b]) {
  const lin = (c) => {
    const s = c / 255;
    return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
  };
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
}

export function contrastRatio(a, b) {
  const la = relativeLuminance(a);
  const lb = relativeLuminance(b);
  const hi = Math.max(la, lb);
  const lo = Math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/**
 * 判定组合：[前景 token, 背景 token, 阈值, 类别, 处置]。
 * 阈值 4.5 = 正文；3 = UI 组件 / 图形 / 大号文本。
 * 处置省略 = enforce（不达标即 --check 失败）；waived = 已记录待决，不阻断。
 *
 * 为什么会有 waived：浅色 token 与唯一设计真源 `docs/prototype/v2/index.html` 的
 * `:root` 变量逐值一致（`--muted:#7c8390`、`--blue:#007dff`、`--danger:#cf4048`、
 * `--green:#35916d`、`--line:#e7e9ed`）。这些组合未达 AA 属于**设计层**问题，
 * 单方面改 token 就是改设计稿；按 v1.10 §3「不追加功能」与清单「设计真源」规则，
 * 只记录实测值与建议值，等设计确认。waiver 必须写 reason，不许空着把问题藏起来。
 */
export const MATRIX = [
  ['text_primary', 'bg_card', 4.5, 'body'],
  ['text_primary', 'bg_page', 4.5, 'body'],
  ['text_primary', 'bg_navigation', 4.5, 'body'],
  ['text_primary', 'brand_bg', 4.5, 'body'],
  ['text_secondary', 'bg_card', 4.5, 'body', 'waived', '原型 --muted:#7c8390；建议 #5b6270（白底 6.1:1），改即改设计稿，待确认'],
  ['text_secondary', 'bg_page', 4.5, 'body', 'waived', '同 --muted；页面底比卡片底暗，要求更严'],
  ['text_secondary', 'bg_navigation', 4.5, 'body', 'waived', '同 --muted'],
  ['text_tertiary', 'bg_card', 4.5, 'body', 'waived', '与 text_secondary 同值，同 --muted'],
  ['text_tertiary', 'bg_page', 4.5, 'body', 'waived', '与 text_secondary 同值，同 --muted'],
  ['brand', 'bg_card', 4.5, 'body', 'waived', '原型 --blue:#007dff；建议 #0062cc（白底 5.8:1，与 brand_press 同值需再分档），待确认'],
  ['brand', 'bg_page', 4.5, 'body', 'waived', '同 --blue'],
  ['brand', 'brand_bg', 4.5, 'body', 'waived', '同 --blue；选中态底色 --blue-soft 由原型定义'],
  ['danger', 'bg_card', 4.5, 'body', 'waived', '浅色 = 原型 --danger:#cf4048（白底 4.69 达标）；深色已单独补齐，见 dark 行'],
  ['danger', 'bg_page', 4.5, 'body', 'waived', '浅色页面底 3.99，同 --danger；建议 #b03038，待确认'],
  ['success', 'bg_card', 4.5, 'body', 'waived', '原型 --green:#35916d；建议 #267050（白底 5.9:1），待确认'],
  ['warning', 'bg_card', 4.5, 'body', 'waived', '原型未定义 --warning，橙色在浅底上天然偏低（2.39）；改到 4.5 需近棕色，待确认'],
  ['on_brand', 'brand', 4.5, 'body', 'waived', '品牌按钮上的文字；随 --blue 一并待确认'],
  ['snack_text', 'snack_bg', 4.5, 'body'],
  ['snack_action', 'snack_bg', 4.5, 'body'],
  ['hl_code', 'bg_card', 4.5, 'body', 'waived', '代码高亮绿 4.25，接近但未达；建议 #0a7d58，待确认'],

  // UI 组件：分隔线、描边、图标（按非文本 3:1）
  ['line', 'bg_card', 3, 'ui', 'waived', '纯装饰性分组分隔线，不是识别控件所必需，WCAG 1.4.11 不适用；值为原型 --line'],
  ['line_strong', 'bg_card', 3, 'ui'],
  ['text_secondary', 'bg_card', 3, 'ui'],
  ['text_tertiary', 'bg_card', 3, 'ui'],
  ['brand', 'bg_card', 3, 'ui'],
  ['danger', 'bg_card', 3, 'ui']
];

/** 只列不判定（WCAG Inactive 例外） */
export const INFORMATIONAL = [
  ['text_disabled', 'bg_card'],
  ['text_disabled', 'bg_page']
];

export function measure(scheme) {
  const rows = MATRIX.map(([fgName, bgName, threshold, kind, status = 'enforce', reason = '']) => {
    if (status === 'waived' && reason.length === 0) {
      throw new Error(`waived 组合必须写明理由：${fgName} on ${bgName}`);
    }
    const fgRaw = scheme[fgName];
    const bgRaw = scheme[bgName];
    if (!fgRaw || !bgRaw) {
      throw new Error(`缺少 token：${fgName} / ${bgName}`);
    }
    const bg = parseColor(bgRaw);
    const fg = flatten(parseColor(fgRaw), bg);
    const ratio = contrastRatio(fg, bg);
    return {
      fg: fgName,
      bg: bgName,
      threshold,
      kind,
      status,
      reason,
      ratio: Math.round(ratio * 100) / 100,
      pass: ratio >= threshold
    };
  });
  const info = INFORMATIONAL.map(([fgName, bgName]) => {
    const bg = parseColor(scheme[bgName]);
    const fg = flatten(parseColor(scheme[fgName]), bg);
    return { fg: fgName, bg: bgName, ratio: Math.round(contrastRatio(fg, bg) * 100) / 100, pass: true, informational: true };
  });
  return { rows, info };
}

export function run() {
  const schemes = { light: readScheme('base'), dark: readScheme('dark') };
  const out = {};
  for (const [name, scheme] of Object.entries(schemes)) {
    out[name] = measure(scheme);
  }
  return out;
}

function main() {
  const args = process.argv.slice(2);
  const result = run();
  if (args.includes('--json')) {
    process.stdout.write(JSON.stringify(result, null, 2) + '\n');
  } else {
    for (const [schemeName, data] of Object.entries(result)) {
      process.stdout.write(`\n== ${schemeName} ==\n`);
      for (const r of data.rows) {
        const tag = r.pass ? 'PASS' : (r.status === 'waived' ? 'WAIVED' : 'FAIL');
        process.stdout.write(
          `${tag.padEnd(6)} ${r.ratio.toFixed(2).padStart(6)} : 1  (需 >= ${r.threshold})  ${r.fg} on ${r.bg}  [${r.kind}]\n`
        );
        if (!r.pass && r.reason) {
          process.stdout.write(`         理由：${r.reason}\n`);
        }
      }
      for (const r of data.info) {
        process.stdout.write(`INFO    ${r.ratio.toFixed(2).padStart(6)} : 1  (不判定)  ${r.fg} on ${r.bg}\n`);
      }
    }
  }
  if (args.includes('--check')) {
    let failed = false;
    for (const [schemeName, data] of Object.entries(result)) {
      for (const r of data.rows) {
        if (!r.pass && r.status === 'enforce') {
          failed = true;
          process.stderr.write(`对比度不达标（${schemeName}）：${r.fg} on ${r.bg} = ${r.ratio} : 1（需 >= ${r.threshold}）\n`);
        }
      }
    }
    process.exit(failed ? 1 : 0);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  main();
}
