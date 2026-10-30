import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(new URL('../web/mdpreview/package.json', import.meta.url));
const { transformSync } = require('esbuild');
const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/Index.ets', import.meta.url), 'utf8');
const start = source.indexOf('  private updateFormatPopupLayout(pane: string): void {');
const end = source.indexOf('\n  private applyEditorFormat(', start);
assert.ok(start >= 0 && end > start, 'could not find Index.updateFormatPopupLayout');

const code = transformSync(`class FormatPopupHarness { ${source.slice(start, end).trim()} }; module.exports = FormatPopupHarness;`, {
  loader: 'ts',
  format: 'cjs'
}).code;
const context = vm.createContext({
  module: { exports: {} },
  Breakpoint: { SM: 'sm' },
  Placement: { TopLeft: 'top-left', BottomLeft: 'bottom-left' },
  Size: { formatMenuW: 360, touch: 48 },
  Space: { s2: 8, s6: 24 }
});
vm.runInContext(code, context);

function layout(options) {
  const app = new context.module.exports();
  Object.assign(app, {
    formatMenuOpen: true,
    formatMenuPane: options.pane,
    topView: 'note',
    activePane: options.pane,
    currentVaultId: 'local',
    formatMenuSourceVaultId: 'local',
    formatMenuSourcePath: 'note.md',
    breakpoint: options.breakpoint ?? 'lg',
    focused: false,
    formatWindowArea: options.windowArea,
    leftFormatPaneArea: options.leftPaneArea,
    rightFormatPaneArea: options.rightPaneArea ?? [0, 0, 0, 0],
    leftFormatAnchorArea: options.leftAnchorArea,
    rightFormatAnchorArea: options.rightAnchorArea ?? [0, 0, 0, 0],
    formatMenuWidth: 360,
    formatMenuMaxHeight: 500,
    paneFilePath: () => 'note.md',
    isPaneEditable: () => true,
    isReferenceShown: () => true,
    keyboardInsetVp: () => options.keyboardInsetVp ?? 0,
    closeFormatMenu() { this.formatMenuOpen = false; }
  });
  app.updateFormatPopupLayout(options.pane);
  return app;
}

test('a single-screen popup does not apply the anchor shift twice after window clamping', () => {
  const app = layout({
    pane: 'left',
    breakpoint: 'sm',
    leftPaneArea: [0, 95, 350.61, 625.57],
    leftAnchorArea: [55.3, 338.87, 48, 48],
    windowArea: [0, 39, 350.61, 737.39],
    keyboardInsetVp: 297
  });

  assert.equal(app.formatMenuWidth, 334.61);
  assert.equal(app.formatPopupOffsetX, 0);
  assert.equal(app.formatMenuOpen, true);
});

test('a wide-window popup keeps the left pane offset when the window does not clamp its anchor', () => {
  const app = layout({
    pane: 'left',
    leftPaneArea: [0, 95, 379, 650],
    leftAnchorArea: [55, 338, 48, 48],
    windowArea: [0, 39, 1107, 737]
  });

  assert.equal(app.formatMenuWidth, 360);
  assert.equal(app.formatPopupOffsetX, -47);
  assert.equal(app.formatMenuOpen, true);
});

test('a right-pane popup offset is measured from its right-aligned placement and window clamp', () => {
  const app = layout({
    pane: 'right',
    rightPaneArea: [728, 95, 379, 650],
    rightAnchorArea: [783, 338, 48, 48],
    windowArea: [0, 39, 1107, 737]
  });

  assert.equal(app.formatMenuWidth, 360);
  assert.equal(app.formatPopupOffsetX, -3);
  assert.equal(app.formatMenuOpen, true);
});
