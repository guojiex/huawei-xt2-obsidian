import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/model/Breakpoint.ets', import.meta.url), 'utf8');
const code = transformSync(source, { loader: 'ts', format: 'cjs' }).code;
const module = { exports: {} };
vm.runInContext(code, vm.createContext({ module, exports: module.exports }));
const { Breakpoint, breakpointFromWidthVp } = module.exports;

test('599.999vp remains in the compact breakpoint', () => {
  assert.equal(breakpointFromWidthVp(599.999), Breakpoint.SM);
});

test('600vp enters the middle breakpoint', () => {
  assert.equal(breakpointFromWidthVp(600), Breakpoint.MD);
});

test('839.999vp remains in the middle breakpoint', () => {
  assert.equal(breakpointFromWidthVp(839.999), Breakpoint.MD);
});

test('840vp enters the wide breakpoint', () => {
  assert.equal(breakpointFromWidthVp(840), Breakpoint.LG);
});
