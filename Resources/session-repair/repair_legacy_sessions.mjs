#!/usr/bin/env node

// Repair the one released dsh-mnemon v0 metadata shape that newer Harness
// Runtime validators reject: a non-notice plugin source carrying `summary`.
// The repair is intentionally byte-preserving for every untouched JSON row.
// The launcher moves the original artifact into its backup tree before it
// publishes the repaired copy, so this helper never overwrites its input.

import { existsSync, mkdirSync, openSync, readFileSync, renameSync, closeSync, writeFileSync, readdirSync } from 'node:fs'
import { dirname, relative, resolve, join } from 'node:path'
import * as zlib from 'node:zlib'

const maximumBytes = 512 * 1024 * 1024
const zstdMagic = Buffer.from([0x28, 0xb5, 0x2f, 0xfd])
const repairedForms = new Set(['instructions', 'catalog', 'snapshot', 'recall', 'relay'])

function objectMembers(text, start) {
  let cursor = start
  const space = () => { while (/\s/.test(text[cursor] ?? '') && cursor < text.length) cursor++ }
  const stringEnd = () => {
    cursor++
    while (cursor < text.length) {
      if (text[cursor++] === '"') return
      if (text[cursor - 1] === '\\') cursor++
    }
    throw new Error('Unterminated JSON string in the legacy message path.')
  }
  const valueEnd = () => {
    if (text[cursor] === '"') return stringEnd()
    if (text[cursor] === '{' || text[cursor] === '[') {
      let depth = 0
      do {
        if (text[cursor] === '"') stringEnd()
        else {
          if ('{['.includes(text[cursor])) depth++
          if ('}]'.includes(text[cursor])) depth--
          cursor++
        }
      } while (depth > 0)
      return
    }
    while (cursor < text.length && !/[\s,}\]]/.test(text[cursor])) cursor++
  }
  space()
  if (text[cursor++] !== '{') throw new Error('Expected a JSON object in the legacy message path.')
  const members = []
  const names = new Set()
  space()
  while (text[cursor] !== '}') {
    const startOfName = cursor
    stringEnd()
    const name = JSON.parse(text.slice(startOfName, cursor))
    if (names.has(name)) throw new Error('Duplicate JSON property in the legacy message path.')
    names.add(name)
    space()
    if (text[cursor++] !== ':') throw new Error('Expected a JSON colon in the legacy message path.')
    space()
    const valueStart = cursor
    valueEnd()
    members.push({ name, start: startOfName, end: cursor, valueStart })
    space()
    if (text[cursor] === '}') break
    if (text[cursor++] !== ',') throw new Error('Expected a JSON comma in the legacy message path.')
    space()
  }
  return members
}

function removeSummary(line) {
  const dataMember = objectMembers(line, 0).find(member => member.name === 'data')
  if (dataMember === undefined) throw new Error('Legacy user/message has no data object.')
  const sourceMember = objectMembers(line, dataMember.valueStart).find(member => member.name === 'source')
  if (sourceMember === undefined) throw new Error('Legacy user/message has no source object.')
  const members = objectMembers(line, sourceMember.valueStart)
  const index = members.findIndex(member => member.name === 'summary')
  if (index < 0) throw new Error('Legacy source has no summary member.')
  const member = members[index]
  const start = index === members.length - 1 && index > 0 ? members[index - 1].end : member.start
  const end = index < members.length - 1 ? members[index + 1].start : member.end
  return line.slice(0, start) + line.slice(end)
}

function frameLength(input, start) {
  const requireBytes = end => {
    if (end > input.length) throw new Error('Truncated Zstandard frame; no output written.')
  }
  requireBytes(start + 5)
  if (input.readUInt32LE(start) !== 0xfd2fb528) throw new Error('Unsupported Zstandard frame.')
  const descriptor = input[start + 4]
  if (descriptor & 0x18) throw new Error('Reserved Zstandard frame header bits are set.')
  const single = (descriptor & 0x20) !== 0
  const sizeFlag = descriptor >>> 6
  const contentSizeBytes = sizeFlag === 0 ? (single ? 1 : 0) : [0, 2, 4, 8][sizeFlag]
  let offset = start + 5 + (single ? 0 : 1) + [0, 1, 2, 4][descriptor & 3] + contentSizeBytes
  requireBytes(offset)
  let last = false
  while (!last) {
    requireBytes(offset + 3)
    const block = input.readUIntLE(offset, 3)
    last = (block & 1) !== 0
    const type = (block >>> 1) & 3
    if (type === 3) throw new Error('Reserved Zstandard block type.')
    offset += 3 + (type === 1 ? 1 : block >>> 3)
    requireBytes(offset)
  }
  offset += descriptor & 4 ? 4 : 0
  requireBytes(offset)
  return offset - start
}

function decodeFrames(input) {
  const chunks = []
  let offset = 0
  let length = 0
  while (offset < input.length) {
    const lengthOnDisk = frameLength(input, offset)
    const decoded = zlib.zstdDecompressSync(
      input.subarray(offset, offset + lengthOnDisk),
      { info: true, maxOutputLength: maximumBytes - length },
    )
    if (decoded.engine.bytesWritten !== lengthOnDisk) throw new Error('Invalid Zstandard frame length.')
    offset += decoded.engine.bytesWritten
    length += decoded.buffer.length
    if (length > maximumBytes) throw new Error('Session exceeds the 512 MiB repair limit.')
    chunks.push(decoded.buffer)
  }
  return Buffer.concat(chunks)
}

function encodeFrames(text) {
  const end = text.indexOf('\n') + 1
  if (end <= 0) throw new Error('Session has no complete header line.')
  const options = { params: { [zlib.constants.ZSTD_c_checksumFlag]: 1 } }
  return Buffer.concat(
    [text.slice(0, end), text.slice(end)]
      .filter(Boolean)
      .map(part => zlib.zstdCompressSync(part, options)),
  )
}

function repair(input) {
  if (!Buffer.isBuffer(input) || input.length > maximumBytes) throw new Error('Session is empty or exceeds the repair limit.')
  const compressed = input.subarray(0, 4).equals(zstdMagic)
  if (compressed && (typeof zlib.zstdDecompressSync !== 'function' || typeof zlib.zstdCompressSync !== 'function')) {
    throw new Error('Zstandard sessions require Node 22.19 or newer (or Node 24+).')
  }
  const decoded = compressed ? decodeFrames(input) : input
  const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(decoded)
  if (!text.endsWith('\n')) throw new Error('Session must end with a complete newline-terminated JSON record.')
  const lines = text.match(/[^\n]*\n/g) ?? []
  if (lines.length === 0) throw new Error('Session has no records.')

  const header = JSON.parse(lines[0])
  if (header.type !== 'session' || header.version !== 0 || typeof header.id !== 'string' ||
      !header.id || !Number.isSafeInteger(header.createdAt) || header.createdAt < 0 ||
      !Number.isSafeInteger(header.delegationDepth) || header.delegationDepth < 0) {
    throw new Error('Only a legacy DSH format v0 Session header is supported.')
  }

  let repairedMessages = 0
  const repaired = lines.map((line, index) => {
    const row = JSON.parse(line)
    if (index === 0) return line
    const source = row?.data?.source
    const shouldRepair = row?.type === 'user/message' && source?.kind === 'plugin' &&
      source.plugin === 'dsh-mnemon' && typeof source.summary === 'string' &&
      repairedForms.has(source.form)
    if (!shouldRepair) return line
    repairedMessages++
    return removeSummary(line)
  }).join('')

  return {
    result: repairedMessages === 0 ? input : compressed ? encodeFrames(repaired) : Buffer.from(repaired),
    repairedMessages,
    originalPreserved: true,
    encoding: compressed ? 'zstd' : 'jsonl',
  }
}

function parseArgs(args) {
  const options = new Map()
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index]
    const value = args[index + 1]
    if (!['--input', '--output', '--root', '--output-root'].includes(name) ||
      !value || value.startsWith('--') || options.has(name)) {
      throw new Error('Usage: repair_legacy_sessions.mjs --root DIR --output-root DIR')
    }
    options.set(name, value)
  }
  const singleFile = options.has('--input') && options.has('--output') &&
    !options.has('--root') && !options.has('--output-root')
  const batch = options.has('--root') && options.has('--output-root') &&
    !options.has('--input') && !options.has('--output')
  if (!singleFile && !batch) throw new Error('Usage: repair_legacy_sessions.mjs --root DIR --output-root DIR')
  return options
}

function sessionFiles(root) {
  const result = []
  const visit = directory => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      if (entry.name.startsWith('.')) continue
      const path = join(directory, entry.name)
      if (entry.isDirectory()) visit(path)
      else if (entry.isFile() && (entry.name === 'session.jsonl.zstd' || entry.name === 'session.jsonl')) result.push(path)
    }
  }
  visit(root)
  return result.sort()
}

function writeOutput(outputPath, bytes) {
  if (existsSync(outputPath)) throw new Error('Output already exists; refusing to overwrite it.')
  mkdirSync(dirname(outputPath), { recursive: true, mode: 0o700 })
  const temporary = `${outputPath}.tmp-${process.pid}-${Date.now()}`
  const descriptor = openSync(temporary, 'wx', 0o600)
  try {
    writeFileSync(descriptor, bytes)
  } finally {
    closeSync(descriptor)
  }
  renameSync(temporary, outputPath)
}

function runSingle(options) {
  const inputPath = resolve(options.get('--input'))
  const outputPath = resolve(options.get('--output'))
  if (inputPath === outputPath) throw new Error('Output must be a new copy; input cannot be overwritten.')
  const repaired = repair(readFileSync(inputPath))
  if (repaired.repairedMessages > 0) writeOutput(outputPath, repaired.result)
  return {
    mode: 'copy',
    format: 0,
    encoding: repaired.encoding,
    repairedMessages: repaired.repairedMessages,
    originalPreserved: true,
  }
}

function runBatch(options) {
  const root = resolve(options.get('--root'))
  const outputRoot = resolve(options.get('--output-root'))
  if (root === outputRoot || outputRoot.startsWith(`${root}/`)) {
    throw new Error('Output root must be outside the input Session root.')
  }
  const repairedFiles = []
  const failedFiles = []
  for (const inputPath of sessionFiles(root)) {
    const relativePath = relative(root, inputPath)
    try {
      const repaired = repair(readFileSync(inputPath))
      if (repaired.repairedMessages > 0) {
        const outputPath = join(outputRoot, relativePath)
        writeOutput(outputPath, repaired.result)
        repairedFiles.push({ relativePath, repairedMessages: repaired.repairedMessages })
      }
    } catch (error) {
      failedFiles.push({
        relativePath,
        error: error instanceof Error ? error.message : String(error),
      })
    }
  }
  return {
    mode: 'batch',
    format: 0,
    scannedFiles: sessionFiles(root).length,
    repairedFiles,
    failedFiles,
    originalPreserved: true,
  }
}

function main() {
  const options = parseArgs(process.argv.slice(2))
  console.log(JSON.stringify(options.has('--root') ? runBatch(options) : runSingle(options)))
}

try {
  main()
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
}
