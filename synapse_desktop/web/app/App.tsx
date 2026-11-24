import { useEffect, useState } from 'react'
import { inTauri } from '../transport/tauri-link.ts'
import { ConfigProvider } from '../state/ConfigProvider.tsx'
import { DiagnosisProvider } from '../state/DiagnosisProvider.tsx'
import { Shell } from '../layout/Shell.tsx'

export function App() {
  const [privateSession, setPrivateSession] = useState(false)
  const [logoutError, setLogoutError] = useState(false)
  const [signingOut, setSigningOut] = useState(false)

  useEffect(() => {
    if (inTauri()) return
    let current = true
    void fetch('/auth/me', { cache: 'no-store' })
      .then(async (response) => {
        if (!response.ok) return
        const result = (await response.json()) as { authenticated?: boolean }
        if (current && result.authenticated === true) setPrivateSession(true)
      })
      .catch(() => undefined)
    return () => {
      current = false
    }
  }, [])

  async function signOut() {
    if (!window.confirm('Sign out? Any unsent draft comments in this tab will be lost.')) return
    setSigningOut(true)
    setLogoutError(false)
    try {
      const response = await fetch('/auth/logout', { method: 'POST', cache: 'no-store' })
      if (!response.ok) throw new Error('logout failed')
      sessionStorage.clear()
      window.location.replace('/login')
    } catch {
      setLogoutError(true)
      setSigningOut(false)
    }
  }

  return (
    <>
      {privateSession && (
        <div>
          <button disabled={signingOut} onClick={() => void signOut()}>
            Sign out
          </button>
          {logoutError && <span role="alert">Sign out failed. Please retry.</span>}
        </div>
      )}
      <ConfigProvider>
        <DiagnosisProvider>
          <Shell />
        </DiagnosisProvider>
      </ConfigProvider>
    </>
  )
}
