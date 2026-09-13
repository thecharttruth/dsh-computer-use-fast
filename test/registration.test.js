import test from 'node:test'
import assert from 'node:assert/strict'
import { apply } from '../index.js'

function register() {
  let gate
  const tools = new Map()
  apply({
    effect() {},
    on(event, fn) { if (event === 'tools/pre-execute') gate = fn },
    tools: { register(tool) { tools.set(tool.name, tool) } },
  }, { driverWarmup: false })
  return { gate, tools }
}

test('the registered plugin asks before saving or releasing its target', async () => {
  const { gate, tools } = register()
  assert.ok(tools.has('computer_render_check'))
  for (const request of [
    { name: 'computer_render_check', arguments: { handle: 1, save_path: 'capture.png' } },
    { name: 'computer_release', arguments: {} },
    { name: 'computer_uia_scan', arguments: { handle: 1 } },
  ]) {
    const result = await gate(request, () => ({ kind: 'allow' }))
    assert.equal(result.kind, 'ask')
  }
  const result = await gate({ name: 'computer_render_check', arguments: { handle: 1 } }, () => ({ kind: 'allow' }))
  assert.equal(result.kind, 'allow')
})
