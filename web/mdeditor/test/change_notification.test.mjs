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
  change.schedule(() => 12, (length) => notifications.push(length))

  change.cancel()
  timers.runPending()

  assert.deepEqual(notifications, [])
  assert.deepEqual(timers.cleared, [1])
})

test('rescheduling coalesces edits and reports the latest pending document length', () => {
  const timers = createFakeTimers()
  const notifications = []
  const change = createChangeNotificationTimer(timers.setTimer, timers.clearTimer)
  change.schedule(() => 12, (length) => notifications.push(length))
  change.schedule(() => 27, (length) => notifications.push(length))

  timers.runPending()

  assert.deepEqual(notifications, [27])
  assert.deepEqual(timers.cleared, [1])
  assert.equal([...timers.callbacks.values()].length, 0)
})

test('programmatic document replacement cancels pending change before dispatch', () => {
  const source = fs.readFileSync(new URL('../src/index.ts', import.meta.url), 'utf8')
  const setContentStart = source.indexOf('  setContent(b64: string): void {')
  const setContentEnd = source.indexOf('\n  getContent(): string {', setContentStart)
  assert.ok(setContentStart >= 0 && setContentEnd > setContentStart)
  const setContent = source.slice(setContentStart, setContentEnd)
  const cancelAt = setContent.indexOf('changeNotification.cancel()')
  const dispatchAt = setContent.indexOf('v.dispatch({')

  assert.ok(cancelAt >= 0 && dispatchAt > cancelAt)
  assert.match(source, /changeNotification\.schedule\(/)
  assert.doesNotMatch(source, /changeTimer/)
})
