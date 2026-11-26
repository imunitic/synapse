// The number of days the Clean up dialog offers, kept in the browser from the last clean up.
// Thirty days where nothing usable was kept or the storage cannot be used.

const daysKey = 'synapse.cleanupDays'

export const defaultCleanupDays = 30

export function readCleanupDays(storage: Pick<Storage, 'getItem'>): number {
  try {
    const kept = storage.getItem(daysKey)
    if (kept === null || !/^\d+$/.test(kept.trim())) return defaultCleanupDays
    const days = Number(kept.trim())
    return Number.isSafeInteger(days) && days >= 1 ? days : defaultCleanupDays
  } catch {
    return defaultCleanupDays
  }
}

export function writeCleanupDays(storage: Pick<Storage, 'setItem'>, days: number): void {
  try {
    storage.setItem(daysKey, String(days))
  } catch {
    // The number of days is only a convenience.
  }
}
