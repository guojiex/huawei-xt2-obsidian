export function serializeCalloutBody(source, bodyMarkdown) {
  const trailing = /(?:\r?\n)*$/.exec(source)?.[0] ?? ''
  const content = source.slice(0, source.length - trailing.length)
  const newline = content.indexOf('\n')
  const hasHeaderLineEnding = newline >= 0
  const header = (hasHeaderLineEnding ? content.slice(0, newline) : content).replace(/\r$/, '')
  const sourceBody = hasHeaderLineEnding ? content.slice(newline + 1) : ''
  const lineEnding = source.includes('\r\n') ? '\r\n' : '\n'
  const bodyPrefix = /^([ \t]{0,3}>[ \t]?)/.exec(sourceBody)?.[1]
  const headerPrefix = /^[ \t]{0,3}>/.exec(header.replace(/^\uFEFF/, ''))?.[0] ?? '>'
  const quotePrefix = bodyPrefix ?? `${headerPrefix} `
  const normalizedBody = String(bodyMarkdown).replace(/\r\n?/g, '\n').replace(/\n+$/, '')

  if (normalizedBody.length === 0) return header + trailing
  return header + lineEnding +
    normalizedBody.split('\n').map((line) => quotePrefix + line).join(lineEnding) + trailing
}
