/** Unknown computer tools require approval; only audited reads are exempt. */
const READ_ONLY_TOOLS = new Set([
  'computer_screenshot', 'computer_windows', 'computer_cursor', 'computer_idle',
  'computer_uia_list', 'computer_wait', 'computer_ocr',
])

export function requiresApproval(mode, exec) {
  if (!exec.name.startsWith('computer_') || mode === 'never') return false
  if (mode === 'always') return true
  if (exec.name === 'computer_render_check') return exec.arguments?.save_path != null
  if (exec.name === 'computer_uia_scan') return exec.arguments?.max_pages !== 0
  return !READ_ONLY_TOOLS.has(exec.name)
}
