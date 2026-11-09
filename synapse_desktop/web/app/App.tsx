import { ConfigProvider } from '../state/config.tsx'
import { DiagnosisProvider } from '../state/diagnosis.tsx'
import { Shell } from '../layout/Shell.tsx'

export function App() {
  return (
    <ConfigProvider>
      <DiagnosisProvider>
        <Shell />
      </DiagnosisProvider>
    </ConfigProvider>
  )
}
