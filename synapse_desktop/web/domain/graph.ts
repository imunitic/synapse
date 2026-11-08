// Where a pipeline's steps and edges go on the page: the steps in a row in the
// order they are declared, the way control moves from one to the next as an
// arrow between neighbours, and every edge as an arc, above the row when it
// leads forward and below it when it leads back.

import type { PipelineDescription } from './pipelines.ts'
import { guardLabel } from './pipelines.ts'

export const NODE_WIDTH = 150
export const NODE_HEIGHT = 60
const GAP = 56
const MARGIN = 24
const ARC_BASE = 24
const ARC_STEP = 20
const END = 'End'

export interface GraphNode {
  name: string
  // The End marker is not a step.
  isEnd: boolean
  x: number
  y: number
}

export interface GraphFlow {
  x1: number
  x2: number
  y: number
}

export interface GraphArc {
  // The edge's position in the description, which is its position in a run's `fired`.
  edgeIndex: number
  path: string
  // The point and direction of the arrowhead.
  tip: { x: number; y: number; direction: 'up' | 'down' }
  label: string
  labelX: number
  labelY: number
}

export interface Graph {
  width: number
  height: number
  nodes: GraphNode[]
  flows: GraphFlow[]
  arcs: GraphArc[]
}

export function layoutGraph(description: PipelineDescription): Graph {
  const names = description.steps.map((s) => s.name)
  const hasEnd = description.edges.some((e) => e.to === END)
  if (hasEnd) names.push(END)
  const indexOf = new Map(names.map((name, i) => [name, i]))

  const edges = description.edges.flatMap((edge) => {
    const from = indexOf.get(edge.from)
    const to = indexOf.get(edge.to)
    return from === undefined || to === undefined ? [] : [{ edge, from, to }]
  })
  const upper = edges.filter((e) => e.to > e.from).length

  // Room above the row for the forward arcs and their labels.
  const top = MARGIN + (upper === 0 ? 0 : ARC_BASE + ARC_STEP * upper)
  const nodeX = (i: number) => MARGIN + i * (NODE_WIDTH + GAP)
  const centre = (i: number) => nodeX(i) + NODE_WIDTH / 2
  const bottom = top + NODE_HEIGHT

  const nodes = names.map((name, i) => ({
    name,
    isEnd: name === END && hasEnd && i === names.length - 1,
    x: nodeX(i),
    y: top,
  }))
  const flows = names.slice(0, -1).map((_, i) => ({
    x1: nodeX(i) + NODE_WIDTH,
    x2: nodeX(i + 1),
    y: top + NODE_HEIGHT / 2,
  }))

  // Within a direction, a shorter arc goes closer to the row than a longer one,
  // so that the arcs nest and do not cross.
  const lanes = new Map<number, number>()
  for (const forward of [true, false]) {
    edges
      .filter((e) => e.to > e.from === forward)
      .sort(
        (a, b) => Math.abs(a.to - a.from) - Math.abs(b.to - b.from) || a.edge.index - b.edge.index,
      )
      .forEach((e, lane) => lanes.set(e.edge.index, lane))
  }

  // Where an arc meets a step: every arc that meets the same side of the same
  // step in the same way gets its own place along it, and the shortest of them
  // is the furthest toward the other end, so that they do not cross either.
  type End = { node: number; forward: boolean; role: 'out' | 'in' }
  const groups = new Map<string, number[]>()
  const key = (end: End) => `${end.node}:${end.forward}:${end.role}`
  const endsOf = (e: { edge: { index: number }; from: number; to: number }) => {
    const forward = e.to > e.from
    return [
      { node: e.from, forward, role: 'out' as const },
      { node: e.to, forward, role: 'in' as const },
    ]
  }
  for (const e of edges) {
    for (const end of endsOf(e))
      groups.set(key(end), [...(groups.get(key(end)) ?? []), e.edge.index])
  }
  const place = (end: End, edgeIndex: number, towards: 1 | -1): number => {
    const sharing = (groups.get(key(end)) ?? []).sort(
      (a, b) => (lanes.get(a) ?? 0) - (lanes.get(b) ?? 0),
    )
    const rank = sharing.indexOf(edgeIndex)
    const offset = 12 + 10 * (sharing.length - 1 - rank) + (end.role === 'in' ? 5 : 0)
    return centre(end.node) + towards * offset
  }

  const arcs = edges.map((e): GraphArc => {
    const { edge, from, to } = e
    const parts = [
      guardLabel(edge.guard),
      edge.max_iterations === null ? null : `max ${edge.max_iterations}`,
    ]
    const label = parts.filter((p) => p !== null).join(' · ')
    const lane = lanes.get(edge.index) ?? 0
    const [out, into] = endsOf(e) as [End, End]
    if (to > from) {
      const y = top - ARC_BASE - ARC_STEP * lane
      const x1 = place(out, edge.index, 1)
      const x2 = place(into, edge.index, -1)
      return {
        edgeIndex: edge.index,
        path: `M ${x1} ${top} V ${y} H ${x2} V ${top}`,
        tip: { x: x2, y: top, direction: 'down' },
        label,
        labelX: (x1 + x2) / 2,
        // On the line, which the label's halo breaks.
        labelY: y + 4,
      }
    }
    const y = bottom + ARC_BASE + ARC_STEP * lane
    const x1 = place(out, edge.index, -1)
    const x2 = place(into, edge.index, 1)
    return {
      edgeIndex: edge.index,
      path: `M ${x1} ${bottom} V ${y} H ${x2} V ${bottom}`,
      tip: { x: x2, y: bottom, direction: 'up' },
      label,
      labelX: (x1 + x2) / 2,
      labelY: y + 4,
    }
  })

  const lower = arcs.length - upper
  return {
    width: MARGIN * 2 + names.length * NODE_WIDTH + (names.length - 1) * GAP,
    height: bottom + (lower === 0 ? MARGIN : ARC_BASE + ARC_STEP * lower + MARGIN),
    nodes,
    flows,
    arcs,
  }
}
