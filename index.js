/**
 * dsh-computer-use-fast — native Windows computer use for DeepSeek Harness.
 *
 * Design notes:
 * - One resident PowerShell driver (driver.ps1) holds the compiled P/Invoke
 *   surface for the whole session, so an action costs a JSON line instead of a
 *   process launch. Measured warm round trips: cursor 0.5 ms, window list
 *   2.3 ms, screenshot ~100 ms.
 * - Every coordinate the model sends is a physical desktop pixel. Screenshots
 *   report their origin and scale so image coordinates can be mapped back
 *   exactly, which is the part hand-rolled computer-use tools usually omit.
 * - The driver is the only component that touches input or the screen; this
 *   file only validates, serializes, and registers tools.
 *
 * @module dsh-computer-use-fast
 */
import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineTool } from '@deepseek-ai/dsh-tools'

export const name = 'computer-use-fast'
export const inject = ['tools']

const DRIVER_PATH = join(dirname(fileURLToPath(import.meta.url)), 'driver.ps1')
const TOOL_PREFIX = 'computer_'

/** Tools that change desktop state and therefore face the approval gate. */
const MUTATING_TOOLS = new Set([
  'computer_click', 'computer_move', 'computer_drag', 'computer_scroll',
  'computer_type', 'computer_key', 'computer_focus', 'computer_focus_force', 'computer_pin',
  'computer_batch', 'computer_uia_act', 'computer_bg_click', 'computer_bg_key',
  'computer_arrange_windows',
])

const BATCH_ACTIONS = ['click', 'move', 'drag', 'scroll', 'type', 'key', 'wait', 'focus']
const MAX_BATCH_STEPS = 24

const DEFAULTS = {
  approvalMode: 'mutating',
  focusGuard: true,
  minUserIdleMs: 0,
  maxScreenshotWidth: 1920,
  maxScreenshotHeight: 1200,
  screenshotFormat: 'png',
  jpegQuality: 80,
  requestTimeoutMs: 15000,
  driverWarmup: true,
}

function resolveConfig(raw) {
  const config = { ...DEFAULTS, ...(raw ?? {}) }
  if (!['mutating', 'always', 'never'].includes(config.approvalMode)) {
    throw new Error(`approvalMode must be "mutating", "always" or "never" (got ${JSON.stringify(config.approvalMode)})`)
  }
  if (!['png', 'jpeg'].includes(config.screenshotFormat)) {
    throw new Error(`screenshotFormat must be "png" or "jpeg" (got ${JSON.stringify(config.screenshotFormat)})`)
  }
  for (const key of ['maxScreenshotWidth', 'maxScreenshotHeight']) {
    const value = config[key]
    if (!Number.isInteger(value) || value < 320 || value > 10000) {
      throw new Error(`${key} must be an integer between 320 and 10000`)
    }
  }
  if (!Number.isInteger(config.jpegQuality) || config.jpegQuality < 10 || config.jpegQuality > 100) {
    throw new Error('jpegQuality must be an integer between 10 and 100')
  }
  if (!Number.isInteger(config.requestTimeoutMs) || config.requestTimeoutMs < 1000 || config.requestTimeoutMs > 120000) {
    throw new Error('requestTimeoutMs must be an integer between 1000 and 120000')
  }
  if (typeof config.focusGuard !== 'boolean') {
    throw new Error('focusGuard must be true or false')
  }
  if (!Number.isInteger(config.minUserIdleMs) || config.minUserIdleMs < 0 || config.minUserIdleMs > 600000) {
    throw new Error('minUserIdleMs must be an integer between 0 and 600000 (0 disables the idle gate)')
  }
  return config
}

/**
 * Input actions carry the idle requirement so the driver can refuse them at the
 * moment of the action, where the desktop state is still current.
 */
function idleGuard(config) {
  return config.minUserIdleMs > 0 ? { minIdleMs: config.minUserIdleMs } : {}
}

/**
 * One resident PowerShell process speaking newline-delimited JSON.
 *
 * Requests are serialized through a promise chain because the driver answers
 * one line at a time; a timeout kills and respawns the process so a wedged
 * driver cannot silently swallow later calls.
 */
class Driver {
  #proc = null
  #pending = new Map()
  #queue = Promise.resolve()
  #nextId = 1
  #stderr = ''
  #disposed = false
  #timeoutMs

  constructor(timeoutMs) {
    this.#timeoutMs = timeoutMs
  }

  get running() {
    return this.#proc !== null
  }

  start() {
    if (this.#proc !== null || this.#disposed) return
    const proc = spawn('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', DRIVER_PATH,
    ], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] })
    this.#proc = proc
    this.#stderr = ''
    const reader = createInterface({ input: proc.stdout })
    reader.on('line', (line) => this.#onLine(line))
    proc.stderr.on('data', (chunk) => {
      this.#stderr = (this.#stderr + chunk.toString()).slice(-4000)
    })
    proc.on('error', (error) => this.#onExit(`driver failed to start: ${error.message}`))
    proc.on('exit', (code) => this.#onExit(`driver exited (code ${code})${this.#stderr ? `: ${this.#stderr.trim().slice(-500)}` : ''}`))
  }

  #onLine(line) {
    const text = line.trim()
    if (text.length === 0) return
    let message
    try {
      message = JSON.parse(text)
    } catch {
      return
    }
    const entry = this.#pending.get(message.id)
    if (entry === undefined) return
    this.#pending.delete(message.id)
    if (message.ok) entry.resolve(message.result)
    else entry.reject(new Error(typeof message.error === 'string' ? message.error : 'driver reported an unknown error'))
  }

  #onExit(reason) {
    const entries = [...this.#pending.values()]
    this.#pending.clear()
    this.#proc = null
    for (const entry of entries) entry.reject(new Error(reason))
  }

  /** Warm the process so the TUI's first real action does not pay startup. */
  warm() {
    return this.call('hello', {})
  }

  call(action, payload = {}, signal, timeoutMs) {
    const run = this.#queue.then(() => this.#send(action, payload, signal, timeoutMs))
    this.#queue = run.then(() => undefined, () => undefined)
    return run
  }

  #send(action, payload, signal, timeoutMs) {
    if (this.#disposed) return Promise.reject(new Error('the computer-use driver has been disposed'))
    if (signal?.aborted) return Promise.reject(new Error('aborted before dispatch'))
    this.start()
    const proc = this.#proc
    const id = this.#nextId++
    // Bulk actions (a full window scan) legitimately outlast a single action.
    const limit = typeof timeoutMs === 'number' && timeoutMs > 0 ? timeoutMs : this.#timeoutMs
    return new Promise((resolve, reject) => {
      const finish = (fn, value) => {
        clearTimeout(timer)
        signal?.removeEventListener('abort', onAbort)
        fn(value)
      }
      const onAbort = () => {
        this.#pending.delete(id)
        finish(reject, new Error('aborted'))
      }
      const timer = setTimeout(() => {
        this.#pending.delete(id)
        finish(reject, new Error(`the computer-use driver did not answer "${action}" within ${limit} ms`))
        this.#kill()
      }, limit)
      signal?.addEventListener('abort', onAbort, { once: true })
      this.#pending.set(id, {
        resolve: (value) => finish(resolve, value),
        reject: (error) => finish(reject, error),
      })
      try {
        proc.stdin.write(`${JSON.stringify({ id, action, ...payload })}\n`, (error) => {
          if (error === undefined || error === null) return
          this.#pending.delete(id)
          finish(reject, new Error(`could not reach the computer-use driver: ${error.message}`))
        })
      } catch (error) {
        this.#pending.delete(id)
        finish(reject, error)
      }
    })
  }

  #kill() {
    const proc = this.#proc
    this.#proc = null
    try {
      proc?.kill()
    } catch {
      // already gone
    }
  }

  dispose() {
    if (this.#disposed) return
    this.#disposed = true
    try {
      this.#proc?.stdin.write(`${JSON.stringify({ id: this.#nextId++, action: 'exit' })}\n`)
    } catch {
      // best effort
    }
    this.#kill()
  }
}

const IMAGE_VALUE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: true,
  properties: {
    attachmentId: { type: 'string', required: true },
    mediaType: { type: 'string', enum: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'], required: true },
    bytes: { type: 'integer', required: true },
    width: { type: 'integer', required: true },
    height: { type: 'integer', required: true },
    name: { type: 'string' },
  },
}

const POINT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: true,
  properties: {
    x: { type: 'integer', required: true },
    y: { type: 'integer', required: true },
    width: { type: 'integer', required: true },
    height: { type: 'integer', required: true },
  },
}

const SCREENSHOT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    image: IMAGE_VALUE_SCHEMA,
    origin_x: { type: 'integer', required: true },
    origin_y: { type: 'integer', required: true },
    scale: { type: 'number', required: true },
    region_width: { type: 'integer', required: true },
    region_height: { type: 'integer', required: true },
    offscreen: { type: 'boolean' },
    screen: POINT_SCHEMA,
  },
}

const textOutput = (render) => ({ schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: String(value) }] })

function imageRef(image) {
  return {
    attachmentId: image.attachmentId,
    mediaType: image.mediaType,
    bytes: image.bytes,
    width: image.width,
    height: image.height,
    ...(image.name === undefined ? {} : { name: image.name }),
  }
}

function formatMapping(value) {
  const region = `${value.region_width}x${value.region_height}`
  const lines = [
    `Screenshot: ${value.image.width}x${value.image.height} px, origin (${value.origin_x}, ${value.origin_y}) on a ${region} desktop region, scale ${value.scale}.`,
  ]
  if (value.offscreen === true) {
    lines.push('Rendered offscreen with PrintWindow, so the window did not need to be visible or focused.')
  }
  if (value.scale === 1) {
    lines.push('Image pixels are desktop pixels: add the origin to an image coordinate to get the desktop coordinate.')
  } else {
    const inverse = 1 / value.scale
    lines.push(`Desktop coordinate = origin + image coordinate / ${value.scale} (multiply the image coordinate by ${inverse.toFixed(3)}).`)
  }
  lines.push(`The full virtual desktop is ${value.screen.width}x${value.screen.height} at (${value.screen.x}, ${value.screen.y}).`)
  return lines.join(' ')
}

function formatPin(pinned) {
  if (pinned === null || pinned === undefined) return 'no pinned target, so input follows whatever is foreground'
  const alive = pinned.alive ? '' : ' (window is GONE: pin a new target)'
  return `pinned target is handle ${pinned.handle} (pid ${pinned.pid})${alive} ${JSON.stringify(pinned.title)}`
}

function formatWindows(result) {
  if (result.count === 0) return 'No visible top-level windows matched.'
  const lines = [`${result.count} visible top-level window(s), largest first:`]
  for (const w of result.windows) {
    lines.push(`${w.foreground ? '*' : ' '} handle=${w.handle} pid=${w.pid} ${w.width}x${w.height} at (${w.x}, ${w.y})${w.minimized ? ' [minimized]' : ''} ${JSON.stringify(w.title)}`)
  }
  lines.push('Use a handle with computer_focus, or the rectangle with computer_screenshot.')
  return lines.join('\n')
}

function formatUiaRow(element) {
  const parts = [
    `#${element.index}`,
    `${'  '.repeat(Math.min(element.depth ?? 0, 8))}${element.type}`,
    element.name === '' ? '' : JSON.stringify(element.name),
    `${element.width}x${element.height} at (${element.x}, ${element.y})`,
    element.enabled ? '' : 'disabled',
    element.offscreen ? 'offscreen' : '',
    element.password ? 'PASSWORD' : '',
    element.value === null || element.value === undefined ? '' : `value=${JSON.stringify(element.value)}`,
    element.patterns.length === 0 ? '' : `[${element.patterns.join(',')}]`,
  ].filter((part) => part !== '')
  return parts.join(' ')
}

function formatUiaScan(result, filter) {
  const needle = typeof filter === 'string' && filter.trim() !== '' ? filter.trim().toLowerCase() : undefined
  const rows = needle === undefined
    ? result.elements
    : result.elements.filter((element) => `${element.name} ${element.type} ${element.automationId} ${element.value ?? ''}`.toLowerCase().includes(needle))
  const lines = [
    `Scanned window ${result.handle}: ${result.count} element(s), ${result.scrollContainers} scroll container(s), ${result.pagesScrolled} scroll page(s) paged through` +
    `${result.complete ? '' : ' — INCOMPLETE, the node cap was reached; raise max_nodes'}` +
    `${needle === undefined ? '' : `; ${rows.length} row(s) match ${JSON.stringify(filter)}`}.`,
  ]
  if (rows.length === 0) lines.push('No element matched that filter.')
  for (const element of rows) lines.push(formatUiaRow(element))
  return lines.join('\n')
}

function formatUiaTree(result) {
  if (result.count === 0) {
    return `Window ${result.handle} exposed no UI Automation elements. It may be a self-drawn surface (many Electron and game UIs), in which case use computer_screenshot with handle= and computer_bg_click.`
  }
  const lines = [`${result.count} UI Automation element(s) in window ${result.handle}${result.truncated ? ' (truncated; raise max_nodes or lower max_depth, or use computer_uia_scan for everything)' : ''}:`]
  for (const element of result.elements) lines.push(formatUiaRow(element))
  lines.push('Act with computer_uia_act: pass a point inside the rectangle, or the exact name, plus one of the element patterns.')
  return lines.join('\n')
}

function describeGate(exec) {
  const args = exec.arguments ?? {}
  switch (exec.name) {
    case 'computer_click':
      return `click ${args.button ?? 'left'} ${args.clicks ?? 1}x at (${args.x}, ${args.y})`
    case 'computer_move':
      return `move the pointer to (${args.x}, ${args.y})`
    case 'computer_drag':
      return `drag from (${args.from_x}, ${args.from_y}) to (${args.to_x}, ${args.to_y})`
    case 'computer_scroll':
      return `scroll ${args.amount} step(s)`
    case 'computer_type':
      return `type ${String(args.text ?? '').length} character(s) into the focused control`
    case 'computer_key':
      return `press ${Array.isArray(args.keys) ? args.keys.join('+') : 'a key'}`
    case 'computer_focus':
      return `focus window handle ${args.handle}`
    case 'computer_focus_force':
      return `force window handle ${args.handle} into the foreground`
    case 'computer_render_check':
      return `check whether window handle ${args.handle} is painting content or is blank`
    case 'computer_pin':
      return `pin the input target to window handle ${args.handle}${args.focus ? ' (taking the foreground)' : ''}`
    case 'computer_uia_act': {
      const target = args.name === undefined ? `the element at (${args.x}, ${args.y})` : `the element named ${JSON.stringify(args.name)}`
      return `${String(args.uia_action ?? 'act').replaceAll('_', ' ')} ${target} in window ${args.handle}`
    }
    case 'computer_bg_click':
      return `${args.button ?? 'left'} click at (${args.x}, ${args.y}) in window ${args.handle}`
    case 'computer_bg_key':
      return args.text === undefined
        ? `post ${Array.isArray(args.keys) ? args.keys.join('+') : 'a key'} to window ${args.handle}`
        : `post ${String(args.text).length} character(s) to window ${args.handle}`
    case 'computer_arrange_windows': {
      const count = Array.isArray(args.placements) ? args.placements.length : (Array.isArray(args.handles) ? args.handles.length : 0)
      const reserve = args.reserve_size > 0 ? `, keeping ${args.reserve_size}px clear on the ${args.reserve_side ?? 'right'}` : ''
      return `move ${count} window(s) into a ${args.layout ?? 'vertical'} layout${reserve}`
    }
    case 'computer_batch': {
      const steps = Array.isArray(args.steps) ? args.steps.length : 0
      return `run ${steps} batched desktop step(s)`
    }
    default:
      return exec.name.replace(TOOL_PREFIX, '').replaceAll('_', ' ')
  }
}

export function apply(ctx, rawConfig) {
  const config = resolveConfig(rawConfig)
  const driver = new Driver(config.requestTimeoutMs)
  ctx.effect(() => () => driver.dispose())
  if (config.driverWarmup) {
    driver.warm().catch((error) => ctx.logger?.warn?.(`[computer-use-fast] driver warm-up failed: ${error.message}`))
  }

  if (config.approvalMode !== 'never') {
    ctx.on('tools/pre-execute', async (exec, next) => {
      if (!exec.name.startsWith(TOOL_PREFIX)) return next()
      if (config.approvalMode === 'mutating' && !MUTATING_TOOLS.has(exec.name)) return next()
      return { kind: 'ask', reason: `Computer Use requests permission to ${describeGate(exec)}.` }
    })
  }

  const screenshot = defineTool({
    name: 'computer_screenshot',
    description: [
      'Capture the Windows desktop (or the foreground window) and return it as an image.',
      'The result states the image origin and scale; desktop coordinates for computer_click and friends are',
      'origin + image coordinate / scale. Prefer computer_windows and computer_cursor for cheap grounding,',
      'and capture only when you need to see pixels.',
    ].join(' '),
    parameters: {
      target: { type: 'string', enum: ['screen', 'active'], default: 'screen', description: 'screen captures the whole virtual desktop; active crops the foreground window rectangle. Ignored when handle is given.' },
      handle: { type: 'integer', description: 'Capture this window offscreen through PrintWindow: no cursor movement, no focus change, and it works while the window is occluded. Some GPU-composited apps refuse and the capture is reported as blank.' },
      max_width: { type: 'integer', default: config.maxScreenshotWidth, description: 'Maximum image width in pixels; the capture is scaled down to fit.' },
      max_height: { type: 'integer', default: config.maxScreenshotHeight, description: 'Maximum image height in pixels.' },
      format: { type: 'string', enum: ['png', 'jpeg'], default: config.screenshotFormat, description: 'jpeg is roughly 5x smaller and slightly faster; png is lossless.' },
      quality: { type: 'integer', default: config.jpegQuality, description: 'JPEG quality 10-100 when format is jpeg.' },
    },
    output: {
      schema: SCREENSHOT_SCHEMA,
      render: (_args, value) => [
        { type: 'text', text: formatMapping(value) },
        { type: 'image', attachment: imageRef(value.image) },
      ],
    },
    isConcurrencySafe: () => true,
    timeoutMs: 30000,
    async execute(args, exec) {
      const attachments = ctx.get('attachments')
      if (attachments === undefined) throw new Error('computer_screenshot needs the attachment service, which this profile does not mount; use computer_windows and computer_cursor instead')
      const target = args.target ?? 'screen'
      const maxWidth = clampInt(args.max_width ?? config.maxScreenshotWidth, 320, 10000)
      const maxHeight = clampInt(args.max_height ?? config.maxScreenshotHeight, 320, 10000)
      const format = args.format ?? config.screenshotFormat
      const quality = clampInt(args.quality ?? config.jpegQuality, 10, 100)
      const shot = await driver.call('screenshot', {
        target,
        maxWidth,
        maxHeight,
        format,
        quality,
        ...(args.handle === undefined ? {} : { handle: args.handle }),
      }, exec.signal)
      const mediaType = shot.mediaType === 'image/jpeg' ? 'image/jpeg' : 'image/png'
      if (!attachments.imageLimits.mediaTypes.includes(mediaType)) {
        throw new Error(`this deployment does not accept ${mediaType} attachments; retry with format "png"`)
      }
      const ref = await attachments.saveImage({
        data: Buffer.from(shot.base64, 'base64'),
        mediaType,
        name: `computer-screenshot.${mediaType === 'image/jpeg' ? 'jpg' : 'png'}`,
      })
      const screen = await driver.call('screen', {}, exec.signal)
      // The store may normalize or downscale further; the model needs the scale
      // that maps the image it actually sees back onto desktop pixels.
      const scale = ref.width / shot.width * shot.scale
      return {
        image: {
          attachmentId: ref.attachmentId,
          mediaType: ref.mediaType,
          bytes: ref.bytes,
          width: ref.width,
          height: ref.height,
          ...(ref.name === undefined ? {} : { name: ref.name }),
        },
        origin_x: shot.originX,
        origin_y: shot.originY,
        scale,
        region_width: shot.width,
        region_height: shot.height,
        offscreen: shot.offscreen === true,
        screen: { x: screen.screen.x, y: screen.screen.y, width: screen.screen.width, height: screen.screen.height },
      }
    },
  })

  const windows = defineTool({
    name: 'computer_windows',
    description: 'List visible top-level windows with their handle, process id, title and rectangle. Cheap grounding: prefer this over a screenshot when you only need to know what is open and where it sits.',
    parameters: {
      filter: { type: 'string', description: 'Case-insensitive substring match on the window title.' },
      limit: { type: 'integer', default: 40, description: 'Maximum rows to return (1-200), largest window first.' },
    },
    output: textOutput(),
    isConcurrencySafe: () => true,
    timeoutMs: 15000,
    async execute(args, exec) {
      const result = await driver.call('windows', { filter: args.filter, limit: clampInt(args.limit ?? 40, 1, 200) }, exec.signal)
      return formatWindows(result)
    },
  })

  const cursor = defineTool({
    name: 'computer_cursor',
    description: 'Report the pointer position, the virtual desktop rectangle, the foreground window title, how long the user has been idle, and the pinned input target. Use before clicking to confirm the cursor is where you think it is.',
    parameters: {},
    output: textOutput(),
    isConcurrencySafe: () => true,
    timeoutMs: 15000,
    async execute(_args, exec) {
      const result = await driver.call('idle', {}, exec.signal)
      const { cursor: point, screen, foreground, idleMs, pinned } = result
      return `Cursor at (${point.x}, ${point.y}). Virtual desktop ${screen.width}x${screen.height} at (${screen.x}, ${screen.y}). Foreground window: ${JSON.stringify(foreground)}. User idle for ${idleMs} ms. ${formatPin(pinned)}.`
    },
  })

  const idle = defineTool({
    name: 'computer_idle',
    description: [
      'Report how long the user has been idle, which window is foreground, and which window (if any) input is pinned to.',
      'Poll this before starting a run so you do not fight the user for the pointer and keyboard.',
    ].join(' '),
    parameters: {},
    output: textOutput(),
    isConcurrencySafe: () => true,
    timeoutMs: 15000,
    async execute(_args, exec) {
      const result = await driver.call('idle', {}, exec.signal)
      const disabled = config.minUserIdleMs === 0
      const verdict = disabled
        ? 'The idle gate is disabled (minUserIdleMs is 0), so input actions are not blocked while the user works.'
        : `Input actions are refused until the user has been idle for ${config.minUserIdleMs} ms.`
      return `User idle for ${result.idleMs} ms. Foreground window: ${JSON.stringify(result.foreground)}. Pinned target: ${formatPin(result.pinned)}. ${verdict}`
    },
  })

  const pin = defineTool({
    name: 'computer_pin',
    description: [
      'Claim a window as the input target. While pinned, every input action verifies that this window is still foreground;',
      'if the user takes over, the action is refused instead of typing into their window. Use after computer_windows.',
    ].join(' '),
    parameters: {
      handle: { type: 'integer', required: true, description: 'Window handle from computer_windows.' },
      focus: { type: 'boolean', default: false, description: 'Also bring the window to the foreground now.' },
    },
    output: textOutput(),
    timeoutMs: 15000,
    async execute(args, exec) {
      const result = await driver.call('pin', { handle: args.handle, focus: args.focus === true }, exec.signal)
      const state = formatPin(result.pinned)
      return result.foreground
        ? `Pinned and focused. ${state}.`
        : `Pinned. ${state}. It is not foreground right now, so the next input action will be refused until it is (use computer_focus).`
    },
  })

  const release = defineTool({
    name: 'computer_release',
    description: 'Release the pinned input target so actions follow whatever window is foreground. Does not change focus.',
    parameters: {},
    output: textOutput(),
    timeoutMs: 15000,
    async execute(_args, exec) {
      const result = await driver.call('unpin', {}, exec.signal)
      return result.released === null || result.released === undefined
        ? 'No target was pinned.'
        : `Released the pin on handle ${result.released.handle}. Actions now follow the foreground window.`
    },
  })

  const click = defineTool({
    name: 'computer_click',
    description: 'Move the pointer to a desktop coordinate and click. Coordinates are physical desktop pixels from computer_screenshot or computer_windows.',
    parameters: {
      x: { type: 'integer', required: true },
      y: { type: 'integer', required: true },
      button: { type: 'string', enum: ['left', 'right', 'middle'], default: 'left' },
      clicks: { type: 'integer', default: 1, description: '1, 2 (double click) or 3.' },
    },
    output: textOutput(),
    timeoutMs: 15000,
    async execute(args, exec) {
      const button = args.button ?? 'left'
      const clicks = clampInt(args.clicks ?? 1, 1, 3)
      const result = await driver.call('click', { x: args.x, y: args.y, button, clicks, ...idleGuard(config) }, exec.signal)
      return `Clicked ${result.button} ${result.clicks}x at (${result.x}, ${result.y}).`
    },
  })

  const move = defineTool({
    name: 'computer_move',
    description: 'Move the pointer to a desktop coordinate without clicking. Useful to reveal hover menus or to park the pointer before a screenshot.',
    parameters: {
      x: { type: 'integer', required: true },
      y: { type: 'integer', required: true },
    },
    output: textOutput(),
    timeoutMs: 15000,
    async execute(args, exec) {
      await driver.call('move', { x: args.x, y: args.y, ...idleGuard(config) }, exec.signal)
      return `Pointer moved to (${args.x}, ${args.y}).`
    },
  })

  const drag = defineTool({
    name: 'computer_drag',
    description: 'Press a mouse button at one desktop coordinate, move smoothly to another, and release. The intermediate motion matters for applications with drag thresholds.',
    parameters: {
      from_x: { type: 'integer', required: true },
      from_y: { type: 'integer', required: true },
      to_x: { type: 'integer', required: true },
      to_y: { type: 'integer', required: true },
      duration_ms: { type: 'integer', default: 250, description: 'Motion duration 0-5000 ms.' },
      button: { type: 'string', enum: ['left', 'right', 'middle'], default: 'left' },
    },
    output: textOutput(),
    timeoutMs: 15000,
    async execute(args, exec) {
      const durationMs = clampInt(args.duration_ms ?? 250, 0, 5000)
      const button = args.button ?? 'left'
      await driver.call('drag', {
        fromX: args.from_x, fromY: args.from_y, toX: args.to_x, toY: args.to_y, durationMs, button, ...idleGuard(config),
      }, exec.signal)
      return `Dragged ${button} from (${args.from_x}, ${args.from_y}) to (${args.to_x}, ${args.to_y}) over ${durationMs} ms.`
    },
  })

  const scroll = defineTool({
    name: 'computer_scroll',
    description: 'Scroll the wheel at the pointer, or at a given coordinate. Positive scrolls up, negative scrolls down.',
    parameters: {
      amount: { type: 'integer', required: true, description: 'Non-zero wheel steps, -50 to 50.' },
      x: { type: 'integer', description: 'Optional coordinate to move the pointer to first.' },
      y: { type: 'integer' },
    },
    output: textOutput(),
    timeoutMs: 15000,
    async execute(args, exec) {
      const amount = clampInt(args.amount, -50, 50)
      if (amount === 0) throw new Error('amount must not be zero')
      const payload = { amount, ...idleGuard(config) }
      if (args.x !== undefined && args.y !== undefined) {
        payload.x = args.x
        payload.y = args.y
      }
      await driver.call('scroll', payload, exec.signal)
      return `Scrolled ${amount > 0 ? 'up' : 'down'} ${Math.abs(amount)} step(s).`
    },
  })

  const type = defineTool({
    name: 'computer_type',
    description: 'Type text into the focused control as real Unicode keystrokes. Newlines and tabs become Enter and Tab. Nothing is written to the clipboard.',
    parameters: {
      text: { type: 'string', required: true, description: 'Up to 20000 characters.' },
    },
    output: textOutput(),
    timeoutMs: 30000,
    async execute(args, exec) {
      const result = await driver.call('type', { text: args.text, ...idleGuard(config) }, exec.signal)
      return `Typed ${result.characters} character(s).`
    },
  })

  const key = defineTool({
    name: 'computer_key',
    description: 'Press a key or chord such as CTRL+L or ALT+F4 in the focused control. The Windows key and CTRL+ALT+DELETE are refused.',
    parameters: {
      keys: { type: 'array', items: { type: 'string' }, required: true, description: 'One to four key names, e.g. ["CTRL","L"] or ["ENTER"].' },
    },
    output: textOutput(),
    timeoutMs: 15000,
    async execute(args, exec) {
      const result = await driver.call('key', { keys: args.keys, ...idleGuard(config) }, exec.signal)
      return `Pressed ${result.keys.join('+')}.`
    },
  })

  const focus = defineTool({
    name: 'computer_focus',
    description: 'Bring a window to the foreground by handle from computer_windows, restoring it first if minimized, and pin input to it so later actions are refused if the user takes the foreground back.',
    parameters: {
      handle: { type: 'integer', required: true, description: 'Window handle reported by computer_windows.' },
      pin: { type: 'boolean', default: config.focusGuard, description: 'Pin input to this window until computer_release. Defaults to the deployment focusGuard setting.' },
    },
    output: textOutput(),
    timeoutMs: 15000,
    async execute(args, exec) {
      const pinTarget = args.pin ?? config.focusGuard
      const result = await driver.call('focus', { handle: args.handle, pin: pinTarget }, exec.signal)
      const pinNote = pinTarget ? ` Input is pinned to it: ${formatPin(result.pinned)}.` : ' Input is not pinned, so later actions follow whatever is foreground.'
      return result.focused
        ? `Focused handle ${args.handle} (foreground now ${JSON.stringify(result.foreground)}).${pinNote}`
        : `Windows refused the focus request for handle ${args.handle}; the foreground window is still ${JSON.stringify(result.foreground)}. A window may refuse focus while another owns it.${pinNote}`
    },
  })

  const focusForce = defineTool({
    name: 'computer_focus_force',
    description: [
      'Take the foreground for a window using the full Windows foreground-transfer sequence, instead of the single SetForegroundWindow call computer_focus makes.',
      'Windows only lets the thread that currently owns the foreground hand it away, so this attaches to the foreground thread, raises the window, then nudges ALT to clear the foreground lock, and verifies the result with retries.',
      'Use it when computer_focus reports that Windows refused the request (a browser, overlay or fullscreen app holding the foreground).',
    ].join(' '),
    parameters: {
      handle: { type: 'integer', required: true, description: 'Window handle reported by computer_windows.' },
      attempts: { type: 'integer', default: 3, description: 'How many transfer attempts to make before reporting failure (1-10).' },
      pin: { type: 'boolean', default: config.focusGuard, description: 'Pin input to this window once it holds the foreground.' },
    },
    output: textOutput(),
    timeoutMs: 20000,
    async execute(args, exec) {
      const pinTarget = args.pin ?? config.focusGuard
      const result = await driver.call('focus-force', { handle: args.handle, attempts: args.attempts, pin: pinTarget }, exec.signal)
      const pinNote = pinTarget ? ` Input is pinned to it: ${formatPin(result.pinned)}.` : ''
      return result.focused
        ? `Took the foreground for handle ${args.handle} on attempt ${result.attempts}.${pinNote}`
        : `Could not take the foreground for handle ${args.handle} after ${result.attempts} attempt(s); the foreground window is still ${JSON.stringify(result.foreground)}. Something is holding the foreground lock - a fullscreen app, an overlay, or an elevation prompt.${pinNote}`
    },
  })

  const renderCheck = defineTool({
    name: 'computer_render_check',
    description: [
      'Capture a window offscreen and report whether it is actually painting content or is a blank surface.',
      'Returns a verdict (rendered, blank-white, blank-black, blank-uniform, blank-near-uniform, capture-refused) plus pixel statistics and whether the window holds the foreground.',
      'Use it when a window looks empty: computer_screenshot cannot distinguish "the application drew nothing" from "Windows refused the offscreen capture", because both surface as the same error.',
      'Pass save_path to also write the capture to a PNG for visual inspection.',
    ].join(' '),
    parameters: {
      handle: { type: 'integer', required: true, description: 'Window handle reported by computer_windows.' },
      save_path: { type: 'string', description: 'Optional PNG path to write the capture to, for visual inspection.' },
    },
    output: textOutput(),
    timeoutMs: 20000,
    async execute(args, exec) {
      const result = await driver.call('render-check', { handle: args.handle, savePath: args.save_path }, exec.signal)
      const pct = (value) => `${(Number(value) * 100).toFixed(1)}%`
      const lines = [
        `Window ${args.handle} (${result.width}x${result.height}) verdict: ${result.verdict}.`,
        `Capture ${result.captured ? `succeeded via ${result.method}` : `was refused (${result.method})`}; foreground now: ${result.focus ? 'yes' : 'no'}.`,
        `Pixels: ${result.uniqueColors} distinct colour(s), mean luma ${result.meanLuma}, std ${result.stdLuma}, white ${pct(result.whiteFraction)}, black ${pct(result.blackFraction)}.`,
      ]
      if (String(result.verdict).startsWith('blank')) {
        lines.push('A blank verdict on a window that should have content usually means either the application failed to build its resource dictionaries (for example a missing theme or image assembly), or it is GPU-composited and needs the foreground. Try computer_focus_force first, then computer_screenshot with target=active.')
      }
      if (result.savedPath) lines.push(`Capture written to ${result.savedPath}.`)
      return lines.join('\n')
    },
  })

  const uiaList = defineTool({
    name: 'computer_uia_list',
    description: [
      "List a window's UI Automation elements: index, depth, name, control type, automation id, screen rectangle, enabled/offscreen/password flags, current value, and the patterns each element supports.",
      'This never moves the cursor and never changes focus, so it can be read while the user keeps working.',
      'Prefer it to screenshots for finding controls; the reported patterns tell you which computer_uia_act action will work.',
    ].join(' '),
    parameters: {
      handle: { type: 'integer', required: true, description: 'Window handle from computer_windows.' },
      max_depth: { type: 'integer', default: 6, description: 'Tree depth 1-20.' },
      max_nodes: { type: 'integer', default: 300, description: 'Element cap 1-1000.' },
    },
    output: textOutput(),
    isConcurrencySafe: () => true,
    timeoutMs: 60000,
    async execute(args, exec) {
      const result = await driver.call('uiaList', {
        handle: args.handle,
        maxDepth: clampInt(args.max_depth ?? 6, 1, 20),
        maxNodes: clampInt(args.max_nodes ?? 300, 1, 1000),
      }, exec.signal)
      return formatUiaTree(result)
    },
  })

  const uiaScan = defineTool({
    name: 'computer_uia_scan',
    description: [
      'Read EVERYTHING in a window: the whole accessibility tree with no depth cut-off, plus every scrollable panel paged through so settings that',
      'live below the fold are included. Use this instead of computer_uia_list when you must not miss any control.',
      'It restores each scroll container to the top afterwards, never moves the cursor, and never changes focus.',
      'The result says whether the scan was complete or hit its node cap.',
    ].join(' '),
    parameters: {
      handle: { type: 'integer', required: true, description: 'Window handle from computer_windows.' },
      max_nodes: { type: 'integer', default: 1500, description: 'Element cap 50-5000 across the whole window.' },
      max_pages: { type: 'integer', default: 20, description: 'Scroll pages to page through per container, 0-100 (0 disables scrolling).' },
      filter: { type: 'string', description: 'Optional case-insensitive substring; only matching rows are printed (the scan still reads everything).' },
    },
    output: textOutput(),
    timeoutMs: 120000,
    async execute(args, exec) {
      const result = await driver.call('uiaScan', {
        handle: args.handle,
        maxNodes: clampInt(args.max_nodes ?? 1500, 50, 5000),
        maxPages: clampInt(args.max_pages ?? 20, 0, 100),
      }, exec.signal, 110000)
      return formatUiaScan(result, args.filter)
    },
  })

  const uiaAct = defineTool({
    name: 'computer_uia_act',
    description: [
      'Act on a UI Automation element without moving the cursor and without stealing focus: invoke a button, write a text field, select/toggle/expand a control, focus it, or scroll it into view.',
      'Address the element by screen x/y (for example the centre of a rectangle from computer_uia_list) or by exact name.',
      'The action must match a pattern the element reports; otherwise the error lists what it does support. Password fields are refused.',
    ].join(' '),
    parameters: {
      handle: { type: 'integer', required: true, description: 'Window the element belongs to; an element living in another window is refused.' },
      uia_action: { type: 'string', required: true, enum: ['invoke', 'set_value', 'select', 'toggle', 'expand', 'collapse', 'scroll_into_view', 'focus', 'scroll_up', 'scroll_down', 'scroll_page_up', 'scroll_page_down', 'scroll_left', 'scroll_right'] },
      x: { type: 'integer', description: 'Screen x of a point inside the element rectangle.' },
      y: { type: 'integer', description: 'Screen y of a point inside the element rectangle.' },
      name: { type: 'string', description: 'Exact element name, used when x/y are omitted.' },
      value: { type: 'string', description: 'Text to write for set_value.' },
    },
    output: textOutput(),
    timeoutMs: 30000,
    async execute(args, exec) {
      if ((args.x === undefined) !== (args.y === undefined)) throw new Error('provide both x and y, or neither')
      if (args.x === undefined && args.name === undefined) throw new Error('provide x/y or a name')
      const result = await driver.call('uiaAct', {
        handle: args.handle,
        uiaAction: args.uia_action,
        ...(args.x === undefined ? {} : { x: args.x, y: args.y }),
        ...(args.name === undefined ? {} : { name: args.name }),
        ...(args.value === undefined ? {} : { value: args.value }),
      }, exec.signal)
      const suffix = result.characters === undefined ? '' : ` (${result.characters} character(s))`
      return `${result.action} through ${result.usedPattern} on ${result.element}${suffix}.`
    },
  })

  const bgClick = defineTool({
    name: 'computer_bg_click',
    description: [
      'Post a mouse click straight to a window, addressed by handle: the physical cursor does not move and focus does not change, so this is safe to use while the user keeps working.',
      'Delivery is asynchronous and unverified. Classic Win32, WPF and WinForms controls usually respond; Electron/Chromium apps, UWP and games often ignore posted messages.',
      'Confirm the effect afterwards with computer_screenshot handle= or computer_uia_list, and fall back to computer_click (which does move the pointer and needs the window focused) if nothing happened.',
    ].join(' '),
    parameters: {
      handle: { type: 'integer', required: true, description: 'Target window handle from computer_windows.' },
      x: { type: 'integer', required: true, description: 'X in screen coordinates, or in client coordinates when client is true.' },
      y: { type: 'integer', required: true },
      button: { type: 'string', enum: ['left', 'right', 'middle'], default: 'left' },
      client: { type: 'boolean', default: false, description: 'Treat x/y as client-area coordinates instead of screen coordinates.' },
    },
    output: textOutput(),
    timeoutMs: 15000,
    async execute(args, exec) {
      const result = await driver.call('bgClick', {
        handle: args.handle,
        x: args.x,
        y: args.y,
        button: args.button ?? 'left',
        client: args.client === true,
      }, exec.signal)
      return `Posted a ${result.button} click at client (${result.clientX}, ${result.clientY}) of window ${args.handle}. Delivery is not confirmed; check the result before assuming it worked.`
    },
  })

  const bgKey = defineTool({
    name: 'computer_bg_key',
    description: [
      'Post text or a key chord directly to a window, addressed by handle, without moving the cursor or changing focus.',
      'Provide either text (posted character by character) or keys (a chord such as ["CTRL","S"]), never both.',
      'As with computer_bg_click, delivery is asynchronous and unverified and some applications ignore posted input; confirm the effect afterwards.',
    ].join(' '),
    parameters: {
      handle: { type: 'integer', required: true, description: 'Target window handle from computer_windows.' },
      text: { type: 'string', description: 'Text to post as characters (up to 20000).' },
      keys: { type: 'array', items: { type: 'string' }, description: 'One to four key names for a chord.' },
    },
    output: textOutput(),
    timeoutMs: 30000,
    async execute(args, exec) {
      if (args.text === undefined && args.keys === undefined) throw new Error('provide text or keys')
      if (args.text !== undefined && args.keys !== undefined) throw new Error('provide text or keys, not both')
      const payload = { handle: args.handle }
      if (args.text !== undefined) payload.text = args.text
      else payload.keys = args.keys
      const result = await driver.call('bgKey', payload, exec.signal)
      return result.mode === 'text'
        ? `Posted ${result.characters} character(s) to window ${args.handle}. Delivery is not confirmed.`
        : `Posted ${result.keys.join('+')} to window ${args.handle}. Delivery is not confirmed.`
    },
  })

  const arrange = defineTool({
    name: 'computer_arrange_windows',
    description: [
      'Move and resize windows by handle so the agent and the user can work at the same time instead of one covering the other.',
      'Layouts: vertical (side by side), horizontal (stacked) or grid. Use reserve_side with reserve_size to keep a strip of the screen',
      'clear for the human, and the agent will lay out only inside the remaining area.',
      'This never activates a window or changes z-order: focus and the cursor stay exactly where they were.',
      'Pass placements instead of handles to set exact rectangles.',
    ].join(' '),
    parameters: {
      handles: { type: 'array', items: { type: 'integer' }, description: '1-6 window handles from computer_windows, arranged in the given order.' },
      layout: { type: 'string', enum: ['vertical', 'horizontal', 'grid'], default: 'vertical' },
      gap: { type: 'integer', default: 8, description: 'Pixels between windows, 0-200.' },
      reserve_side: { type: 'string', enum: ['none', 'left', 'right', 'top', 'bottom'], default: 'none', description: 'Screen edge to keep clear for the user.' },
      reserve_size: { type: 'integer', default: 0, description: 'Pixels of that edge to keep clear, 0-3000.' },
      placements: {
        type: 'array',
        description: 'Explicit rectangles, overriding handles and layout.',
        items: {
          type: 'object',
          additionalProperties: false,
          properties: {
            handle: { type: 'integer', required: true },
            x: { type: 'integer', required: true },
            y: { type: 'integer', required: true },
            width: { type: 'integer', required: true },
            height: { type: 'integer', required: true },
          },
        },
      },
    },
    output: textOutput(),
    timeoutMs: 20000,
    async execute(args, exec) {
      const screen = await driver.call('screen', {}, exec.signal)
      const bounds = screen.screen
      let placements = []

      const explicit = Array.isArray(args.placements) ? args.placements : []
      if (explicit.length > 0) {
        if (explicit.length > 6) throw new Error('placements is limited to 6 windows')
        placements = explicit.map((entry) => ({
          handle: clampInt(entry.handle, 1, Number.MAX_SAFE_INTEGER),
          x: clampInt(entry.x, -32000, 32000),
          y: clampInt(entry.y, -32000, 32000),
          width: clampInt(entry.width, 64, 32000),
          height: clampInt(entry.height, 64, 32000),
        }))
      } else {
        const handles = Array.isArray(args.handles) ? args.handles : []
        if (handles.length === 0) throw new Error('provide handles (from computer_windows) or explicit placements')
        if (handles.length > 6) throw new Error('handles is limited to 6 windows')
        const gap = clampInt(args.gap ?? 8, 0, 200)
        const reserveSize = clampInt(args.reserve_size ?? 0, 0, 3000)
        const reserveSide = args.reserve_side ?? 'none'
        const area = { x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height }
        if (reserveSide !== 'none' && reserveSize > 0) {
          if (reserveSize > area.width - 320 && (reserveSide === 'left' || reserveSide === 'right')) {
            throw new Error(`reserve_size ${reserveSize} leaves no usable width in ${area.width}`)
          }
          if (reserveSide === 'left') { area.x += reserveSize; area.width -= reserveSize }
          else if (reserveSide === 'right') { area.width -= reserveSize }
          else if (reserveSide === 'top') { area.y += reserveSize; area.height -= reserveSize }
          else if (reserveSide === 'bottom') { area.height -= reserveSize }
        }
        const count = handles.length
        const layout = args.layout ?? 'vertical'
        const columns = layout === 'vertical' ? count : layout === 'horizontal' ? 1 : Math.ceil(Math.sqrt(count))
        const rows = Math.ceil(count / columns)
        const cellWidth = Math.floor((area.width - gap * (columns - 1)) / columns)
        const cellHeight = Math.floor((area.height - gap * (rows - 1)) / rows)
        if (cellWidth < 64 || cellHeight < 64) throw new Error('that layout has no room; fewer windows or a smaller reserve_size is needed')
        placements = handles.map((handle, index) => {
          const column = index % columns
          const row = Math.floor(index / columns)
          return {
            handle: clampInt(handle, 1, Number.MAX_SAFE_INTEGER),
            x: area.x + column * (cellWidth + gap),
            y: area.y + row * (cellHeight + gap),
            width: cellWidth,
            height: cellHeight,
          }
        })
      }

      const result = await driver.call('arrange', { windows: placements }, exec.signal)
      const lines = []
      let moved = 0
      for (const entry of result.windows) {
        if (entry.ok === false) {
          lines.push(`handle ${entry.handle}: FAILED (${entry.error ?? 'the window refused the move'})`)
          continue
        }
        moved++
        lines.push(`handle ${entry.handle} -> (${entry.x}, ${entry.y}) ${entry.width}x${entry.height}`)
      }
      const reserveNote = (args.reserve_size ?? 0) > 0 && (args.reserve_side ?? 'none') !== 'none'
        ? ` ${args.reserve_size}px on the ${args.reserve_side} was left untouched for the user.`
        : ''
      return `Moved ${moved} of ${result.count} window(s) without changing focus or z-order:${reserveNote}\n${lines.join('\n')}`
    },
  })

  const wait = defineTool({
    name: 'computer_wait',
    description: 'Wait briefly for an application to catch up before observing or acting again.',
    parameters: {
      ms: { type: 'integer', default: 400, description: '0-10000 ms.' },
    },
    output: textOutput(),
    timeoutMs: 15000,
    async execute(args, exec) {
      const ms = clampInt(args.ms ?? 400, 0, 10000)
      await sleep(ms, exec.signal)
      return `Waited ${ms} ms.`
    },
  })

  const batch = defineTool({
    name: 'computer_batch',
    description: [
      'Run up to 24 desktop steps in one call, back to back, without a model round trip between them.',
      'Each step is {action, ...}: click{x,y,button?,clicks?}, move{x,y}, drag{from_x,from_y,to_x,to_y,duration_ms?},',
      'scroll{amount,x?,y?}, type{text}, key{keys}, wait{ms}, focus{handle}.',
      'Execution stops at the first failure and reports which step failed. Use this for repetitive sequences such as',
      'filling a form or stepping through a list; use the single-step tools when you want to observe between actions.',
    ].join(' '),
    parameters: {
      steps: {
        type: 'array',
        required: true,
        description: `1-${MAX_BATCH_STEPS} steps, executed in order.`,
        items: {
          type: 'object',
          additionalProperties: false,
          properties: {
            action: { type: 'string', enum: BATCH_ACTIONS, required: true },
            x: { type: 'integer' },
            y: { type: 'integer' },
            button: { type: 'string', enum: ['left', 'right', 'middle'] },
            clicks: { type: 'integer' },
            from_x: { type: 'integer' },
            from_y: { type: 'integer' },
            to_x: { type: 'integer' },
            to_y: { type: 'integer' },
            duration_ms: { type: 'integer' },
            amount: { type: 'integer' },
            text: { type: 'string' },
            keys: { type: 'array', items: { type: 'string' } },
            ms: { type: 'integer' },
            handle: { type: 'integer' },
          },
        },
      },
    },
    output: textOutput(),
    timeoutMs: 120000,
    async execute(args, exec) {
      const steps = args.steps ?? []
      if (!Array.isArray(steps) || steps.length === 0) throw new Error('steps must contain at least one step')
      if (steps.length > MAX_BATCH_STEPS) throw new Error(`steps is limited to ${MAX_BATCH_STEPS} entries (got ${steps.length})`)
      const done = []
      for (let index = 0; index < steps.length; index++) {
        const step = steps[index] ?? {}
        try {
          done.push(`${index + 1}. ${await runStep(step, driver, exec.signal, idleGuard(config))}`)
        } catch (error) {
          throw new Error(`batch stopped at step ${index + 1} of ${steps.length} (${done.length} step(s) completed): ${error.message}\n${done.join('\n')}`)
        }
      }
      return `Completed ${steps.length} step(s):\n${done.join('\n')}`
    },
  })

  const ocrRead = defineTool({
    name: 'computer_ocr',
    description: [
      'Read the TEXT displayed in a window without focusing it or moving the cursor.',
      'Captures the window offscreen through PrintWindow and runs the built-in Windows OCR engine (Windows.Media.Ocr) over the capture.',
      'Use this to harvest numbers or labels from panels that expose no UI Automation tree - grids, charts and statistics readouts that render as pixels only.',
      'It is non-invasive: safe to run while the user is working. Returns plain text lines, so parse digits out rather than expecting structure.',
    ].join(' '),
    parameters: {
      handle: { type: 'integer', required: true, description: 'Window handle from computer_windows. Captured offscreen, so it need not be visible or focused.' },
    },
    output: {
      schema: { type: 'object', properties: { handle: { type: 'integer' }, lineCount: { type: 'integer' }, text: { type: 'string' } }, required: ['handle', 'lineCount', 'text'], additionalProperties: false },
      render(_args, value) {
        const body = value.text.length > 0 ? value.text : '(no text recognised)'
        return [{ type: 'text', text: `OCRed ${value.lineCount} line(s) from window ${value.handle}:${String.fromCharCode(10)}${body}` }]
      },
    },
    isConcurrencySafe: () => true,
    timeoutMs: 60000,
    async execute(args, exec) {
      return driver.call('ocr', { handle: clampInt(args.handle, 1, Number.MAX_SAFE_INTEGER) }, exec.signal)
    },
  })
  for (const tool of [screenshot, windows, cursor, idle, click, move, drag, scroll, type, key, focus, focusForce, renderCheck, pin, release, uiaList, uiaScan, uiaAct, bgClick, bgKey, arrange, wait, batch, ocrRead]) {
    ctx.tools.register(tool)
  }
}

async function runStep(step, driver, signal, guard = {}) {
  switch (step.action) {
    case 'click': {
      const result = await driver.call('click', {
        x: step.x, y: step.y, button: step.button ?? 'left', clicks: clampInt(step.clicks ?? 1, 1, 3), ...guard,
      }, signal)
      return `click ${result.button} ${result.clicks}x at (${result.x}, ${result.y})`
    }
    case 'move':
      await driver.call('move', { x: step.x, y: step.y, ...guard }, signal)
      return `move to (${step.x}, ${step.y})`
    case 'drag': {
      const durationMs = clampInt(step.duration_ms ?? 250, 0, 5000)
      await driver.call('drag', {
        fromX: step.from_x, fromY: step.from_y, toX: step.to_x, toY: step.to_y,
        durationMs, button: step.button ?? 'left', ...guard,
      }, signal)
      return `drag (${step.from_x}, ${step.from_y}) -> (${step.to_x}, ${step.to_y})`
    }
    case 'scroll': {
      const amount = clampInt(step.amount, -50, 50)
      if (amount === 0) throw new Error('scroll amount must not be zero')
      const payload = { amount, ...guard }
      if (step.x !== undefined && step.y !== undefined) {
        payload.x = step.x
        payload.y = step.y
      }
      await driver.call('scroll', payload, signal)
      return `scroll ${amount}`
    }
    case 'type': {
      const result = await driver.call('type', { text: step.text, ...guard }, signal)
      return `type ${result.characters} character(s)`
    }
    case 'key': {
      const result = await driver.call('key', { keys: step.keys, ...guard }, signal)
      return `key ${result.keys.join('+')}`
    }
    case 'wait': {
      const ms = clampInt(step.ms ?? 400, 0, 10000)
      await sleep(ms, signal)
      return `wait ${ms} ms`
    }
    case 'focus': {
      const result = await driver.call('focus', { handle: step.handle }, signal)
      return `focus ${step.handle} (${result.focused ? 'ok' : 'refused'})`
    }
    default:
      throw new Error(`unsupported batch action: ${JSON.stringify(step.action)}`)
  }
}

function clampInt(value, min, max) {
  const number = Number(value)
  if (!Number.isFinite(number)) throw new Error(`expected a number, got ${JSON.stringify(value)}`)
  const rounded = Math.trunc(number)
  if (rounded < min || rounded > max) throw new Error(`value ${rounded} is outside the allowed range ${min}..${max}`)
  return rounded
}

function sleep(ms, signal) {
  if (ms <= 0) return Promise.resolve()
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort)
      resolve()
    }, ms)
    const onAbort = () => {
      clearTimeout(timer)
      reject(new Error('aborted'))
    }
    signal?.addEventListener('abort', onAbort, { once: true })
  })
}
