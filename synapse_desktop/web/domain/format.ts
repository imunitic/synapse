// A length of time in seconds as people write it: 90 as `1m 30s`, 1800 as `30m`.
export function formatDuration(seconds: number): string {
  if (seconds <= 0) return '0s'
  const hours = Math.floor(seconds / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)
  const rest = seconds % 60
  return [
    hours > 0 ? `${hours}h` : '',
    minutes > 0 ? `${minutes}m` : '',
    rest > 0 ? `${rest}s` : '',
  ]
    .filter(Boolean)
    .join(' ')
}

// How long before `now` a time was, in the largest whole unit: `just now`,
// `5 minutes ago`, `3 hours ago`, `2 days ago`; a date for anything over a month.
export function timeAgo(iso: string, now: Date): string {
  const then = Date.parse(iso)
  if (Number.isNaN(then)) return ''
  const seconds = Math.max(0, Math.floor((now.getTime() - then) / 1000))
  const units: [number, string][] = [
    [86_400, 'day'],
    [3600, 'hour'],
    [60, 'minute'],
  ]
  if (seconds < 60) return 'just now'
  if (seconds >= 30 * 86_400) return new Date(then).toISOString().slice(0, 10)
  for (const [size, name] of units) {
    if (seconds >= size) {
      const count = Math.floor(seconds / size)
      return `${count} ${name}${count === 1 ? '' : 's'} ago`
    }
  }
  return 'just now'
}
