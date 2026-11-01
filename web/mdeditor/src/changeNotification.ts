export interface ChangeNotificationTimer {
  schedule(getLength: () => number, documentRevision: number,
    notify: (length: number, documentRevision: number) => void): void
  cancel(): void
}

export function createChangeNotificationTimer(
  setTimer: (callback: () => void, delayMs: number) => number,
  clearTimer: (timerId: number) => void,
  delayMs: number = 300
): ChangeNotificationTimer {
  let timerId: number | undefined = undefined

  const cancel = (): void => {
    if (timerId !== undefined) {
      clearTimer(timerId)
      timerId = undefined
    }
  }

  return {
    schedule(getLength: () => number, documentRevision: number,
      notify: (length: number, documentRevision: number) => void): void {
      cancel()
      const scheduledRevision = documentRevision
      timerId = setTimer((): void => {
        timerId = undefined
        notify(getLength(), scheduledRevision)
      }, delayMs)
    },
    cancel
  }
}
