import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const source = fs.readFileSync(new URL('../../entry/src/main/ets/pages/SyncPage.ets', import.meta.url), 'utf8');
const buildStart = source.indexOf('  build() {');
assert.notEqual(buildStart, -1, 'SyncPage build method is present');
const buildSource = source.slice(buildStart);

test('SyncPage fixed typography and spacing use shared tokens', () => {
  assert.doesNotMatch(buildSource, /\.fontSize\(\s*\d+(?:\.\d+)?\s*\)/);
  assert.doesNotMatch(buildSource, /\.padding\(\s*\d+(?:\.\d+)?\s*\)/);
  assert.doesNotMatch(buildSource,
    /\.margin\(\s*\{[^}]*\b(?:top|right|bottom|left)\s*:\s*\d+(?:\.\d+)?\b/);
  assert.doesNotMatch(buildSource, /\bspace\s*:\s*\d+(?:\.\d+)?\b/);
});

test('SyncPage uses the repository font and spacing token modules', () => {
  assert.match(source, /import\s*\{\s*FontSize\s*,\s*Space\s*\}\s*from\s*'\.\.\/common\/Tokens';/);
  assert.match(buildSource, /\.fontSize\(FontSize\.(?:body1|caption|s2)\)/);
  assert.match(buildSource, /\.padding\(Space\.s4\)/);
  assert.match(buildSource, /\.margin\(\{\s*bottom:\s*Space\.s[234]\s*\}\)/);
});
