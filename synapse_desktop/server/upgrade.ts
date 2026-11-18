// Each kind of WebSocket has its own listener for the handshakes on its path and leaves the others
// alone; a handshake that no path claims is dropped here.

import type { Server } from 'node:http'

export function dropUnclaimedUpgrades(server: Server, paths: readonly string[]): void {
  server.on('upgrade', (req, socket) => {
    if (!paths.includes(req.url ?? '')) socket.destroy()
  })
}
