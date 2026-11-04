export const COMMON_CODE_LANGUAGES = [
  '', 'javascript', 'typescript', 'python', 'java', 'kotlin', 'swift', 'go', 'rust',
  'c', 'cpp', 'json', 'yaml', 'bash', 'sql', 'html', 'css', 'markdown', 'mermaid'
]

function sourceLines(source) {
  const lines = []
  let start = 0
  while (start < source.length) {
    const newline = source.indexOf('\n', start)
    const rawEnd = newline < 0 ? source.length : newline
    const contentEnd = rawEnd > start && source[rawEnd - 1] === '\r' ? rawEnd - 1 : rawEnd
    lines.push({
      start,
      contentEnd,
      nextStart: newline < 0 ? source.length : newline + 1,
      ending: newline < 0 ? '' : contentEnd < rawEnd ? '\r\n' : '\n'
    })
    if (newline < 0) break
    start = newline + 1
  }
  return lines
}

function fenceLine(text) {
  return /^( *)(`{3,}|~{3,})(.*)$/.exec(text)
}

function isFenceLikeLine(text) {
  return /^ {0,3}(?:`{3,}|~{3,})/.test(text)
}

export function inspectCodeFence(raw, renderedText) {
  const lines = sourceLines(raw)
  if (lines.length === 0) return null
  const first = lines[0]
  const firstText = raw.slice(first.start, first.contentEnd)
  const bomLength = firstText.startsWith('\uFEFF') ? 1 : 0
  const opening = fenceLine(firstText.slice(bomLength))
  if (!opening) return null

  const indent = opening[1]
  const fence = opening[2]
  const info = opening[3]
  const openingInfoFrom = first.start + bomLength + indent.length + fence.length
  const leadingInfoSpace = info.length - info.trimStart().length
  const infoTrimmed = info.trim()
  const language = infoTrimmed.length === 0 ? '' : infoTrimmed.split(/\s+/, 1)[0]
  const languageFrom = openingInfoFrom + leadingInfoSpace
  const languageTo = languageFrom + language.length
  const languageSuffix = info.slice(leadingInfoSpace + language.length)
  const languageOnly = languageSuffix.trim().length === 0
  const openingEnd = first.nextStart
  let closing = null

  for (let index = 1; index < lines.length; index++) {
    const line = lines[index]
    const text = raw.slice(line.start, line.contentEnd)
    const match = /^ {0,3}(`+|~+)[ \t]*$/.exec(text)
    if (match !== null && match[1][0] === fence[0] && match[1].length >= fence.length) {
      closing = { ...line, indent: text.length - text.trimStart().length }
      break
    }
  }

  const closed = closing !== null
  const bodyFrom = openingEnd
  const bodyTo = closed ? closing.start : raw.length
  const body = raw.slice(bodyFrom, bodyTo)
  const normalizedBody = body.replace(/\r\n/g, '\n')
  const logicalBody = normalizedBody.endsWith('\n') ? normalizedBody.slice(0, -1) : normalizedBody
  const nested = lines.some((line, index) => {
    if (index === 0 || line.start < bodyFrom || line.start >= bodyTo) return false
    return isFenceLikeLine(raw.slice(line.start, line.contentEnd))
  })
  const renderedBody = renderedText === undefined ? undefined :
    String(renderedText).replace(/\r\n/g, '\n').replace(/\n$/, '')
  const textMatches = renderedBody === undefined || logicalBody === renderedBody
  const reason = !closed ? 'unclosed' :
    indent.length > 0 || closing.indent > 0 ? 'indented' :
      nested ? 'nested' : !textMatches ? 'unmapped' :
        fence[0] === '`' && info.includes('`') ? 'invalid-info' : ''

  return {
    fence,
    language,
    closed,
    editable: reason.length === 0,
    reason,
    bodyFrom,
    bodyTo,
    body,
    logicalBody,
    openingInfoFrom,
    openingInfoTo: opening.nextStart,
    openingEnding: first.ending,
    languageFrom,
    languageTo,
    languagePrefix: info.slice(0, leadingInfoSpace),
    languageSuffix,
    languageSelectable: reason.length === 0 && languageOnly && COMMON_CODE_LANGUAGES.includes(language)
  }
}

export function prepareCodeBodyEdit(source, from, to, text) {
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to <= from || to > source.length) {
    return null
  }
  const model = inspectCodeFence(source.slice(from, to))
  if (!model || !model.editable) return null
  const bodyFrom = from + model.bodyFrom
  const bodyTo = from + model.bodyTo
  const expected = source.slice(bodyFrom, bodyTo)
  if (expected !== model.body) return null

  const content = String(text).replace(/\r\n/g, '\n')
  const lines = content.split('\n')
  if (lines.some(isFenceLikeLine)) return null

  const lineEnding = expected.includes('\r\n') ? '\r\n' :
    expected.includes('\n') ? '\n' : model.openingEnding || '\n'
  const structuralEnding = expected.endsWith('\r\n') ? '\r\n' : expected.endsWith('\n') ? '\n' : ''
  const fullReplacement = content.replace(/\n/g, lineEnding) +
    (content.length === 0 ? '' : expected.length === 0 ? lineEnding : structuralEnding)
  let prefix = 0
  while (prefix < expected.length && prefix < fullReplacement.length &&
    expected[prefix] === fullReplacement[prefix]) {
    prefix++
  }
  if (prefix > 0 && prefix < expected.length &&
    expected.charCodeAt(prefix - 1) >= 0xD800 && expected.charCodeAt(prefix - 1) <= 0xDBFF) {
    prefix--
  }
  let suffix = 0
  while (suffix < expected.length - prefix && suffix < fullReplacement.length - prefix &&
    expected[expected.length - suffix - 1] === fullReplacement[fullReplacement.length - suffix - 1]) {
    suffix++
  }
  if (suffix > 0 && suffix < expected.length &&
    expected.charCodeAt(expected.length - suffix) >= 0xDC00 &&
    expected.charCodeAt(expected.length - suffix) <= 0xDFFF) {
    suffix--
  }
  const editFrom = bodyFrom + prefix
  const editTo = bodyTo - suffix
  return {
    from: editFrom,
    to: editTo,
    expected: expected.slice(prefix, expected.length - suffix),
    replacement: fullReplacement.slice(prefix, fullReplacement.length - suffix),
    kind: 'code-body'
  }
}

export function prepareCodeLanguageEdit(source, from, to, language) {
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to < from || to > source.length ||
    !COMMON_CODE_LANGUAGES.includes(language)) {
    return null
  }
  const model = inspectCodeFence(source.slice(from, to))
  if (!model || !model.languageSelectable) return null
  const editFrom = from + model.languageFrom
  const editTo = from + model.languageTo
  const expected = source.slice(editFrom, editTo)
  if (expected !== model.language) return null
  const replacement = language
  return { from: editFrom, to: editTo, expected, replacement, kind: 'code-language' }
}

export function prepareInlineCodeUnwrap(source, from, to) {
  if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || to <= from || to > source.length) {
    return null
  }
  const expected = source.slice(from, to)
  const opening = /^`+/.exec(expected)?.[0] ?? ''
  const closing = /`+$/.exec(expected)?.[0] ?? ''
  if (opening.length === 0 || opening.length !== closing.length || expected.length <= opening.length * 2) {
    return null
  }
  return {
    from,
    to,
    expected,
    replacement: expected.slice(opening.length, expected.length - closing.length),
    kind: 'inline-code'
  }
}
