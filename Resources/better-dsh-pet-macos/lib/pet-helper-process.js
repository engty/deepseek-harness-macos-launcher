import { spawn, spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join, resolve } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const packageRoot = resolve(here, '..')
const defaultHelperMain = resolve(packageRoot, 'runtime', 'electron-helper', 'main.js')

/**
 * 解析 Electron 可执行文件。
 * 优先级：
 *   1. options.electronPath / DSH_PET_ELECTRON_PATH
 *   2. App 自己的 DSH_HOME/electron 目录
 *
 * Electron 不从系统全局 npm 或 /Applications 解析，避免桌宠把用户的
 * 全局环境当作运行时，也避免不同 Electron 版本造成不可复现的行为。
 */
function resolveElectronPath(candidates = []) {
  const seen = new Set()
  const list = []
  const push = (value) => {
    if (!value || seen.has(value)) return
    seen.add(value)
    list.push(value)
  }
  for (const value of candidates) push(value)
  if (process.env.DSH_PET_ELECTRON_PATH) push(process.env.DSH_PET_ELECTRON_PATH)
  // 只从当前 Harness 的私有 DSH_HOME 解析，绝不依赖用户全局安装。
  const home = process.env.DSH_HOME || join(process.env.USERPROFILE || process.env.HOME || '', '.dsh')
  const localCandidates = platformCandidates(home)
  for (const candidate of localCandidates) push(candidate)
  if (!list.some((value) => existsSync(value))) {
    const ensured = ensureElectron()
    if (ensured) push(ensured)
  }
  return list.find((value) => existsSync(value))
}

/**
 * 按当前平台返回常见 Electron 安装位置。
 * macOS：当前 Harness 私有 DSH_HOME/electron/Electron.app/...
 */
function platformCandidates(home) {
  if (process.platform === 'darwin') {
    const appExe = join('Electron.app', 'Contents', 'MacOS', 'Electron')
    return [
      join(home, 'electron', appExe),
    ]
  }
  if (process.platform === 'win32') {
    return [
      join(home, 'electron', 'electron.exe'),
      join(process.env.APPDATA || '', 'npm', 'node_modules', 'electron', 'dist', 'electron.exe'),
      join(process.env.USERPROFILE || '', 'AppData', 'Roaming', 'npm', 'node_modules', 'electron', 'dist', 'electron.exe'),
      join(process.env.LOCALAPPDATA || '', 'Programs', 'Electron', 'electron.exe'),
      'C:/Program Files/Electron/electron.exe',
      'C:/Program Files (x86)/Electron/electron.exe',
    ]
  }
  // linux 兜底
  return [
    join(home, 'electron', 'electron'),
    '/usr/local/bin/electron',
    '/usr/bin/electron',
  ]
}

function ensureElectron() {
  const script = resolve(packageRoot, 'scripts', 'ensure-electron.mjs')
  if (!existsSync(script)) return undefined
  console.log('[better-dsh-pet] Electron not found, running ensure-electron.mjs ...')
  const result = spawnSync(process.execPath, [script], {
    stdio: 'inherit',
    timeout: 10 * 60 * 1000,
  })
  if (result.status !== 0) return undefined
  const home = process.env.DSH_HOME || join(process.env.USERPROFILE || process.env.HOME || '', '.dsh')
  const exe = join(home, 'electron', process.platform === 'darwin'
    ? join('Electron.app', 'Contents', 'MacOS', 'Electron')
    : process.platform === 'win32' ? 'electron.exe' : 'electron')
  return existsSync(exe) ? exe : undefined
}

function defaultLaunch(options = {}) {
  const electronPath = resolveElectronPath([options.electronPath])
  if (!electronPath) {
    throw new Error('better-dsh-pet: cannot resolve Electron executable. Set DSH_PET_ELECTRON_PATH or install electron.')
  }
  const helperPath = options.helperPath || defaultHelperMain
  return { command: electronPath, args: [helperPath] }
}

/**
 * 桌面 Helper 进程管理器。
 *
 * 新架构下 Helper 不再通过 stdin 协议通信，而是轮询宿主暴露的
 * /plugins/better-dsh-pet/status HTTP 端点；因此这里只负责拉起/守护 Electron 进程。
 */
export class HelperProcess {
  constructor(options = {}, logger = console) {
    this.options = options
    this.logger = logger
    this.child = undefined
    this.stopping = false
    this.restartSuppressed = false
    this.restartTimer = undefined
  }

  start() {
    if (this.child || this.stopping || this.restartSuppressed) return this.child
    const helperPath = this.options.helperPath || defaultHelperMain
    const launch = this.options.command
      ? { command: this.options.command, args: this.options.args || [helperPath] }
      : defaultLaunch(this.options)
    const command = launch.command
    const args = this.options.args || launch.args

    const child = spawn(command, args, {
      cwd: this.options.cwd || packageRoot,
      env: { ...process.env, ...this.options.env },
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true,
    })
    this.child = child
    child.once('error', (error) => {
      this.logger.error?.(`better-dsh-pet helper failed to start: ${error.message}`)
    })
    child.once('exit', (code, signal) => {
      if (this.child !== child) return
      this.child = undefined
      if (!this.stopping && !this.restartSuppressed) {
        this.logger.warn?.(`better-dsh-pet helper exited (code=${String(code)}, signal=${String(signal)}); restarting`)
        this.#scheduleRestart()
      }
    })
    child.stdout.on('data', (chunk) => {
      const line = String(chunk).trim()
      if (line) this.logger.debug?.(`better-dsh-pet helper: ${line}`)
    })
    child.stderr.on('data', (chunk) => {
      const line = String(chunk).trim()
      if (line) this.logger.warn?.(`better-dsh-pet helper: ${line}`)
    })
    return child
  }

  stop(reason = 'plugin-disposed') {
    this.stopping = true
    if (this.restartTimer) clearTimeout(this.restartTimer)
    this.restartTimer = undefined
    const child = this.child
    if (!child) return
    child.kill()
  }

  #scheduleRestart() {
    if (this.restartTimer || this.stopping || this.restartSuppressed) return
    const delay = this.options.restartDelayMs ?? 750
    this.restartTimer = setTimeout(() => {
      this.restartTimer = undefined
      this.start()
    }, delay)
    this.restartTimer.unref?.()
  }
}

export {
  defaultHelperMain,
  defaultLaunch,
  packageRoot,
  resolveElectronPath,
}
