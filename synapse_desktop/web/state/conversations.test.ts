import { describe, expect, it } from 'vitest'
import { conversationsOf, onConversationsChange, setConversations } from './conversations.ts'

describe('the conversations a session follows', () => {
  it('are what its terminal published last, each session apart, and go when none are left', () => {
    let told = 0
    const stop = onConversationsChange(() => (told += 1))
    const claude = { id: 'c1', harness: 'Claude' as const, cwd: '/w', lines: ['{}'] }
    setConversations('s1', [claude])
    setConversations('s2', [{ ...claude, id: 'c2' }])
    expect(conversationsOf('s1').map((c) => c.id)).toEqual(['c1'])
    expect(conversationsOf('s2').map((c) => c.id)).toEqual(['c2'])
    setConversations('s1', [])
    expect(conversationsOf('s1')).toEqual([])
    expect(conversationsOf('nobody')).toEqual([])
    stop()
    setConversations('s2', [])
    expect(told).toBe(3)
  })
})
