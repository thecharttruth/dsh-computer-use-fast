import { mkdtemp, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

export function validateCaptureName(name) {
  // A filename only: no drive letters, UNC paths, traversal, NTFS streams,
  // separators, or Windows device names (even when followed by an extension).
  if (typeof name !== 'string' || !/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,119}\.png$/i.test(name) ||
      /^(con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)/i.test(name)) {
    throw new Error('save_path must be a simple PNG filename, such as capture.png; directories and device names are not allowed')
  }
  return name
}

/** One unpredictable, private capture directory per plugin instance. */
export class CaptureFiles {
  #directory

  async save(name, pngBase64) {
    validateCaptureName(name)
    if (typeof pngBase64 !== 'string' || !pngBase64) throw new Error('driver returned no capture image')
    const data = Buffer.from(pngBase64, 'base64')
    if (!data.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
      throw new Error('driver returned an invalid PNG capture')
    }
    this.#directory ??= mkdtemp(join(tmpdir(), 'dsh-captures-'))
    const path = join(await this.#directory, name)
    // Exclusive creation also refuses a pre-existing symlink or destination.
    await writeFile(path, data, { flag: 'wx', mode: 0o600 })
    return path
  }
}
