import { describe, expect, it } from 'vitest'
import { DEVELOP_FEATURE_SHOW } from './fixtures.ts'
import type { MeasureText } from './graph.ts'
import { layoutGraph, NODE_HEIGHT, NODE_MIN_WIDTH } from './graph.ts'
import type { PipelineDescription } from './pipelines.ts'

// Eight pixels a character, whatever the kind of text.
const measure: MeasureText = (text) => text.length * 8

const develop = JSON.parse(DEVELOP_FEATURE_SHOW) as PipelineDescription

function pipeline(
  steps: string[],
  edges: [string, string, unknown?, number?][],
): PipelineDescription {
  return {
    format: 'synapse-pipeline-description/v1',
    name: 'P',
    steps: steps.map((name) => ({
      name,
      harness: 'Claude',
      model: null,
      permissions: 'Workspace_Write',
      timeout_seconds: 1800,
      retries: 0,
      outcomes: null,
      role: null,
      assignment: null,
      origins: [],
    })),
    edges: edges.map(([from, to, guard, max], index) => ({
      index,
      from,
      to,
      guard: guard ?? null,
      max_iterations: max ?? null,
    })),
    limits: { default_timeout_seconds: 1800, step_ceiling: 50, runner: 'process' },
  }
}

describe('layoutGraph', () => {
  it('puts the steps of a real pipeline in a row with an arrow between neighbours', () => {
    const graph = layoutGraph(develop, measure)
    expect(graph.nodes.map((n) => n.name)).toEqual(['Develop', 'Test', 'Review'])
    expect(graph.nodes.every((n) => n.y === graph.nodes[0]?.y)).toBe(true)
    expect(graph.nodes[1]!.x).toBeGreaterThan(graph.nodes[0]!.x + graph.nodes[0]!.width)
    expect(graph.flows).toHaveLength(2)
  })

  it('draws a back edge below the row with its guard and bound as the label', () => {
    const graph = layoutGraph(develop, measure)
    const [arc] = graph.arcs
    expect(graph.arcs).toHaveLength(1)
    expect(arc).toMatchObject({ edgeIndex: 0, label: 'Changes_Requested · max 5' })
    expect(arc?.tip.direction).toBe('up')
    expect(arc!.tip.y).toBe(graph.nodes[0]!.y + NODE_HEIGHT)
    expect(graph.height).toBeGreaterThan(graph.nodes[0]!.y + NODE_HEIGHT)
  })

  it('draws a forward edge above the row and makes room for it', () => {
    const graph = layoutGraph(
      pipeline(['A', 'B', 'C'], [['A', 'C', { '==': [{ var: 'outcome' }, 'Skip'] }]]),
      measure,
    )
    const [arc] = graph.arcs
    expect(arc?.tip.direction).toBe('down')
    expect(arc!.labelY).toBeLessThan(graph.nodes[0]!.y)
    expect(graph.nodes[0]!.y).toBeGreaterThan(24)
  })

  it('adds an End marker after the last step when an edge leads to End', () => {
    const graph = layoutGraph(
      pipeline(['A', 'B'], [['A', 'End', { '==': [{ var: 'outcome' }, 'Done'] }]]),
      measure,
    )
    expect(graph.nodes.map((n) => [n.name, n.isEnd])).toEqual([
      ['A', false],
      ['B', false],
      ['End', true],
    ])
    expect(graph.flows).toHaveLength(2)
  })

  it('does not add an End marker when no edge leads to End', () => {
    expect(layoutGraph(develop, measure).nodes.some((n) => n.isEnd)).toBe(false)
  })

  it('stacks arcs of the same direction at different heights', () => {
    const graph = layoutGraph(
      pipeline(
        ['A', 'B', 'C'],
        [
          ['C', 'A'],
          ['C', 'B'],
        ],
      ),
      measure,
    )
    expect(graph.arcs[0]!.labelY).not.toBe(graph.arcs[1]!.labelY)
  })

  it('skips an edge that names a step that does not exist', () => {
    expect(layoutGraph(pipeline(['A'], [['A', 'Nowhere']]), measure).arcs).toEqual([])
  })

  it('has no extra height without arcs', () => {
    const plain = layoutGraph(pipeline(['A', 'B'], []), measure)
    expect(plain.height).toBe(24 + NODE_HEIGHT + 24)
  })

  describe('the width of a box', () => {
    it('is the minimum for short names', () => {
      const graph = layoutGraph(pipeline(['A', 'Build', 'Test'], []), measure)
      expect(graph.nodes.map((n) => n.width)).toEqual([
        NODE_MIN_WIDTH,
        NODE_MIN_WIDTH,
        NODE_MIN_WIDTH,
      ])
    })

    it('fits a long name, and the next box starts one gap after it', () => {
      const graph = layoutGraph(pipeline(['Performance_Review_And_Signoff', 'Ship'], []), measure)
      const [long, next] = graph.nodes
      // 30 characters at 8 each, and 12 on each side.
      expect(long!.width).toBe(264)
      expect(next!.x).toBe(long!.x + 264 + 56)
    })

    it('fits a long harness under a short name', () => {
      const description = pipeline(['A', 'B'], [])
      description.steps[0]!.harness = 'Performance_Review_And_Signoff'
      const graph = layoutGraph(description, measure)
      expect(graph.nodes[0]!.width).toBe(264)
      expect(graph.nodes[1]!.x).toBe(graph.nodes[0]!.x + 264 + 56)
    })

    it('gives the End marker the minimum width', () => {
      const graph = layoutGraph(
        pipeline(['A'], [['A', 'End', { '==': [{ var: 'outcome' }, 'Done'] }]]),
        () => 1000,
      )
      expect(graph.nodes[1]).toMatchObject({ isEnd: true, width: NODE_MIN_WIDTH })
    })

    it('runs every arrow from the right edge of one box to the left edge of the next', () => {
      const graph = layoutGraph(
        pipeline(['Plan', 'Performance_Review_And_Signoff', 'Ship'], []),
        measure,
      )
      graph.flows.forEach((flow, i) => {
        const left = graph.nodes[i]!
        expect(flow.x1).toBe(left.x + left.width)
        expect(flow.x2).toBe(graph.nodes[i + 1]!.x)
      })
    })

    it('makes the diagram as wide as the right edge of the last box and the margin', () => {
      const graph = layoutGraph(
        pipeline(['Plan', 'Performance_Review_And_Signoff', 'Ship'], []),
        measure,
      )
      const last = graph.nodes[graph.nodes.length - 1]!
      expect(graph.width).toBe(last.x + last.width + 24)
    })
  })

  describe('a pipeline with several loops', () => {
    const when = (outcome: string) => ({ '==': [{ var: 'outcome' }, outcome] })
    // The same pipeline, with the second step under another name.
    function shipNamed(implement: string): PipelineDescription {
      return pipeline(
        ['Plan', implement, 'Test', 'Review', 'Document', 'Release'],
        [
          ['Plan', 'End', when('Rejected')],
          ['Test', implement, when('Failing'), 3],
          ['Test', 'Document', when('Skip_Review')],
          ['Review', implement, when('Changes_Requested'), 5],
          ['Review', 'Plan', when('Redesign'), 2],
        ],
      )
    }
    const ship = layoutGraph(shipNamed('Implement'), measure)
    const arc = (label: string) => ship.arcs.find((a) => a.label.startsWith(label))!
    // The path of an arc is `M <x> <y> V <y> H <x> V <y>`.
    // The three straight pieces of an arc, from its path.
    function segments(path: string) {
      const [, x1, top, , y, , x2] = path.split(' ').map(Number)
      return [
        { x1: x1!, y1: top!, x2: x1!, y2: y! },
        { x1: x1!, y1: y!, x2: x2!, y2: y! },
        { x1: x2!, y1: y!, x2: x2!, y2: top! },
      ]
    }
    // Pairs of arcs where a vertical piece of one passes through a horizontal
    // piece of the other.
    function crossings(arcs: typeof ship.arcs): string[] {
      const found: string[] = []
      for (const a of arcs) {
        for (const b of arcs) {
          if (a === b) continue
          for (const v of segments(a.path).filter((s) => s.x1 === s.x2)) {
            for (const h of segments(b.path).filter((s) => s.y1 === s.y2)) {
              const inX = v.x1 > Math.min(h.x1, h.x2) && v.x1 < Math.max(h.x1, h.x2)
              const inY = h.y1 > Math.min(v.y1, v.y2) && h.y1 < Math.max(v.y1, v.y2)
              if (inX && inY) found.push(`${a.label} crosses ${b.label}`)
            }
          }
        }
      }
      return found
    }
    const startX = (label: string) => Number(arc(label).path.split(' ')[1])
    const endX = (label: string) => Number(arc(label).path.split(' ')[6])

    it('puts a shorter arc closer to the row than a longer one, so that they nest', () => {
      // Below the row, closer is smaller; above it, closer is larger.
      expect(arc('Failing').labelY).toBeLessThan(arc('Changes_Requested').labelY)
      expect(arc('Changes_Requested').labelY).toBeLessThan(arc('Redesign').labelY)
      expect(arc('Skip_Review').labelY).toBeGreaterThan(arc('Rejected').labelY)
    })

    it('does not run two arcs out of the same step along the same line', () => {
      expect(startX('Changes_Requested')).not.toBe(startX('Redesign'))
      expect(endX('Failing')).not.toBe(endX('Changes_Requested'))
    })

    it('lets no two arcs cross', () => {
      expect(crossings(ship.arcs)).toEqual([])
    })

    it('draws every edge once', () => {
      expect(ship.arcs).toHaveLength(5)
      expect(new Set(ship.arcs.map((a) => a.edgeIndex)).size).toBe(5)
    })

    it('keeps the arcs apart and on their boxes when one box is wider', () => {
      const description = shipNamed('Implement_The_Plan_Step_By_One')
      const wide = layoutGraph(description, measure)
      expect(wide.nodes[1]!.width).toBeGreaterThan(150)
      expect(crossings(wide.arcs)).toEqual([])
      const box = (name: string) => wide.nodes.find((n) => n.name === name)!
      for (const a of wide.arcs) {
        const edge = description.edges[a.edgeIndex]!
        const [, x1, , , , , x2] = a.path.split(' ').map(Number)
        for (const [name, x] of [
          [edge.from, x1!],
          [edge.to, x2!],
        ] as const) {
          expect(x).toBeGreaterThan(box(name).x)
          expect(x).toBeLessThan(box(name).x + box(name).width)
        }
      }
    })
  })
})
