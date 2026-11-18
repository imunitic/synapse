import { useState } from 'react'
import { attentionOf, dismissedWarnings, type Attention, type Fix } from '../domain/diagnosis.ts'
import { useDiagnosis } from '../state/diagnosis.tsx'
import type { Page, TerminalKind } from '../state/state.ts'

// A command to run in a terminal. It is shown and can be copied, and is never run for the
// person.
function CommandFix({
  fix,
  onStartTerminal,
}: {
  fix: Extract<Fix, { kind: 'command' }>
  onStartTerminal: (kind: TerminalKind) => void
}) {
  const [copied, setCopied] = useState(false)
  function copy() {
    navigator.clipboard.writeText(fix.command).then(
      () => setCopied(true),
      () => setCopied(false),
    )
  }
  return (
    <div className="setup-command">
      <span className="muted small">{fix.label}</span>
      <code className="mono">{fix.command}</code>
      <button
        className="secondary"
        aria-label={`${copied ? 'Copied' : 'Copy'} the command for ${fix.label}`}
        onClick={copy}
      >
        {copied ? 'Copied' : 'Copy'}
      </button>
      <button className="link" onClick={() => onStartTerminal('Shell')}>
        Open a shell
      </button>
    </div>
  )
}

function Finding({
  item,
  onOpen,
  onStartTerminal,
  onDismiss,
}: {
  item: Attention
  onOpen: (page: Page) => void
  onStartTerminal: (kind: TerminalKind) => void
  onDismiss: () => void
}) {
  return (
    <li className="setup-finding" data-severity={item.severity}>
      <div className="setup-finding-head">
        <span className="setup-severity" data-severity={item.severity}>
          {item.severity === 'error' ? 'Needs doing' : 'Worth a look'}
        </span>
        <strong>{item.title}</strong>
      </div>
      <p className="muted">{item.detail}</p>
      <div className="setup-fixes">
        {item.fixes.map((fix) =>
          fix.kind === 'settings' ? (
            <button
              key={fix.label}
              className="secondary"
              onClick={() => onOpen({ kind: 'settings', section: fix.section })}
            >
              {fix.label}
            </button>
          ) : (
            <CommandFix key={fix.command} fix={fix} onStartTerminal={onStartTerminal} />
          ),
        )}
        {item.dismissible && (
          <button className="link" onClick={onDismiss}>
            Dismiss
          </button>
        )}
      </div>
    </li>
  )
}

// What `synapse doctor` found that is not fine, and what puts each right. It is not there
// while everything is fine, except for the warnings that were put aside, which can be
// brought back.
export function SetupCheckCard({
  onOpen,
  onStartTerminal,
}: {
  onOpen: (page: Page) => void
  onStartTerminal: (kind: TerminalKind) => void
}) {
  const { state, checking, recheck, dismissed, dismiss, restore } = useDiagnosis()
  const [showAll, setShowAll] = useState(false)
  if (state.status === 'loading') return null
  if (state.status === 'failed') {
    return (
      <section className="card setup-check" aria-label="Setup check">
        <h2 className="card-title">Setup check</h2>
        <p role="alert">Could not check the setup: {state.error}</p>
        <div className="row">
          <button className="secondary" disabled={checking} onClick={recheck}>
            {checking ? 'Checking…' : 'Check again'}
          </button>
        </div>
      </section>
    )
  }
  const items = attentionOf(state.data, dismissed)
  const aside = dismissedWarnings(state.data, dismissed)
  if (items.length === 0 && aside.length === 0) return null
  return (
    <section className="card setup-check" aria-label="Setup check">
      <div className="card-head">
        <h2 className="card-title">Setup check</h2>
        <span className="row">
          <button className="secondary" disabled={checking} onClick={recheck}>
            {checking ? 'Checking…' : 'Check again'}
          </button>
        </span>
      </div>
      {items.length === 0 ? (
        <p className="muted">Nothing needs doing.</p>
      ) : (
        <ul className="setup-findings">
          {items.map((item) => (
            <Finding
              key={item.key}
              item={item}
              onOpen={onOpen}
              onStartTerminal={onStartTerminal}
              onDismiss={() => dismiss(item.key)}
            />
          ))}
        </ul>
      )}
      <div className="setup-more">
        {aside.length > 0 && (
          <button className="link" onClick={restore}>
            {aside.length === 1 ? '1 warning put aside' : `${aside.length} warnings put aside`}
            {' · show'}
          </button>
        )}
        <button className="link" aria-expanded={showAll} onClick={() => setShowAll(!showAll)}>
          {showAll ? 'Hide all checks' : `All ${state.data.findings.length} checks`}
        </button>
      </div>
      {showAll && (
        <ul className="setup-all" aria-label="All checks">
          {state.data.findings.map((finding) => (
            <li key={finding.key}>
              <span className="setup-status" data-status={finding.status}>
                {finding.status}
              </span>
              <span className="mono">{finding.name}</span>
              <span className="muted small">{finding.detail}</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
