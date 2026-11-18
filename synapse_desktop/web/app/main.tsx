import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { App } from './App.tsx'
import './index.css'
import { startTextSize } from '../state/text-size.ts'
import { startTheme } from '../state/theme.ts'
import { startPlainTyping } from '../state/plain-typing.ts'

const root = document.getElementById('root')
if (root === null) throw new Error('index.html has no #root element')

// The size of the text and the theme are put on the page before it is drawn, so that it does not
// jump or flash.
startTextSize()
startTheme()
// What is typed in a field stays as typed: no capitalizing or correcting by macOS.
startPlainTyping()

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
