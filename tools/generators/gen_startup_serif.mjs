#!/usr/bin/env node
/**
 * gen_startup_serif.mjs —— 生成启动页衬线字体子集（v1.63 / v1.64）
 *
 * 真源：docs/prototype/v2/index.html `.startup-mask --serif`（Songti SC / STSong /
 * Noto Serif SC / Source Han Serif / SimSun）。HarmonyOS 系统只预装 HarmonyOS Sans，
 * `fontFamily('serif')` 会回退黑体，故按启动页实际字符集裁剪一份 Noto Serif SC
 * （SIL OFL 1.1，授权文本见同目录 OFL.txt）并注册为自定义字体。
 *
 * 前置：npm install --no-save subset-font   （在本脚本所在目录或任一可解析 node_modules 的目录执行）
 * 源字体：默认取本机 Windows 预装的 NotoSerifSC-VF.ttf；也可用 --src 指向官方同版
 *   https://github.com/google/fonts/raw/main/ofl/notoserifsc/NotoSerifSC%5Bwght%5D.ttf
 * 产物：entry/src/main/resources/rawfile/fonts/StartupSerif-Regular.ttf   (wght=400)
 *       entry/src/main/resources/rawfile/fonts/StartupSerif-Semibold.ttf  (wght=600)
 *
 * 字符集来自 StartupMask.ets 的 QUOTES 常量 + 品牌名 / 页脚中文数字 / 标点 / 大引号。
 * ⚠️ 名言库增删或改字后必须重跑本脚本，否则新字会回退系统黑体。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '../..');
const OUT_DIR = path.join(ROOT, 'entry/src/main/resources/rawfile/fonts');
const MASK = path.join(ROOT, 'entry/src/main/ets/components/StartupMask.ets');
const DEFAULT_SRC = 'C:/Windows/Fonts/NotoSerifSC-VF.ttf';
const OFFICIAL_SRC_URL =
  'https://github.com/google/fonts/raw/main/ofl/notoserifsc/NotoSerifSC%5Bwght%5D.ttf';

const FIXED_CHARS =
  '曜石笔记〇一二三四五六七八九十年月日星期·“”‘’，。；？！、《》()—－ ' +
  '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

/** 解析 SFNT 表目录。 */
function readTables(buf) {
  const count = buf.readUInt16BE(4);
  const tableMap = new Map();
  for (let i = 0; i < count; i++) {
    const o = 12 + 16 * i;
    tableMap.set(buf.toString('ascii', o, o + 4), {
      offset: buf.readUInt32BE(o + 8),
      length: buf.readUInt32BE(o + 12)
    });
  }
  return tableMap;
}

/** 收集 cmap 覆盖的码点区间（format 4 / 12），用于校验子集不缺字。 */
function readCmapRanges(buf) {
  const tableMap = readTables(buf);
  const cmap = tableMap.get('cmap');
  if (!cmap) {
    throw new Error('subset font has no cmap table');
  }
  const ranges = [];
  const numSubtables = buf.readUInt16BE(cmap.offset + 2);
  for (let i = 0; i < numSubtables; i++) {
    const rec = cmap.offset + 4 + 8 * i;
    const sub = cmap.offset + buf.readUInt32BE(rec + 4);
    const format = buf.readUInt16BE(sub);
    if (format === 4) {
      const segCount = buf.readUInt16BE(sub + 6) / 2;
      const endAt = sub + 14;
      const startAt = endAt + segCount * 2 + 2;
      for (let s = 0; s < segCount; s++) {
        const start = buf.readUInt16BE(startAt + s * 2);
        const end = buf.readUInt16BE(endAt + s * 2);
        if (start <= end && end !== 0xFFFF) {
          ranges.push([start, end]);
        }
      }
    } else if (format === 12) {
      const groups = buf.readUInt32BE(sub + 12);
      for (let g = 0; g < groups; g++) {
        const at = sub + 16 + g * 12;
        ranges.push([buf.readUInt32BE(at), buf.readUInt32BE(at + 4)]);
      }
    }
  }
  return ranges;
}


/** SFNT 校验和（4 字节对齐的 uint32 求和）。 */
function tableChecksum(data) {
  const padded = data.length % 4 === 0 ? data : Buffer.concat([data, Buffer.alloc(4 - (data.length % 4))]);
  let sum = 0;
  for (let i = 0; i < padded.length; i += 4) {
    sum = (sum + padded.readUInt32BE(i)) >>> 0;
  }
  return sum >>> 0;
}

function readEntries(buf) {
  const count = buf.readUInt16BE(4);
  const entries = [];
  for (let i = 0; i < count; i++) {
    const o = 12 + 16 * i;
    entries.push({
      tag: buf.toString('ascii', o, o + 4),
      offset: buf.readUInt32BE(o + 8),
      length: buf.readUInt32BE(o + 12)
    });
  }
  return entries;
}

/**
 * 改写内部 name 表与 OS/2 字重。源 VF 的 name 表写着 "Noto Serif SC / ExtraLight"，
 * 两档子集同名会让 fontWeight 匹配歧义；改名后也明确这是 OFL 修改版子集。
 * 版权 (0)、版本 (5)、授权说明 (13) 与授权链接 (14) 原样保留，符合 OFL 再分发要求。
 */
function renameFont(srcBuf, spec) {
  const entries = readEntries(srcBuf);
  const data = new Map();
  for (const e of entries) {
    data.set(e.tag, Buffer.from(srcBuf.subarray(e.offset, e.offset + e.length)));
  }

  const nameBuf = data.get('name');
  const count = nameBuf.readUInt16BE(2);
  const strOff = nameBuf.readUInt16BE(4);
  const recs = [];
  for (let i = 0; i < count; i++) {
    const r = 6 + 12 * i;
    const len = nameBuf.readUInt16BE(r + 8);
    const off = nameBuf.readUInt16BE(r + 10);
    const rec = {
      platformID: nameBuf.readUInt16BE(r),
      encodingID: nameBuf.readUInt16BE(r + 2),
      languageID: nameBuf.readUInt16BE(r + 4),
      nameID: nameBuf.readUInt16BE(r + 6),
      raw: Buffer.from(nameBuf.subarray(strOff + off, strOff + off + len))
    };
    const replacement = spec.names[rec.nameID];
    if (replacement !== undefined) {
      rec.raw = (rec.platformID === 3 || rec.platformID === 0)
        ? Buffer.from(replacement, 'utf16le').swap16()
        : Buffer.from(replacement, 'latin1');
    }
    recs.push(rec);
  }
  const headBuf = Buffer.alloc(6);
  headBuf.writeUInt16BE(0, 0);
  headBuf.writeUInt16BE(recs.length, 2);
  headBuf.writeUInt16BE(6 + 12 * recs.length, 4);
  const recBuf = Buffer.alloc(12 * recs.length);
  const strings = [];
  let cursor = 0;
  recs.forEach((rec, i) => {
    const o = 12 * i;
    recBuf.writeUInt16BE(rec.platformID, o);
    recBuf.writeUInt16BE(rec.encodingID, o + 2);
    recBuf.writeUInt16BE(rec.languageID, o + 4);
    recBuf.writeUInt16BE(rec.nameID, o + 6);
    recBuf.writeUInt16BE(rec.raw.length, o + 8);
    recBuf.writeUInt16BE(cursor, o + 10);
    strings.push(rec.raw);
    cursor += rec.raw.length;
  });
  data.set('name', Buffer.concat([headBuf, recBuf, ...strings]));

  const os2 = data.get('OS/2');
  if (os2 !== undefined && os2.length >= 6) {
    os2.writeUInt16BE(spec.weight, 4); // usWeightClass
  }
  const head = data.get('head');
  head.writeUInt32BE(0, 8); // checkSumAdjustment 先清零，最后按整文件重算

  const entrySelector = Math.floor(Math.log2(entries.length));
  const searchRange = (2 ** entrySelector) * 16;
  const dir = Buffer.alloc(12 + 16 * entries.length);
  dir.writeUInt32BE(srcBuf.readUInt32BE(0), 0);
  dir.writeUInt16BE(entries.length, 4);
  dir.writeUInt16BE(searchRange, 6);
  dir.writeUInt16BE(entrySelector, 8);
  dir.writeUInt16BE(entries.length * 16 - searchRange, 10);
  const chunks = [];
  let offset = dir.length;
  let headOffset = 0;
  entries.forEach((e, i) => {
    const body = data.get(e.tag);
    const o = 12 + 16 * i;
    dir.write(e.tag, o, 4, 'ascii');
    dir.writeUInt32BE(tableChecksum(body), o + 4);
    dir.writeUInt32BE(offset, o + 8);
    dir.writeUInt32BE(body.length, o + 12);
    if (e.tag === 'head') {
      headOffset = offset;
    }
    chunks.push(body);
    const pad = (4 - (body.length % 4)) % 4;
    if (pad > 0) {
      chunks.push(Buffer.alloc(pad));
    }
    offset += body.length + pad;
  });
  const out = Buffer.concat([dir, ...chunks]);
  out.writeUInt32BE((0xB1B0AFBA - tableChecksum(out)) >>> 0, headOffset + 8);
  return out;
}

function verify(buf, chars, spec) {
  const tableMap = readTables(buf);
  for (const tag of ['cmap', 'glyf', 'head', 'hhea', 'hmtx', 'loca', 'maxp', 'name', 'OS/2', 'post']) {
    if (!tableMap.has(tag)) {
      throw new Error(`${spec.family}: missing table ${tag}`);
    }
  }
  if (tableMap.has('fvar')) {
    throw new Error(`${spec.family}: variable axes were not pinned to a static instance`);
  }
  const ranges = readCmapRanges(buf);
  const missing = [...chars].filter((ch) => {
    const code = ch.codePointAt(0);
    return !ranges.some(([lo, hi]) => code >= lo && code <= hi);
  });
  if (missing.length > 0) {
    throw new Error(`${spec.family}: missing glyphs for ${missing.join('')}`);
  }
  const nameE = tableMap.get('name');
  const nameCount = buf.readUInt16BE(nameE.offset + 2);
  const nameStrOff = buf.readUInt16BE(nameE.offset + 4);
  let family = '';
  let hasCopyright = false;
  let hasLicense = false;
  for (let i = 0; i < nameCount; i++) {
    const r = nameE.offset + 6 + 12 * i;
    const platformID = buf.readUInt16BE(r);
    const nameID = buf.readUInt16BE(r + 6);
    const len = buf.readUInt16BE(r + 8);
    const off = buf.readUInt16BE(r + 10);
    const raw = Buffer.from(buf.subarray(nameE.offset + nameStrOff + off,
      nameE.offset + nameStrOff + off + len));
    if (nameID === 0 && platformID === 3) {
      hasCopyright = raw.swap16().toString('utf16le').includes('Adobe');
    }
    if (nameID === 13 && platformID === 3) {
      hasLicense = raw.swap16().toString('utf16le').includes('Open Font License');
    }
    if (nameID === 1 && (platformID === 3 || platformID === 0)) {
      family = raw.swap16().toString('utf16le');
    }
  }
  if (family !== spec.family) {
    throw new Error(`${spec.family}: internal family name is "${family}"`);
  }
  if (!hasCopyright || !hasLicense) {
    throw new Error(`${spec.family}: OFL copyright/license name records were dropped`);
  }
  if (buf.readUInt16BE(tableMap.get('OS/2').offset + 4) !== spec.weight) {
    throw new Error(`${spec.family}: OS/2 usWeightClass mismatch`);
  }
  console.log(`${spec.family}: ${(buf.length / 1024).toFixed(1)} KB, ${chars.length} chars, ` +
    `wght=${spec.weight}, static sfnt, OFL notice kept`);
}

async function main() {
  let subsetFont;
  try {
    subsetFont = (await import('subset-font')).default;
  } catch {
    console.error('缺少依赖：请先执行 npm install --no-save subset-font');
    process.exit(1);
  }
  const srcArg = process.argv.indexOf('--src');
  const srcPath = srcArg >= 0 ? process.argv[srcArg + 1] : DEFAULT_SRC;
  if (!fs.existsSync(srcPath)) {
    console.error(`找不到源字体 ${srcPath}\n官方同版下载地址：${OFFICIAL_SRC_URL}`);
    process.exit(1);
  }
  const maskSrc = fs.readFileSync(MASK, 'utf8');
  const quotes = [...maskSrc.matchAll(/\{ text: '([^']+)', source: '([^']+)' \}/g)];
  if (quotes.length !== 12) {
    throw new Error(`名言库解析异常：期望 12 句，实际 ${quotes.length} 句`);
  }
  const chars = [...new Set([...(quotes.map((m) => m[1] + m[2]).join('') + FIXED_CHARS)])].join('');
  const source = fs.readFileSync(srcPath);
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const specs = [
    { weight: 400, label: 'Regular', family: 'StartupSerif', subfamily: 'Regular' },
    { weight: 600, label: 'Semibold', family: 'StartupSerifSemibold', subfamily: 'SemiBold' }
  ];
  for (const s of specs) {
    const out = await subsetFont(source, chars, {
      targetFormat: 'sfnt',
      variationAxes: { wght: s.weight },
      preserveNameIds: [0, 1, 2, 3, 4, 5, 6, 13, 14, 16, 17]
    });
    const spec = {
      weight: s.weight,
      family: s.family,
      names: {
        1: s.family,
        2: s.subfamily,
        3: `1.000;XT2;${s.family}`,
        4: s.family,
        6: `${s.family}-${s.subfamily}`,
        16: s.family,
        17: s.subfamily
      }
    };
    const buf = renameFont(Buffer.from(out), spec);
    verify(buf, chars, spec);
    fs.writeFileSync(path.join(OUT_DIR, `StartupSerif-${s.label}.ttf`), buf);
  }
  console.log(`输出目录：${OUT_DIR}`);
}

await main();
