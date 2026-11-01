import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

const indexSource = readSourceFile(new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url));
const settingsSource = readSourceFile(new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url));

test('single-screen settings details have one back control and it returns to categories', () => {
  assert.doesNotMatch(settingsSource, /showCategoryBack|onBackToCategories|← 设置分类/);
  assert.match(indexSource,
    /if \(this\.isSingleScreenLayout\(\) && this\.settingsDetail && this\.settingsReturnView !== 'agent'\) \{\s*this\.settingsDetail = false;/);
  assert.match(indexSource,
    /if \(this\.topView === 'settings'\) \{\s*if \(this\.isSingleScreenLayout\(\) && this\.settingsDetail/);
});
