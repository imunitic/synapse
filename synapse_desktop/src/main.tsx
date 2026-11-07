import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { App } from './App.tsx'
import './index.css'
import { startTextSize } from './shell/text-size.ts'

const root = document.getElementById('root')
if (root === null) throw new Error('index.html has no #root element')

// The size of the text is put on the page before it is drawn, so that it does not jump.
startTextSize()

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
