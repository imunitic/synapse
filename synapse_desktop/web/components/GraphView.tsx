import type { KeyboardEvent } from 'react'
import { NODE_HEIGHT, NODE_WIDTH, type Graph } from '../domain/graph.ts'

const MIN_SCALE = 0.75

// The steps and edges of a pipeline. A step can be chosen; `subtitles` gives
// each step a second line.
export function GraphView({
  graph,
  selected,
  onSelect,
  subtitles,
  states,
  arcCounts,
  flowCounts,
}: {
  graph: Graph
  selected?: string
  onSelect?: (name: string) => void
  subtitles?: Record<string, string>
  // Progress of a run: the state of each step, how many times each edge was
  // taken (by the edge's index) and how many times control fell through from
  // each step to the next. The state is also in the step's subtitle, because a
  // color alone says nothing to everyone.
  states?: Record<string, string>
  arcCounts?: Record<number, number>
  flowCounts?: number[]
}) {
  function onKey(event: KeyboardEvent, name: string) {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault()
      onSelect?.(name)
    }
  }

  return (
    <svg
      className="graph"
      viewBox={`0 0 ${graph.width} ${graph.height}`}
      // Its own size when there is room, smaller when there is not, and a
      // scroll bar only below that.
      style={{ width: '100%', minWidth: graph.width * MIN_SCALE, maxWidth: graph.width }}
      role="group"
      aria-label="Steps and edges"
    >
      {graph.flows.map((flow, i) => (
        <g
          key={flow.x1}
          className="graph-flow"
          data-taken={flowCounts === undefined ? undefined : (flowCounts[i] ?? 0) > 0}
          aria-hidden="true"
        >
          <line x1={flow.x1} y1={flow.y} x2={flow.x2 - 8} y2={flow.y} />
          <polygon
            points={`${flow.x2},${flow.y} ${flow.x2 - 9},${flow.y - 5} ${flow.x2 - 9},${flow.y + 5}`}
          />
        </g>
      ))}
      {graph.arcs.map((arc) => {
        const taken = arcCounts === undefined ? undefined : (arcCounts[arc.edgeIndex] ?? 0)
        return (
          <g
            key={arc.edgeIndex}
            className="graph-arc"
            data-taken={taken === undefined ? undefined : taken > 0}
          >
            <path d={arc.path} fill="none" />
            <polygon
              points={
                arc.tip.direction === 'down'
                  ? `${arc.tip.x},${arc.tip.y} ${arc.tip.x - 5},${arc.tip.y - 9} ${arc.tip.x + 5},${arc.tip.y - 9}`
                  : `${arc.tip.x},${arc.tip.y} ${arc.tip.x - 5},${arc.tip.y + 9} ${arc.tip.x + 5},${arc.tip.y + 9}`
              }
            />
            <text x={arc.labelX} y={arc.labelY} textAnchor="middle">
              {taken !== undefined && taken > 0 ? `${arc.label} · taken ${taken}×` : arc.label}
            </text>
          </g>
        )
      })}
      {graph.nodes.map((node) =>
        node.isEnd ? (
          <g key={node.name} className="graph-end" data-state={states?.[node.name]}>
            <rect x={node.x} y={node.y + 12} width={NODE_WIDTH} height={NODE_HEIGHT - 24} rx={18} />
            <text x={node.x + NODE_WIDTH / 2} y={node.y + NODE_HEIGHT / 2 + 5} textAnchor="middle">
              End
            </text>
          </g>
        ) : (
          <g
            key={node.name}
            className="graph-node"
            data-state={states?.[node.name]}
            role={onSelect ? 'button' : undefined}
            tabIndex={onSelect ? 0 : undefined}
            aria-label={`Step ${node.name}${subtitles?.[node.name] === undefined ? '' : `, ${subtitles[node.name]}`}`}
            aria-pressed={onSelect ? selected === node.name : undefined}
            onClick={() => onSelect?.(node.name)}
            onKeyDown={(event) => onKey(event, node.name)}
          >
            <rect x={node.x} y={node.y} width={NODE_WIDTH} height={NODE_HEIGHT} rx={8} />
            <text className="graph-name" x={node.x + 12} y={node.y + 26}>
              {node.name}
            </text>
            {subtitles?.[node.name] !== undefined && (
              <text className="graph-sub" x={node.x + 12} y={node.y + 45}>
                {subtitles[node.name]}
              </text>
            )}
          </g>
        ),
      )}
    </svg>
  )
}
