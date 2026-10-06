import fs from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

export const rootDir = path.resolve(__dirname, '..', '..')

const STRICT_SEMVER_RE = /^(\d+)\.(\d+)\.(\d+)$/

function relLabel(root, filePath) {
  return path.relative(root, filePath).replaceAll('\\', '/')
}

function fail(message) {
  throw new Error(message)
}

export function parseSemverStrict(raw) {
  const text = String(raw || '').trim()
  const match = STRICT_SEMVER_RE.exec(text)
  if (!match) return null
  return {
    text,
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
  }
}

export function assertSemverStrict(raw, field) {
  const version = parseSemverStrict(raw)
  if (!version) fail(`${field} 必须是 x.y.z 格式: ${raw}`)
  return version
}

export function bumpSemverStrict(version, bump) {
  const v = assertSemverStrict(version, 'version')
  if (bump === 'patch') return `${v.major}.${v.minor}.${v.patch + 1}`
  if (bump === 'minor') return `${v.major}.${v.minor + 1}.0`
  if (bump === 'major') return `${v.major + 1}.0.0`
  fail(`未知升版类型: ${bump}`)
}

function preserveNewline(text, updatedText) {
  const newline = text.includes('\r\n') ? '\r\n' : '\n'
  return updatedText.replace(/\r\n?/g, '\n').replace(/\n/g, newline)
}

async function readRequiredText(filePath, label) {
  try {
    return await fs.readFile(filePath, 'utf8')
  } catch (error) {
    if (error?.code === 'ENOENT') fail(`缺少 v5 app 版本目标: ${label}`)
    throw error
  }
}

async function assertRequiredDir(dirPath, label) {
  let stat
  try {
    stat = await fs.stat(dirPath)
  } catch (error) {
    if (error?.code === 'ENOENT') fail(`缺少 v5 app 目录: ${label}`)
    throw error
  }
  if (!stat.isDirectory()) fail(`v5 app 路径不是目录: ${label}`)
}

function jsonVersionLineMatches(text) {
  return text
    .split(/\r?\n/)
    .map((line, index) => ({ line, index }))
    .map(({ line, index }) => ({
      index,
      match: /^\s*"version"\s*:\s*"([^"]*)"\s*,?\s*$/.exec(line),
    }))
    .filter(item => item.match)
}

function readJsonVersion(text, label) {
  let parsed
  try {
    parsed = JSON.parse(text)
  } catch (error) {
    fail(`${label}: JSON 解析失败: ${error?.message || error}`)
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) fail(`${label}: 顶层必须是 JSON 对象`)
  if (typeof parsed.version !== 'string') fail(`${label}: 顶层 version 必须存在且是字符串`)
  const parsedVersion = assertSemverStrict(parsed.version, `${label}.version`).text

  const matches = jsonVersionLineMatches(text)
  if (matches.length !== 1) fail(`${label}: version 行必须唯一，当前找到 ${matches.length} 个`)
  const lineVersion = assertSemverStrict(matches[0].match[1], `${label}.version`).text
  if (lineVersion !== parsedVersion) fail(`${label}: version 行与 JSON 顶层 version 不一致`)
  return parsedVersion
}

function updateJsonVersion(text, newVersion, label) {
  readJsonVersion(text, label)
  const matches = jsonVersionLineMatches(text)
  if (matches.length !== 1) fail(`${label}: version 行必须唯一，当前找到 ${matches.length} 个`)

  const lines = text.split(/\r?\n/)
  const index = matches[0].index
  lines[index] = lines[index].replace(/("version"\s*:\s*)"[^"]*"/, `$1"${newVersion}"`)
  const updated = lines.join('\n')
  const updatedVersion = readJsonVersion(updated, label)
  if (updatedVersion !== newVersion) fail(`${label}: 更新后 version 校验失败`)
  return preserveNewline(text, updated)
}

// pubspec 版本行规则：`version: x.y.z` 或 `version: x.y.z+构建号`；商店版本只取 x.y.z 部分。
function pubspecVersionLineMatches(text) {
  return text
    .split(/\r?\n/)
    .map((line, index) => ({ line, index }))
    .map(({ line, index }) => ({
      index,
      match: /^version:\s*(\S+)\s*$/.exec(line),
    }))
    .filter(item => item.match)
}

function readPubspecVersion(text, label) {
  const matches = pubspecVersionLineMatches(text)
  if (matches.length !== 1) fail(`${label}: 顶层 version 行必须唯一，当前找到 ${matches.length} 个`)
  const raw = matches[0].match[1]
  const parsed = /^(\d+\.\d+\.\d+)(?:\+(\d+))?$/.exec(raw)
  if (!parsed) fail(`${label}: version 格式必须是 x.y.z 或 x.y.z+构建号: ${raw}`)
  const version = assertSemverStrict(parsed[1], `${label}.version`).text
  return { version, build: parsed[2] === undefined ? null : Number(parsed[2]) }
}

function updatePubspecVersion(text, newVersion, label) {
  const current = readPubspecVersion(text, label)
  const matches = pubspecVersionLineMatches(text)
  if (matches.length !== 1) fail(`${label}: 顶层 version 行必须唯一，当前找到 ${matches.length} 个`)

  const nextBuild = (current.build ?? 0) + 1
  const lines = text.split(/\r?\n/)
  const index = matches[0].index
  lines[index] = lines[index].replace(/^(version:\s*)\S+\s*$/, `$1${newVersion}+${nextBuild}`)
  const updated = lines.join('\n')
  const updatedVersion = readPubspecVersion(updated, label)
  if (updatedVersion.version !== newVersion) fail(`${label}: 更新后 version 校验失败`)
  if (updatedVersion.build !== nextBuild) fail(`${label}: 更新后构建号校验失败`)
  return preserveNewline(text, updated)
}

function makeJsonTarget(root, filePath) {
  const label = relLabel(root, filePath)
  return {
    label,
    filePath,
    readVersion: text => readJsonVersion(text, label),
    updateText: (text, newVersion) => updateJsonVersion(text, newVersion, label),
  }
}

function makePubspecTarget(root, filePath) {
  const label = relLabel(root, filePath)
  return {
    label,
    filePath,
    readVersion: text => readPubspecVersion(text, label).version,
    updateText: (text, newVersion) => updatePubspecVersion(text, newVersion, label),
  }
}

export async function createV5AppVersionPlan(appDirArg = rootDir) {
  const appDir = path.resolve(appDirArg)
  await assertRequiredDir(appDir, appDir)

  return {
    appDir,
    targets: [
      makeJsonTarget(appDir, path.join(appDir, 'release.json')),
      makePubspecTarget(appDir, path.join(appDir, 'pubspec.yaml')),
    ],
  }
}

export async function readV5AppVersionState({ appDir = rootDir } = {}) {
  const plan = await createV5AppVersionPlan(appDir)
  const entries = []
  for (const target of plan.targets) {
    const text = await readRequiredText(target.filePath, target.label)
    entries.push({
      ...target,
      text,
      version: target.readVersion(text),
    })
  }
  return { ...plan, entries }
}

export function assertUnifiedV5AppVersion(entries, appDir) {
  const versions = new Map()
  for (const entry of entries) {
    if (!versions.has(entry.version)) versions.set(entry.version, [])
    versions.get(entry.version).push(entry.label)
  }
  if (versions.size === 1) return entries[0].version

  const details = Array.from(versions.entries())
    .map(([version, labels]) => `  ${version}: ${labels.join(', ')}`)
    .join('\n')
  fail(`v5 app ${appDir} 版本漂移，拒绝升版:\n${details}`)
}

export async function checkV5AppVersion({ appDir = rootDir } = {}) {
  const state = await readV5AppVersionState({ appDir })
  const currentVersion = assertUnifiedV5AppVersion(state.entries, state.appDir)
  return {
    appDir: state.appDir,
    currentVersion,
    files: state.entries.map(entry => ({ label: entry.label, version: entry.version })),
  }
}

export async function bumpV5AppVersion({ bump = 'patch', to = null, dryRun = false, appDir = rootDir } = {}) {
  const state = await readV5AppVersionState({ appDir })
  const oldVersion = assertUnifiedV5AppVersion(state.entries, state.appDir)
  const newVersion = to ? assertSemverStrict(to, '--to').text : bumpSemverStrict(oldVersion, bump)
  if (newVersion === oldVersion) fail('新版本等于当前版本，拒绝无意义升版')

  const changed = []
  const updates = []
  for (const entry of state.entries) {
    const updated = entry.updateText(entry.text, newVersion)
    if (updated === entry.text) fail(`${entry.label}: 版本写入没有产生变化`)
    if (entry.readVersion(updated) !== newVersion) fail(`${entry.label}: 写入后版本校验失败`)
    changed.push({ label: entry.label, filePath: entry.filePath })
    updates.push({ ...entry, updated })
  }

  if (!dryRun) {
    const applied = []
    try {
      for (const entry of updates) {
        await fs.writeFile(entry.filePath, entry.updated, 'utf8')
        applied.push(entry)
      }
      const verified = await checkV5AppVersion({ appDir: state.appDir })
      if (verified.currentVersion !== newVersion) fail(`二次校验失败: expected=${newVersion}, got=${verified.currentVersion}`)
    } catch (error) {
      const rollbackErrors = []
      for (const entry of applied.reverse()) {
        try {
          await fs.writeFile(entry.filePath, entry.text, 'utf8')
        } catch (rollbackError) {
          rollbackErrors.push(`${entry.label}: ${rollbackError?.message || rollbackError}`)
        }
      }
      if (rollbackErrors.length) fail(`v5 app 升版失败，且版本回滚失败。升版错误: ${error?.message || error}；回滚错误: ${rollbackErrors.join('；')}`)
      fail(`v5 app 升版失败，已回滚到 ${oldVersion}: ${error?.message || error}`)
    }
  }

  return {
    appDir: state.appDir,
    oldVersion,
    newVersion,
    dryRun,
    files: changed.map(item => item.label),
  }
}
