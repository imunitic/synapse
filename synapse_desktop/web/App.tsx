import { ConfigProvider } from './shell/config.tsx'
import { DiagnosisProvider } from './shell/diagnosis.tsx'
import { Shell } from './shell/Shell.tsx'

export function App() {
  return (
    <ConfigProvider>
      <DiagnosisProvider>
        <Shell />
      </DiagnosisProvider>
    </ConfigProvider>
  )
}
