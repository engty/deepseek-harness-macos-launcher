/**
 * better-dsh-pet desktop helper —— Electron 主进程
 *
 * 不再依赖 stdin 协议（Windows 下 Electron GUI 进程的 stdin 不可靠），
 * 改为轮询 DSH 宿主暴露的 /plugins/better-dsh-pet/status HTTP 端点，
 * 把最新状态转发给透明置顶窗口内的 renderer。
 */
const { app, BrowserWindow, ipcMain, screen, shell } = require('electron')
const path = require('node:path')
const { spawn, execFile } = require('node:child_process')
const { existsSync } = require('node:fs')

// 允许无用户手势直接播放 MP3 闹钟
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required')

// macOS：桌面宠物是背景型应用，隐藏 Dock 图标，避免影响用户。
if (process.platform === 'darwin' && app.dock) {
  try { app.dock.hide() } catch { /* 系统不支持时忽略 */ }
}

let mainWindow = null
let pollTimer = null
let speechProcess = null
let speechGeneration = 0

// Windows 版使用 System.Speech；macOS 用系统自带的 say，避免再引入一套
// 语音引擎或把音频上传到网络。参数通过 execFile 数组传递，不经过 shell。
function speakText(text) {
  if (process.platform !== 'darwin' || process.env.DSH_PET_VOICE_ENABLED === '0') return
  const safeText = String(text || '').replace(/\s+/g, ' ').trim().slice(0, 240)
  if (!safeText) return
  if (speechProcess && !speechProcess.killed) speechProcess.kill('SIGTERM')
  const generation = ++speechGeneration
  // Yue (Premium) 是 macOS 的高级中文（中国大陆）系统音色；未安装时自动回退。
  const voice = process.env.DSH_PET_VOICE_NAME || 'Yue (Premium)'
  const launch = (args, allowFallback) => {
    const child = execFile('/usr/bin/say', args, { timeout: 15000 }, (error) => {
      if (speechProcess === child) speechProcess = null
      // 用户未安装指定中文音色时，退回系统默认音色。
      if (error && allowFallback && generation === speechGeneration) launch([safeText], false)
    })
    speechProcess = child
  }
  launch(['-v', voice, safeText], true)
}

// macOS 点击穿透方案：
// setIgnoreMouseEvents 的 { forward: true } 只有 Windows 支持，macOS 上窗口一旦
// 忽略鼠标事件就再也收不到 mousemove，无法像 Windows 那样由 renderer 自行切换。
// 因此 macOS 下由主进程轮询系统光标位置：光标进入宠物/气泡矩形时临时关闭忽略，
// 让 renderer 恢复接收鼠标事件；光标离开后再由 renderer 重新开启忽略。
let ignoring = true
let cursorWatchTimer = null
let petRects = [] // renderer 上报的屏幕坐标矩形（DIP）
const CURSOR_WATCH_MS = 80
const CURSOR_PADDING = 12 // 光标进入判断的余量，避免贴边时抖动

function setClickThrough(ignore) {
  ignoring = ignore === true
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.setIgnoreMouseEvents(ignoring, { forward: true })
  }
  if (process.platform === 'darwin') {
    if (ignoring) startCursorWatch()
    else stopCursorWatch()
  }
}

function startCursorWatch() {
  if (cursorWatchTimer) return
  cursorWatchTimer = setInterval(() => {
    if (!mainWindow || mainWindow.isDestroyed() || !ignoring) return
    const point = screen.getCursorScreenPoint()
    const hit = petRects.some((rect) => (
      point.x >= rect.x - CURSOR_PADDING
      && point.x <= rect.x + rect.width + CURSOR_PADDING
      && point.y >= rect.y - CURSOR_PADDING
      && point.y <= rect.y + rect.height + CURSOR_PADDING
    ))
    if (hit) {
      // 光标进入宠物区域：关闭忽略，renderer 随后会接管判断。
      setClickThrough(false)
    }
  }, CURSOR_WATCH_MS)
  if (cursorWatchTimer.unref) cursorWatchTimer.unref()
}

function stopCursorWatch() {
  if (cursorWatchTimer) {
    clearInterval(cursorWatchTimer)
    cursorWatchTimer = null
  }
}

function resolveDesktopPath() {
  const candidates = [
    process.env.DSH_PET_DESKTOP_PATH,
    process.env.DSH_DESKTOP_PATH,
  ].filter(Boolean)
  if (process.platform === 'darwin') {
    // macOS：DSH Desktop 是 .app 包。
    candidates.push(
      '/Applications/Deepseek Harness Desktop.app',
      '/Applications/DSH Desktop.app',
      `${process.env.HOME || ''}/Applications/Deepseek Harness Desktop.app`,
      `${process.env.HOME || ''}/Applications/DSH Desktop.app`,
    )
  } else if (process.platform === 'win32') {
    candidates.push(
      'D:\\deepseek harness\\DSH Desktop\\DSH Desktop.exe',
      'D:/deepseek harness/DSH Desktop/DSH Desktop.exe',
    )
  }
  return candidates.find((candidate) => candidate && existsSync(candidate))
}

function openDesktop() {
  const desktopPath = resolveDesktopPath()
  if (!desktopPath) {
    console.error('[better-dsh-pet-helper] DSH Desktop executable not found')
    return
  }
  try {
    if (process.platform === 'darwin') {
      // macOS：用 open 启动 .app。
      const child = spawn('open', [desktopPath], {
        detached: true,
        stdio: 'ignore',
      })
      child.unref()
      return
    }
    const child = spawn(desktopPath, [], {
      detached: true,
      stdio: 'ignore',
      windowsHide: false,
    })
    child.unref()
  } catch (error) {
    console.error('[better-dsh-pet-helper] failed to launch DSH Desktop:', error)
  }
}

function createWindow() {
  const scale = Number(process.env.DSH_PET_SCALE || '1')
  const bubbleScale = Number(process.env.DSH_PET_BUBBLE_SCALE || '1')
  // 使用主屏工作区作为透明画布，宠物在画布内自由移动，不移动窗口本身。
  const display = screen.getPrimaryDisplay()
  const area = display.workArea
  const width = area.width
  const height = area.height

  mainWindow = new BrowserWindow({
    width,
    height,
    x: area.x,
    y: area.y,
    show: false,
    useContentSize: true,
    transparent: true,
    frame: false,
    alwaysOnTop: true,
    skipTaskbar: true,
    resizable: false,
    hasShadow: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      // The renderer only needs the preload bridge; keep Chromium's sandbox
      // enabled so a malformed animation or remote response cannot reach Node.
      sandbox: true,
      paintWhenInitiallyHidden: false,
    },
  })

  mainWindow.once('ready-to-show', () => {
    mainWindow.show()
  })

  mainWindow.setAlwaysOnTop(true, 'screen-saver')
  mainWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true })
  setClickThrough(true)

  mainWindow.loadFile('index.html', {
    query: {
      scale: String(scale),
      bubbleScale: String(bubbleScale),
      voiceEnabled: process.env.DSH_PET_VOICE_ENABLED === '0' ? '0' : '1',
      activityLevel: process.env.DSH_PET_ACTIVITY_LEVEL || 'normal',
      reducedMotion: process.env.DSH_PET_REDUCED_MOTION === '1' ? '1' : '0',
      bubbleMode: process.env.DSH_PET_BUBBLE_MODE || 'always',
      bubbleStates: process.env.DSH_PET_BUBBLE_STATES || 'SUCCESS,ERROR,WAITING',
      webuiUrl: process.env.DSH_PET_WEBUI_URL || 'http://127.0.0.1:3080/',
    },
  }).then(() => {
    startPolling()
  }).catch((error) => {
    console.error('[better-dsh-pet-helper] page load failed:', error)
    app.quit()
  })

  mainWindow.on('closed', () => {
    mainWindow = null
    if (pollTimer) clearInterval(pollTimer)
    pollTimer = null
    stopCursorWatch()
    petRects = []
  })
}

async function notifyHostClosed() {
  const statusUrl = process.env.DSH_PET_STATUS_URL
  if (!statusUrl) return
  try {
    const closeUrl = statusUrl.replace(/\/plugins\/better-dsh-pet\/status$/, '/plugins/better-dsh-pet/close')
    await fetch(closeUrl, { method: 'POST', cache: 'no-store' })
  } catch {
    // 宿主不可达时无法通知，仍继续退出；宿主侧可能按崩溃重启处理。
  }
}

function startPolling() {
  const statusUrl = process.env.DSH_PET_STATUS_URL
  if (!statusUrl) {
    console.error('[better-dsh-pet-helper] DSH_PET_STATUS_URL is not set')
    return
  }
  const poll = async () => {
    if (!mainWindow || mainWindow.isDestroyed()) return
    try {
      const response = await fetch(statusUrl, { cache: 'no-store' })
      if (!response.ok) return
      const status = await response.json()
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('pet:status', status)
      }
    } catch (error) {
      // DSH 尚未就绪或临时不可达时静默跳过，下个周期再试。
    }
  }
  poll()
  pollTimer = setInterval(poll, 1000)
  if (pollTimer.unref) pollTimer.unref()
}

app.whenReady().then(() => {
  createWindow()
  ipcMain.on('pet:closed', (_event, reason) => {
    void notifyHostClosed().finally(() => app.quit())
  })
  ipcMain.on('pet:hide', () => {
    if (mainWindow) mainWindow.hide()
  })
  ipcMain.on('pet:open-webui', (_event, url) => {
    if (url) shell.openExternal(String(url)).catch(() => {})
  })
  ipcMain.on('pet:open-desktop', () => {
    openDesktop()
  })
  ipcMain.on('pet:set-ignore-mouse', (_event, { ignore }) => {
    setClickThrough(ignore === true)
  })
  ipcMain.on('pet:report-rect', (_event, rects) => {
    if (!Array.isArray(rects)) return
    petRects = rects.filter((rect) => (
      rect && Number.isFinite(rect.x) && Number.isFinite(rect.y)
      && Number.isFinite(rect.width) && Number.isFinite(rect.height)
      && rect.width > 0 && rect.height > 0
    ))
  })
  ipcMain.on('pet:beep', () => {
    try { shell.beep() } catch { /* 系统不支持时忽略 */ }
  })
  ipcMain.on('pet:speak', (_event, text) => {
    speakText(text)
  })
  ipcMain.on('pet:save-config', async (_event, patch) => {
    const statusUrl = process.env.DSH_PET_STATUS_URL
    if (!statusUrl || !patch || typeof patch !== 'object') return
    try {
      const configUrl = statusUrl.replace(/\/plugins\/better-dsh-pet\/status$/, '/plugins/better-dsh-pet/config')
      const response = await fetch(configUrl, {
        method: 'PATCH',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(patch),
      })
      if (!response.ok) {
        console.error('[better-dsh-pet-helper] save config failed:', response.status)
      }
    } catch (error) {
      console.error('[better-dsh-pet-helper] save config error:', error)
    }
  })
  ipcMain.on('pet:request-roast', async () => {
    const statusUrl = process.env.DSH_PET_STATUS_URL
    if (!statusUrl) return
    try {
      const roastUrl = statusUrl.replace(/\/plugins\/better-dsh-pet\/status$/, '/plugins/better-dsh-pet/roast')
      await fetch(roastUrl, { method: 'POST', cache: 'no-store' })
    } catch (error) {
      console.error('[better-dsh-pet-helper] request roast error:', error)
    }
  })
  ipcMain.on('pet:refresh-balance', async () => {
    const statusUrl = process.env.DSH_PET_STATUS_URL
    if (!statusUrl) return
    try {
      const refreshUrl = statusUrl.replace(/\/plugins\/better-dsh-pet\/status$/, '/plugins/better-dsh-pet/refresh-balance')
      await fetch(refreshUrl, { method: 'POST', cache: 'no-store' })
    } catch (error) {
      console.error('[better-dsh-pet-helper] refresh balance error:', error)
    }
  })
  ipcMain.on('pet:move-by', () => {
    // 已改为全屏画布内移动宠物 DOM，不再移动窗口。
  })
  ipcMain.on('pet:drag-end', () => {
    // 保留此通道，后续可用来做拖拽结束后的持久化。
  })
})

app.on('window-all-closed', () => {
  speechGeneration++
  if (speechProcess && !speechProcess.killed) speechProcess.kill('SIGTERM')
  app.quit()
})

app.on('before-quit', () => {
  speechGeneration++
  if (speechProcess && !speechProcess.killed) speechProcess.kill('SIGTERM')
})
