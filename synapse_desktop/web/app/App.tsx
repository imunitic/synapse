import { ConfigProvider } from '../state/ConfigProvider.tsx'
import { DiagnosisProvider } from '../state/DiagnosisProvider.tsx'
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
