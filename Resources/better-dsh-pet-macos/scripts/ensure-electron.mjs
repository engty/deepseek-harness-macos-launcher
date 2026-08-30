#!/usr/bin/env node
/**
 * ensure-electron.mjs
 *
 * 自动下载 Electron 到 $DSH_HOME/electron（默认 ~/.dsh/electron），
 * 供 better-dsh-pet 桌面 Helper 使用。
 *
 * 用法：
 *   node scripts/ensure-electron.mjs
 *
 * 环境变量：
 *   DSH_HOME                     DSH 主目录（默认 ~/.dsh）
 *   DSH_PET_ELECTRON_VERSION     Electron 版本（默认 43.3.0）
 *   DSH_PET_ELECTRON_MIRROR      镜像地址（默认 npmmirror）
 *
 * 平台支持：Windows（win32-x64）、macOS（darwin-arm64 / darwin-x64）、Linux（linux-x64 / linux-arm64）。
 */

import { createHash } from 'node:crypto'
import { createReadStream, existsSync, mkdirSync, rmSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { spawnSync } from 'node:child_process'
import { pipeline } from 'node:stream/promises'
import { createWriteStream } from 'node:fs'

const HOME = process.env.DSH_HOME || join(process.env.USERPROFILE || process.env.HOME || '', '.dsh')
const VERSION = process.env.DSH_PET_ELECTRON_VERSION || '43.3.0'
const MIRROR = process.env.DSH_PET_ELECTRON_MIRROR || 'https://npmmirror.com/mirrors/electron/'
const TARGET_DIR = resolve(HOME, 'electron')

// Electron archives are fetched at first activation, so verify the exact
// bytes before extraction. These are the official Electron v43.3.0 release
// digests for the architectures supported by this macOS build.
const EXPECTED_SHA256 = {
  'darwin-arm64': 'ee939d1564d83d61032b3b3cb23af4e46005a4900c91f0695f7ed793f0ce6e83',
  'darwin-x64': '7347bbd5fb529eea64f9c2d148bb1c19222d98946ff234ffe27953a1bbcb9dae',
}

// ---------- 平台相关定义 ----------
function platformTag() {
  if (process.platform === 'win32') return 'win32-x64'
  if (process.platform === 'darwin') return process.arch === 'arm64' ? 'darwin-arm64' : 'darwin-x64'
  if (process.platform === 'linux') return `linux-${process.arch}`
  throw new Error(`unsupported platform: ${process.platform} ${process.arch}`)
}

// Electron 可执行文件（相对 TARGET_DIR）。
function electronBinaryName() {
  if (process.platform === 'win32') return 'electron.exe'
  if (process.platform === 'darwin') return join('Electron.app', 'Contents', 'MacOS', 'Electron')
  return 'electron'
}

function requiredFiles() {
  if (process.platform === 'win32') {
    return [
      'electron.exe',
      'icudtl.dat',
      'resources.pak',
      'snapshot_blob.bin',
      'chrome_100_percent.pak',
      'v8_context_snapshot.bin',
    ]
  }
  if (process.platform === 'darwin') {
    return [
      join('Electron.app', 'Contents', 'MacOS', 'Electron'),
      join('Electron.app', 'Contents', 'Resources', 'default_app.asar'),
    ]
  }
  return ['electron', 'resources.pak', 'v8_context_snapshot.bin']
}

const EXE = join(TARGET_DIR, electronBinaryName())

async function download(url, dest) {
  const response = await fetch(url, { redirect: 'follow' })
  if (!response.ok) {
    throw new Error(`download failed: ${response.status} ${response.statusText} (${url})`)
  }
  await pipeline(response.body, createWriteStream(dest))
}

async function sha256(file) {
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(file)) hash.update(chunk)
  return hash.digest('hex')
}

function extractZip(zipPath, targetDir) {
  mkdirSync(targetDir, { recursive: true })
  // macOS/Linux 自带 tar（bsdtar/gnu tar）可以直接解压 zip；Windows 上也可用自带的 tar；
  // 失败时退回 PowerShell Expand-Archive。
  const tar = spawnSync('tar', ['-xf', zipPath, '-C', targetDir], { stdio: 'inherit' })
  if (tar.status !== 0) {
    if (process.platform !== 'win32') {
      throw new Error('failed to extract Electron zip with tar')
    }
    const ps = spawnSync('powershell', [
      '-NoProfile',
      '-Command',
      `Expand-Archive -LiteralPath '${zipPath}' -DestinationPath '${targetDir}' -Force`,
    ], { stdio: 'inherit' })
    if (ps.status !== 0) {
      throw new Error('failed to extract Electron zip')
    }
  }
  // 校验关键文件是否完整；不完整说明下载/解压失败，清理后重试。
  const missing = requiredFiles().filter((name) => !existsSync(join(targetDir, name)))
  if (missing.length > 0) {
    rmSync(targetDir, { recursive: true, force: true })
    throw new Error(`Electron zip incomplete, missing: ${missing.join(', ')}`)
  }
}

async function main() {
  if (existsSync(EXE)) {
    console.log(EXE)
    return
  }

  console.log(`[ensure-electron] Electron not found, downloading v${VERSION} ...`)
  mkdirSync(TARGET_DIR, { recursive: true })

  // 清理其它平台的残留文件（例如从 Windows 同步过来的 electron.exe），避免混淆。
  if (process.platform !== 'win32') {
    for (const stale of ['electron.exe', 'chrome_100_percent.pak', 'd3dcompiler_47.dll']) {
      const p = join(TARGET_DIR, stale)
      if (existsSync(p)) {
        try { rmSync(p, { recursive: true, force: true }) } catch { /* ignore */ }
      }
    }
  }

  const tag = platformTag()
  const zipName = `electron-v${VERSION}-${tag}.zip`
  const urls = [
    `${MIRROR.replace(/\/$/, '')}/${VERSION}/${zipName}`,
    `https://github.com/electron/electron/releases/download/v${VERSION}/${zipName}`,
  ]
  const zipPath = join(tmpdir(), zipName)

  try {
    let lastError
    for (const url of urls) {
      try {
        console.log(`[ensure-electron] ${url}`)
        await download(url, zipPath)
        lastError = undefined
        break
      } catch (error) {
        lastError = error
        try { rmSync(zipPath, { force: true }) } catch { /* ignore */ }
      }
    }
    if (lastError) throw lastError
    const expected = EXPECTED_SHA256[tag]
    if (expected) {
      const actual = await sha256(zipPath)
      if (actual !== expected) {
        throw new Error(`Electron archive checksum mismatch: expected ${expected}, got ${actual}`)
      }
      console.log(`[ensure-electron] SHA-256 verified: ${actual}`)
    }
    extractZip(zipPath, TARGET_DIR)
    if (!existsSync(EXE)) {
      throw new Error(`Electron zip extracted, but ${EXE} not found`)
    }
    // macOS 下确保可执行位存在（bsdtar 一般会保留权限，这里兜底）。
    if (process.platform !== 'win32') {
      try { statSync(EXE) } catch { /* ignore */ }
      spawnSync('chmod', ['+x', EXE], { stdio: 'ignore' })
    }
    console.log(EXE)
  } finally {
    try { rmSync(zipPath, { force: true }) } catch { /* ignore */ }
  }
}

main().catch((error) => {
  console.error(`[ensure-electron] ${error instanceof Error ? error.message : String(error)}`)
  process.exit(1)
})
