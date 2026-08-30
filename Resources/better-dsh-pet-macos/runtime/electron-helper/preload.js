const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('petBridge', {
  onStatus(callback) {
    const listener = (_event, status) => callback(status)
    ipcRenderer.on('pet:status', listener)
    return () => ipcRenderer.removeListener('pet:status', listener)
  },
  close(reason) {
    ipcRenderer.send('pet:closed', reason || 'user')
  },
  hide() {
    ipcRenderer.send('pet:hide')
  },
  openWebUi(url) {
    ipcRenderer.send('pet:open-webui', url)
  },
  openDesktop() {
    ipcRenderer.send('pet:open-desktop')
  },
  moveBy(dx, dy) {
    ipcRenderer.send('pet:move-by', { dx, dy })
  },
  endDrag() {
    ipcRenderer.send('pet:drag-end')
  },
  setIgnoreMouse(ignore) {
    ipcRenderer.send('pet:set-ignore-mouse', { ignore })
  },
  // 上报宠物/气泡的屏幕坐标矩形列表（DIP），主进程在 macOS 下据此做点击穿透切换。
  reportRect(rects) {
    ipcRenderer.send('pet:report-rect', rects)
  },
  beep() {
    ipcRenderer.send('pet:beep')
  },
  speak(text) {
    ipcRenderer.send('pet:speak', text)
  },
  saveConfig(patch) {
    ipcRenderer.send('pet:save-config', patch)
  },
  requestRoast() {
    ipcRenderer.send('pet:request-roast')
  },
  refreshBalance() {
    ipcRenderer.send('pet:refresh-balance')
  },
})
