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
