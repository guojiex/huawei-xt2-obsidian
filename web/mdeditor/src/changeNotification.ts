export interface ChangeNotificationTimer {
  schedule(getLength: () => number, notify: (length: number) => void): void
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
    schedule(getLength: () => number, notify: (length: number) => void): void {
      cancel()
      timerId = setTimer((): void => {
        timerId = undefined
        notify(getLength())
      }, delayMs)
    },
    cancel
  }
}
