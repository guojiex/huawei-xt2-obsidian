import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readSourceFile } from './lib/source.mjs';

const settingsSource = readSourceFile(
  new URL('../../entry/src/main/ets/components/SettingsView.ets', import.meta.url)
);
const indexSource = readSourceFile(
  new URL('../../entry/src/main/ets/pages/Index.ets', import.meta.url)
);
const policySource = readSourceFile(
  new URL('../../entry/src/main/ets/components/PrivacyPolicyView.ets', import.meta.url)
);

test('About exposes the official policy and opens the in-app policy view', () => {
  const aboutTabStart = settingsSource.indexOf('  AboutTab() {');
  const aboutTabEnd = settingsSource.indexOf('\n  @Builder', aboutTabStart);
  assert.ok(aboutTabStart >= 0 && aboutTabEnd > aboutTabStart, 'could not find AboutTab');
  const aboutTab = settingsSource.slice(aboutTabStart, aboutTabEnd);

  assert.match(aboutTab, /Text\('隐私政策'\)/);
  assert.match(aboutTab, /\.accessibilityText\('查看隐私政策'\)/);
  assert.match(aboutTab, /\.onClick\(\(\): void => \{ this\.onOpenPrivacyPolicy\(\); \}\)/);
  assert.match(policySource,
    /https:\/\/agreement-drcn\.hispace\.dbankcloud\.cn\/index\.html\?lang=zh&agreementId=2064689818977197760/);
  assert.match(settingsSource, /if \(this\.showPrivacyPolicy\) \{\s*PrivacyPolicyView\(\{ onClose: this\.onClosePrivacyPolicy \}\)/);
  assert.match(indexSource, /showPrivacyPolicy: this\.settingsPrivacyPolicyOpen/);
  assert.match(indexSource, /onOpenPrivacyPolicy: \(\): void => \{ this\.settingsPrivacyPolicyOpen = true; \}/);
});

test('policy back controls close the policy before leaving Settings', () => {
  assert.match(indexSource,
    /if \(this\.settingsPrivacyPolicyOpen\) \{\s*this\.settingsPrivacyPolicyOpen = false;\s*return;\s*\}\s*if \(this\.isSingleScreenLayout\(\) && this\.settingsDetail\)/);
  assert.match(indexSource,
    /if \(this\.settingsPrivacyPolicyOpen\) \{\s*this\.settingsPrivacyPolicyOpen = false;\s*\} else if \(this\.isSingleScreenLayout\(\) && this\.settingsDetail/);
  assert.match(policySource, /\.accessibilityText\('返回关于'\)[\s\S]*?this\.onClose\(\)/);
});

test('failed policy loads display a retry action and cancel untrusted SSL requests', () => {
  assert.match(policySource, /\.onErrorReceive\(\(event\) => \{[\s\S]*?event\.request\.isMainFrame\(\)[\s\S]*?this\.loadStatus = 'failed'/);
  assert.match(policySource, /\.onHttpErrorReceive\(\(event\) => \{[\s\S]*?event\.request\.isMainFrame\(\)[\s\S]*?this\.loadStatus = 'failed'/);
  assert.match(policySource, /\.onSslErrorEventReceive\(\(event\) => \{[\s\S]*?event\.handler\.handleCancel\(\)[\s\S]*?this\.loadStatus = 'failed'/);
  assert.match(policySource, /this\.loadStatus === 'failed' \? '暂时无法加载隐私政策' : '正在加载隐私政策/);
  assert.match(policySource, /Text\('重试 ›'\)[\s\S]*?this\.retryLoading\(\)/);
  assert.match(policySource, /private retryLoading\(\): void \{\s*this\.loadStatus = 'loading';\s*try \{\s*this\.controller\.loadUrl\(PRIVACY_POLICY_URL\)/);
});
