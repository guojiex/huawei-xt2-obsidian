// 生成 DevEco/hvigor 能解密的签名密码密文（hex）。
//
// 用法（用 DevEco 自带的 node，别的版本没验过）：
//   $node = 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe'
//   & $node tools\encode_signing_pwd.mjs <material目录> <明文密码>
// 例（发布签名）：
//   & $node tools\encode_signing_pwd.mjs .local\release-signing\material (Get-Content .local\release-signing\keystore.pass.txt)
// 输出的 enc 填进 .local/<xx>-signing.json 的 storePassword / keyPassword。
// 脚本自带「加密→解密回验」，回验不过会直接退出码 1。
//
// 为什么需要它：hvigor 的 HapSignCommandBuilder.getKeyStorePwd() 会**无条件**调用
//   DecipherUtil.decryptPwd(path.resolve(material.storeFile,'..'), material.storePassword, …)
// 把密码当 hex 密文做 AES-128-GCM 解密，密钥来自 dirname(storeFile)/material（fd/ac/ce）。
// 所以 signingConfig 里只能填密文，明文会直接 00308018 ENOENT …/material。
//
// 算法完全照 DevEco 的 decipher-util.js 复刻（已逐行核对，非凭记忆）：
//   fd(3×16B) + component(16B) 依次 XOR → 16B
//   rootKey = pbkdf2(xor.toString(), salt=ac, 10000, 16, sha256)
//   key     = AES-128-GCM(rootKey).decrypt(ce)
//   密文格式 = uint32BE(len(ct)+16) || iv || ct || tag(16)
// 注意：密钥只依赖 material 文件内容，与密码、第三参数无关（第三参数仅用于报错文案）。

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const COMPONENT = Int8Array.from([49, 243, 9, 115, 214, 175, 91, 184, 211, 190, 177, 88, 101, 131, 192, 119]);

function readDirBytes(dir) {
  const list = fs.readdirSync(dir);
  if (list.length !== 1) throw new Error(`目录内文件数必须为 1：${dir}（${list.length}）`);
  return new Int8Array(fs.readFileSync(path.resolve(dir, list[0])));
}

function readFd(matDir) {
  const d = path.resolve(matDir, 'fd');
  const sub = fs.readdirSync(d);
  if (sub.length !== 3) throw new Error(`fd 下必须有 3 项：${d}（${sub.length}）`);
  return sub.map((x) => readDirBytes(path.resolve(d, x)));
}

function xor(a, b) {
  if (a.length !== b.length) throw new Error('XOR 长度不等');
  const o = new Int8Array(a.length);
  for (let i = 0; i < a.length; i++) o[i] = a[i] ^ b[i];
  return o;
}

function xorComponents(items) {
  items.forEach((x) => { if (x.length !== 16) throw new Error('material 段必须是 16 字节'); });
  let e = xor(items[0], items[1]);
  for (let i = 2; i < items.length; i++) e = xor(e, items[i]);
  return Buffer.from(e);
}

function aesGcmDecrypt(key, buf) {
  const r = Buffer.from(buf);
  const encLen = (255 & r[0]) << 24 | (255 & r[1]) << 16 | (255 & r[2]) << 8 | 255 & r[3];
  const ivLen = r.length - 4 - encLen;
  const iv = r.slice(4, 4 + ivLen);
  const tag = r.slice(r.length - 16);
  const d = crypto.createDecipheriv('aes-128-gcm', Buffer.from(key), iv);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(r.subarray(4 + ivLen, r.length - 16)), d.final()]);
}

function getKey(matDir) {
  const fd = readFd(matDir);
  const salt = readDirBytes(path.resolve(matDir, 'ac'));
  const rootKey = new Int8Array(
    crypto.pbkdf2Sync(xorComponents([...fd, COMPONENT]).toString(), Buffer.from(salt), 10000, 16, 'sha256')
  );
  const work = readDirBytes(path.resolve(matDir, 'ce'));
  return new Int8Array(aesGcmDecrypt(rootKey, work));
}

function encryptPwd(matDir, plain) {
  const key = Buffer.from(getKey(matDir));
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-128-gcm', key, iv);
  const ct = Buffer.concat([c.update(plain, 'utf8'), c.final()]);
  const tag = c.getAuthTag();
  const header = Buffer.alloc(4);
  header.writeUInt32BE(ct.length + 16);
  return Buffer.concat([header, iv, ct, tag]).toString('hex');
}

const matDir = process.argv[2];
const plain = process.argv[3];
const enc = encryptPwd(matDir, plain);

// 自回验：用同一套 material 解回明文
const back = aesGcmDecrypt(getKey(matDir), new Int8Array(Buffer.from(enc, 'hex'))).toString('utf-8');
if (back !== plain) {
  console.error(`回验失败：${back} !== ${plain}`);
  process.exit(1);
}
console.log(JSON.stringify({ len: enc.length, even: enc.length % 2 === 0, roundtrip: true, enc }, null, 2));
