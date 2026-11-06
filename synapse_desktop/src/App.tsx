import { ConfigProvider } from './shell/config.tsx'
import { Shell } from './shell/Shell.tsx'

export function App() {
  return (
    <ConfigProvider>
      <Shell />
    </ConfigProvider>
  )
}
