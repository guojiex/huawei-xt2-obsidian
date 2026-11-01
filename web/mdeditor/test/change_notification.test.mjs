import assert from 'node:assert/strict'
import fs from 'node:fs'
import { test } from 'node:test'
import { createRequire } from 'node:module'

const require = createRequire(new URL('../package.json', import.meta.url))
const { transformSync } = require('esbuild')
const moduleUrl = new URL('../src/changeNotification.ts', import.meta.url)
const compiled = transformSync(fs.readFileSync(moduleUrl, 'utf8'), { loader: 'ts', format: 'cjs' }).code
const module = { exports: {} }
new Function('module', 'exports', compiled)(module, module.exports)
const { createChangeNotificationTimer } = module.exports

function createFakeTimers() {
  let nextId = 1
  const callbacks = new Map()
  const cleared = []
  return {
    callbacks,
    cleared,
    setTimer(callback, delayMs) {
      const id = nextId++
      callbacks.set(id, { callback, delayMs })
      return id
    },
    clearTimer(id) {
      cleared.push(id)
      callbacks.delete(id)
    },
    runPending() {
      const pending = [...callbacks.values()]
      callbacks.clear()
      pending.forEach(({ callback }) => callback())
    }
  }
}

test('cancel prevents a pending old-document change from notifying the next target', () => {
  const timers = createFakeTimers()
  const notifications = []
  const change = createChangeNotificationTimer(timers.setTimer, timers.clearTimer)
  change.schedule(() => 12, 1, (length) => notifications.push(length))

  change.cancel()
  timers.runPending()

  assert.deepEqual(notifications, [])
  assert.deepEqual(timers.cleared, [1])
})

test('rescheduling coalesces edits and reports the latest pending document length', () => {
  const timers = createFakeTimers()
  const notifications = []
  const change = createChangeNotificationTimer(timers.setTimer, timers.clearTimer)
  change.schedule(() => 12, 1, (length) => notifications.push(length))
  change.schedule(() => 27, 2, (length) => notifications.push(length))

  timers.runPending()

  assert.deepEqual(notifications, [27])
  assert.deepEqual(timers.cleared, [1])
  assert.equal([...timers.callbacks.values()].length, 0)
})

test('an edit notification carries the document revision captured when it was scheduled', () => {
  const timers = createFakeTimers()
  const notifications = []
  const change = createChangeNotificationTimer(timers.setTimer, timers.clearTimer)
  change.schedule(() => 27, 41, (length, revision) => notifications.push([length, revision]))

  timers.runPending()

  assert.deepEqual(notifications, [[27, 41]])
  assert.deepEqual(timers.cleared, [])
})

test('programmatic document replacement cancels pending change before dispatch', () => {
  const source = fs.readFileSync(new URL('../src/index.ts', import.meta.url), 'utf8')
  const setContentStart = source.indexOf('  setContent(b64: string, revision: number, vaultIdB64: string, noteDirB64: string): void {')
  const setContentEnd = source.indexOf('\n  getContent(): string {', setContentStart)
  assert.ok(setContentStart >= 0 && setContentEnd > setContentStart)
  const setContent = source.slice(setContentStart, setContentEnd)
  const cancelAt = setContent.indexOf('changeNotification.cancel()')
  const dispatchAt = setContent.indexOf('v.dispatch({')

  assert.ok(cancelAt >= 0 && dispatchAt > cancelAt)
  assert.match(source, /changeNotification\.schedule\(/)
  assert.match(source, /name: 'change', len: len, revision: revision/)
  assert.doesNotMatch(source, /changeTimer/)
})
