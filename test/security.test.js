import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile, rm } from 'node:fs/promises'
import { dirname, basename } from 'node:path'
import { requiresApproval } from '../security-policy.js'
import { CaptureFiles, validateCaptureName } from '../capture-files.js'

test('mutating mode gates disk writes, scroll scans, target release, and unknown tools', () => {
  for (const exec of [
    { name: 'computer_render_check', arguments: { save_path: 'capture.png' } },
    { name: 'computer_uia_scan', arguments: {} },
    { name: 'computer_uia_scan', arguments: { max_pages: 1 } },
    { name: 'computer_release' }, { name: 'computer_click' }, { name: 'computer_future_action' },
  ]) assert.equal(requiresApproval('mutating', exec), true, exec.name)
})

test('read-only calls stay free; always and never remain explicit modes', () => {
  for (const exec of [
    { name: 'computer_screenshot' }, { name: 'computer_uia_list' },
    { name: 'computer_render_check', arguments: {} },
    { name: 'computer_uia_scan', arguments: { max_pages: 0 } },
  ]) {
    assert.equal(requiresApproval('mutating', exec), false)
    assert.equal(requiresApproval('always', exec), true)
  }
  assert.equal(requiresApproval('never', { name: 'computer_click' }), false)
  assert.equal(requiresApproval('always', { name: 'other_tool' }), false)
})

test('capture names cannot escape the directory or name Windows devices/streams', () => {
  for (const name of ['../capture.png', '/tmp/capture.png', 'C:\\capture.png', '\\\\server\\share\\capture.png', 'a/b.png', 'a\\b.png', 'a.png:stream', 'CON.png', 'NUL.any.png', 'LPT1.png', '..', '', null]) {
    assert.throws(() => validateCaptureName(name), /simple PNG filename/)
  }
  assert.equal(validateCaptureName('capture-1.png'), 'capture-1.png')
})

test('captures use a dedicated directory and an existing image cannot be overwritten', async () => {
  const captures = new CaptureFiles()
  const png = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10, 0])
  const path = await captures.save('capture.png', png.toString('base64'))
  try {
    assert.match(basename(dirname(path)), /^dsh-captures-/)
    assert.deepEqual(await readFile(path), png)
    await assert.rejects(captures.save('capture.png', png.toString('base64')), { code: 'EEXIST' })
    assert.deepEqual(await readFile(path), png)
  } finally {
    await rm(dirname(path), { recursive: true, force: true })
  }
})

test('non-PNG data is refused before a file is created', async () => {
  await assert.rejects(new CaptureFiles().save('capture.png', Buffer.from('not png').toString('base64')), /invalid PNG/)
})
