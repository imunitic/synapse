// The width rules of a panel a person can resize by dragging its edge or with the arrow keys:
// the width kept in storage, the limits it stays within, and the room the main page keeps.
// Pure: no DOM and no React, so the hook that uses it stays thin.

export const MAIN_MIN_PX = 360
export const KEY_STEP_PX = 16
export const KEY_STEP_SHIFT_PX = 64

export interface WidthLimits {
  min: number
  max: number
  initial: number
}

// The width kept in storage, or `initial` when there is none, or it is not a number inside the limits.
export function readStoredWidth(stored: string | null, limits: WidthLimits): number {
  if (stored === null || stored.trim() === '') return limits.initial
  const width = Number(stored)
  if (!Number.isFinite(width) || width < limits.min || width > limits.max) return limits.initial
  return width
}

// `wanted` within the limits, and narrow enough that the main page keeps MAIN_MIN_PX.
export function clampWidth(
  wanted: number,
  limits: WidthLimits,
  room: { current: number; mainWidth: number },
): number {
  const roomy = room.current + room.mainWidth - MAIN_MIN_PX
  const most = Math.max(limits.min, Math.min(limits.max, roomy))
  return Math.min(Math.max(wanted, limits.min), most)
}

// One arrow key press: 16 px, or 64 px with Shift, towards `direction` (+1 wider, -1 narrower).
export function stepWidth(
  current: number,
  direction: 1 | -1,
  shift: boolean,
  limits: WidthLimits,
  mainWidth: number,
): number {
  const step = shift ? KEY_STEP_SHIFT_PX : KEY_STEP_PX
  return clampWidth(current + direction * step, limits, { current, mainWidth })
}
