import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const prototypeHtml = fs.readFileSync(path.join(root, 'docs/prototype/v2/index.html'), 'utf8')
const tokenBlock = prototypeHtml.match(/:root\{[^\r\n]*\}\s*\[data-theme=dark\]\{[^\r\n]*\}/)?.[0]
assert.ok(tokenBlock, 'v2 light and dark token blocks must remain available')

function cssVariables(block, selector) {
  const rule = selector === ':root'
    ? block.match(/:root\{([^}]*)\}/)?.[1]
    : block.match(/\[data-theme=dark\]\{([^}]*)\}/)?.[1]
  assert.ok(rule, `Missing ${selector} rule`)
  return Object.fromEntries([...rule.matchAll(/(--[\w-]+):([^;]+);?/g)].map(([, key, value]) => [key, value.trim()]))
}

function colorsFromResource(relativePath) {
  const resource = JSON.parse(fs.readFileSync(path.join(root, relativePath), 'utf8'))
  return Object.fromEntries(resource.color.map(({ name, value }) => {
    const digits = value.slice(1).toUpperCase()
    return [name, digits.length === 6 ? `#FF${digits}` : `#${digits}`]
  }))
}

function cssHexToHarmonyArgb(hex) {
  const digits = hex.slice(1)
  if (digits.length === 3 || digits.length === 4) {
    const expanded = [...digits].map((digit) => digit + digit).join('')
    return digits.length === 3
      ? `#FF${expanded.toUpperCase()}`
      : `#${expanded.slice(6).toUpperCase()}${expanded.slice(0, 6).toUpperCase()}`
  }
  assert.ok(digits.length === 6 || digits.length === 8, `Unsupported CSS color ${hex}`)
  return digits.length === 6
    ? `#FF${digits.toUpperCase()}`
    : `#${digits.slice(6).toUpperCase()}${digits.slice(0, 6).toUpperCase()}`
}

function numericToken(source, tokenName) {
  if (tokenName === 'LINE_HEIGHT_BODY') {
    const match = source.match(/export const LINE_HEIGHT_BODY: number = ([\d.]+)/)
    assert.ok(match, 'Missing numeric token LINE_HEIGHT_BODY')
    return Number(match[1])
  }
  const [className, key] = tokenName.split('.')
  const scope = source.match(new RegExp(`export class ${className}\\s*\\{([\\s\\S]*?)\\n\\}`))?.[1]
  const match = scope?.match(new RegExp(`static readonly ${key}: number = ([\\d.]+)`))
  assert.ok(match, `Missing numeric token ${tokenName}`)
  return Number(match[1])
}

function cssNumber(variables, key) {
  const match = variables[key]?.match(/^[\d.]+/)
  assert.ok(match, `Missing numeric CSS token ${key}`)
  return Number(match[0])
}

test('editor and preview bundles embed the exact v2 light and dark token blocks', () => {
  for (const relativePath of [
    'web/mdeditor/build.mjs',
    'web/mdpreview/build.mjs'
  ]) {
    const source = fs.readFileSync(path.join(root, relativePath), 'utf8')
    assert.ok(source.includes('docs/prototype/v2/index.html'), relativePath)
    assert.ok(source.includes('Unable to read shared v2 tokens'), relativePath)
  }

  for (const relativePath of [
    'entry/src/main/resources/rawfile/mdeditor/index.html',
    'entry/src/main/resources/rawfile/mdpreview/index.html'
  ]) {
    const generatedHtml = fs.readFileSync(path.join(root, relativePath), 'utf8')
    assert.ok(generatedHtml.includes(tokenBlock), `${relativePath} is stale`)
  }
})

test('native theme colors and ArkTS numeric tokens match v2 mappings', () => {
  const light = cssVariables(tokenBlock, ':root')
  const dark = { ...light, ...cssVariables(tokenBlock, '[data-theme=dark]') }
  const baseColors = colorsFromResource('entry/src/main/resources/base/element/color.json')
  const darkColors = colorsFromResource('entry/src/main/resources/dark/element/color.json')

  const colorMappings = [
    [baseColors, light, 'brand', '--blue'],
    [baseColors, light, 'brand_bg', '--blue-soft'],
    [baseColors, light, 'on_brand', '--paper'],
    [baseColors, light, 'success', '--green'],
    [baseColors, light, 'danger', '--danger'],
    [baseColors, light, 'start_window_background', '--outer'],
    [baseColors, light, 'bg_page', '--outer'],
    [baseColors, light, 'bg_navigation', '--nav'],
    [baseColors, light, 'bg_card', '--paper'],
    [baseColors, light, 'bg_secondary', '--nav'],
    [baseColors, light, 'line', '--line'],
    [baseColors, light, 'text_primary', '--ink'],
    [baseColors, light, 'text_secondary', '--muted'],
    [baseColors, light, 'text_tertiary', '--muted'],
    [baseColors, light, 'float_shadow', '--float-shadow'],
    [baseColors, light, 'mask', '--scrim'],
    [darkColors, dark, 'brand', '--blue'],
    [darkColors, dark, 'brand_bg', '--blue-soft'],
    [darkColors, dark, 'on_brand', '--paper'],
    [darkColors, dark, 'success', '--green'],
    [darkColors, dark, 'danger', '--danger'],
    [darkColors, dark, 'start_window_background', '--outer'],
    [darkColors, dark, 'bg_page', '--outer'],
    [darkColors, dark, 'bg_navigation', '--nav'],
    [darkColors, dark, 'bg_card', '--paper'],
    [darkColors, dark, 'bg_secondary', '--nav'],
    [darkColors, dark, 'line', '--line'],
    [darkColors, dark, 'text_primary', '--ink'],
    [darkColors, dark, 'text_secondary', '--muted'],
    [darkColors, dark, 'text_tertiary', '--muted'],
    [darkColors, dark, 'float_shadow', '--float-shadow'],
    [darkColors, dark, 'mask', '--scrim']
  ]

  for (const [resource, variables, colorName, cssName] of colorMappings) {
    const cssValue = variables[cssName].match(/#[\da-fA-F]{3,8}$/)?.[0] ?? variables[cssName]
    const expected = cssHexToHarmonyArgb(cssValue)
    assert.equal(resource[colorName], expected, `${colorName} should match ${cssName}`)
  }

  const tokens = fs.readFileSync(path.join(root, 'entry/src/main/ets/common/Tokens.ets'), 'utf8')
  const numericMappings = [
    ['Space.s1', 's1'], ['Space.s2', 's2'], ['Space.s3', 's3'], ['Space.s4', 's4'],
    ['Space.s5', 's5'], ['Space.s6', 's6'], ['Space.s8', 's8'], ['Space.s10', 's10'],
    ['Space.s12', 's12'], ['Space.s16', 's16'],
    ['Radius.icon', 'small-r'], ['Radius.control', 'small-r'], ['Radius.card', 'r'],
    ['Radius.menu', 'r'], ['Radius.full', 'pill'],
    ['FontSize.caption', 'caption'], ['FontSize.body2', 'small'], ['FontSize.body1', 'body'],
    ['FontSize.s2', 'large'], ['FontSize.s3', 'large'],
    ['Size.paneHeadH', 's12'], ['Size.itemH', 'touch'], ['Size.buttonH', 'touch'],
    ['Size.sidebarW', 'nav-width'], ['Size.drawerW', 'mobile-nav-width'], ['Size.paneMinW', 'pane-min'],
    ['Size.formatMenuW', 'format-width'],
    ['Size.touch', 'touch'], ['Size.treeIndent', 'tree-indent'], ['Size.swipeDelExtra', 'swipe-extra'],
    ['Motion.durBase', 'ease']
  ]
  for (const [tokenName, cssName] of numericMappings) {
    const expected = cssNumber(light, `--${cssName}`)
    assert.equal(numericToken(tokens, tokenName), expected, `${tokenName} should match --${cssName}`)
  }
  // These tokens size the browser prototype frame and search result list; they
  // no longer describe the native Aa panel, which follows its anchor geometry.
  assert.equal(cssNumber(light, '--phone-width'), 390)
  assert.equal(cssNumber(light, '--panel-height'), 80)
  assert.equal(numericToken(tokens, 'LINE_HEIGHT_BODY'), cssNumber(light, '--leading'))
})
