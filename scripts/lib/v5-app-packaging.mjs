import crypto from 'node:crypto'
import fs from 'node:fs/promises'
import fssync from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { spawn } from 'node:child_process'
import {
  DEFAULT_V5_APP_PROFILE,
  isV5AppProfile,
  isSafeId,
  loadAppConfig,
  normalizeRel,
  parseSemverStrict,
  readJson,
  rootDir,
} from './v5-app-package-manifest.mjs'
import { isReservedNameExempted, packZipDirectory } from '../../.fast-window-dev-protocol/fast-window-dev-tool.mjs'

export { DEFAULT_V5_APP_PROFILE, isSafeId, loadAppConfig, normalizeRel, parseSemverStrict, readJson, rootDir }

export const DEFAULT_V5_APP_OUT_DIR = path.join(rootDir, '.tmp', 'dist-v5-apps')
const V5_APP_PACKAGE_DIR_NAME = 'package'
const V5_APP_DATA_DIR_NAME = 'data'
const V5_APP_ICON_MIME_BY_EXT = new Map([
  ['.png', 'image/png'],
  ['.jpg', 'image/jpeg'],
  ['.jpeg', 'image/jpeg'],
  ['.webp', 'image/webp'],
  ['.gif', 'image/gif'],
  ['.ico', 'image/x-icon'],
  ['.svg', 'image/svg+xml'],
])

export function v5AppStagePackageDir(stageDir) {
  return path.join(stageDir, V5_APP_PACKAGE_DIR_NAME)
}

export async function exists(filePath) {
  try {
    await fs.access(filePath)
    return true
  } catch {
    return false
  }
}

function cmdQuote(value) {
  const raw = String(value)
  if (!raw) return '""'
  if (!/[\s"^&|<>%]/.test(raw)) return raw
  return `"${raw.replaceAll('%', '%%').replace(/["^]/g, match => `^${match}`)}"`
}

function resolveSpawnSpec(command, args) {
  if (process.platform === 'win32') {
    // Windows 下统一交给命令解释器：flutter 等入口是 .bat，直接 spawn 不可靠。
    // cmd /c 引号规则：命令全文以引号开头时才需要外层再包一层，交给 /s 剥离。
    const line = [command, ...args].map(cmdQuote).join(' ')
    const commandLine = line.startsWith('"') ? `"${line}"` : line
    return { command: process.env.ComSpec || 'cmd.exe', args: ['/d', '/s', '/c', commandLine] }
  }
  return { command, args }
}

// 构建子进程的 stdout 汇入父进程 stderr：命令行工具自身的 stdout 只留给协议回执解析的 JSON。
export function run(command, args, cwd, opts = {}) {
  return new Promise((resolve, reject) => {
    const spec = resolveSpawnSpec(command, args)
    const child = spawn(spec.command, spec.args, {
      cwd,
      stdio: ['inherit', process.stderr, 'inherit'],
      shell: false,
      ...opts,
    })
    child.on('error', reject)
    child.on('exit', code => {
      if ((code ?? 0) === 0) resolve()
      else reject(new Error(`${command} ${args.join(' ')} failed with exit ${code}`))
    })
  })
}

export async function sha256FileHex(filePath) {
  return await new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256')
    const stream = fssync.createReadStream(filePath)
    stream.on('error', reject)
    stream.on('data', chunk => hash.update(chunk))
    stream.on('end', () => resolve(hash.digest('hex')))
  })
}

async function copyEntry(src, dst) {
  const st = await fs.stat(src).catch(error => {
    throw new Error(`缺少打包输入: ${src} (${error.message})`)
  })
  if (st.isDirectory()) {
    await fs.rm(dst, { recursive: true, force: true })
    await fs.mkdir(path.dirname(dst), { recursive: true })
    await fs.cp(src, dst, { recursive: true })
    return
  }
  if (!st.isFile()) throw new Error(`打包输入不是文件或目录: ${src}`)
  await fs.mkdir(path.dirname(dst), { recursive: true })
  await fs.copyFile(src, dst)
}

async function replaceDirAtomic(srcDir, dstDir) {
  const parent = path.dirname(dstDir)
  const base = path.basename(dstDir)
  const stamp = Date.now()
  const backupDir = path.join(parent, `.tmp-backup-${base}-${stamp}`)
  await fs.rm(backupDir, { recursive: true, force: true })

  let backedUp = false
  if (await exists(dstDir)) {
    try {
      await fs.rename(dstDir, backupDir)
      backedUp = true
    } catch (error) {
      throw new Error(`无法替换 v5 app staging 目录，可能应用仍在运行: ${dstDir} (${error.message})`)
    }
  }

  try {
    await fs.rename(srcDir, dstDir)
  } catch (error) {
    let restoreError = null
    if (backedUp) {
      try {
        await fs.rename(backupDir, dstDir)
      } catch (e) {
        restoreError = e
      }
    }
    const restoreMessage = restoreError ? `；恢复旧目录失败: ${restoreError.message}` : ''
    throw new Error(`写入 v5 app staging 目录失败: ${dstDir} (${error.message})${restoreMessage}`)
  }

  if (backedUp) await fs.rm(backupDir, { recursive: true, force: true })
}

function isInternalStageTempEntry(name) {
  return name.startsWith('.tmp-stage-package-') || name.startsWith('.tmp-backup-package-')
}

async function prepareStageContainer(stageDir) {
  if (!(await exists(stageDir))) {
    await fs.mkdir(stageDir, { recursive: true })
    return
  }

  const stat = await fs.stat(stageDir)
  if (!stat.isDirectory()) throw new Error(`v5 app staging 路径已存在但不是目录: ${stageDir}`)

  const entries = await fs.readdir(stageDir, { withFileTypes: true })
  const hasLegacyManifest = entries.some(entry => entry.isFile() && entry.name === 'fw-app.json')
  if (hasLegacyManifest) {
    for (const entry of entries) {
      if (entry.name === V5_APP_DATA_DIR_NAME) continue
      await fs.rm(path.join(stageDir, entry.name), { recursive: true, force: true })
    }
    return
  }

  for (const entry of entries) {
    if (entry.name === V5_APP_PACKAGE_DIR_NAME || entry.name === V5_APP_DATA_DIR_NAME) continue
    if (isInternalStageTempEntry(entry.name)) {
      await fs.rm(path.join(stageDir, entry.name), { recursive: true, force: true })
      continue
    }
    throw new Error(`v5 app staging 容器存在未知顶层条目，拒绝覆盖: ${path.join(stageDir, entry.name)}`)
  }
}

async function assertNoReservedPackageDataDir(packageRoot, exemptions) {
  if (await exists(path.join(packageRoot, V5_APP_DATA_DIR_NAME)) && !isReservedNameExempted(exemptions, V5_APP_DATA_DIR_NAME)) {
    throw new Error(`程序包根目录不允许包含保留数据目录: ${V5_APP_DATA_DIR_NAME}`)
  }
}

function getV5AppIconMime(iconRel) {
  return V5_APP_ICON_MIME_BY_EXT.get(path.extname(String(iconRel || '')).toLowerCase()) || ''
}

async function zipDirContents(sourceDir, zipPath) {
  await fs.rm(zipPath, { force: true })
  await fs.mkdir(path.dirname(zipPath), { recursive: true })
  packZipDirectory(sourceDir, zipPath)
}

export async function loadV5AppVersion(config) {
  const source = normalizeRel(config.versionSource, 'versionSource')
  const data = await readJson(path.join(config.appDir, source))
  const version = parseSemverStrict(data.version)
  if (!version) throw new Error(`${source}.version 必须是 x.y.z 格式`)
  return version
}

export function normalizeV5AppProfile(profile = DEFAULT_V5_APP_PROFILE) {
  const id = String(profile || DEFAULT_V5_APP_PROFILE).trim()
  if (!isV5AppProfile(id)) throw new Error(`v5 app profile 不受支持: ${id || '(empty)'}`)
  return id
}

export function getV5AppProfile(config, profile = DEFAULT_V5_APP_PROFILE) {
  const id = normalizeV5AppProfile(profile)
  const profileConfig = config.profiles?.[id]
  if (!profileConfig) throw new Error(`v5 app profile 缺失: ${id}`)
  return { id, ...profileConfig }
}

export function defaultV5AppStageDir(config, profile = DEFAULT_V5_APP_PROFILE) {
  return path.join(config.appDir, getV5AppProfile(config, profile).stageDir)
}

function validateCommands(commands) {
  if (!Array.isArray(commands)) throw new Error('commands 必须是数组')
  const seen = new Set()
  return commands.map(command => {
    const id = String(command?.id || '').trim()
    const title = String(command?.title || '').trim()
    if (!isSafeId(id)) throw new Error(`command id 不合法: ${id}`)
    if (!title || title.length > 80) throw new Error(`command title 不合法: ${id}`)
    if (seen.has(id)) throw new Error(`command id 重复: ${id}`)
    seen.add(id)
    return { id, title }
  })
}

function buildRuntimeManifest(config, version) {
  return {
    type: config.type,
    id: config.id,
    name: config.name,
    description: config.description,
    version,
    package: {
      windowsExecutable: normalizeRel(config.executable, 'executable'),
      icon: normalizeRel(config.icon, 'icon'),
    },
    displayMode: config.displayMode,
    commands: validateCommands(config.commands || []),
  }
}

async function validateStagedV5App(packageRoot, manifest, exemptions = []) {
  if (manifest.type !== 'desktop-app') throw new Error(`fw-app.type 必须为 desktop-app: ${manifest.type}`)
  const executable = normalizeRel(manifest.package.windowsExecutable, 'fw-app.package.windowsExecutable')
  const icon = normalizeRel(manifest.package.icon, 'fw-app.package.icon')
  if (!(await exists(path.join(packageRoot, executable)))) throw new Error(`windowsExecutable 不存在: ${executable}`)
  if (!(await exists(path.join(packageRoot, icon)))) throw new Error(`icon 不存在: ${icon}`)
  if (!getV5AppIconMime(icon)) throw new Error(`fw-app.package.icon 必须是受支持的图片格式: ${icon}`)
  if (!(await exists(path.join(packageRoot, 'fw-app.json')))) throw new Error('staging 目录缺少 fw-app.json')
  await assertNoReservedPackageDataDir(packageRoot, exemptions)
}

async function writeRuntimeManifest(packageRoot, manifest) {
  await fs.writeFile(path.join(packageRoot, 'fw-app.json'), JSON.stringify(manifest, null, 2) + '\n', 'utf8')
}

async function populateV5AppStageDir(config, profileConfig, packageRoot, version) {
  await fs.mkdir(packageRoot, { recursive: true })

  for (const file of profileConfig.files) {
    const fromRel = normalizeRel(file.from, 'files.from')
    const toRel = normalizeRel(file.to, 'files.to')
    await copyEntry(path.join(config.appDir, fromRel), path.join(packageRoot, toRel))
  }

  const manifest = buildRuntimeManifest(config, version)
  await writeRuntimeManifest(packageRoot, manifest)
  await validateStagedV5App(packageRoot, manifest, config.reservedNameExemptions)
  return manifest
}

export async function stageV5AppPackage(config, opts = {}) {
  const profile = getV5AppProfile(config, opts.profile)
  if (!opts.noBuild) {
    const runOpts = opts.env ? { env: opts.env } : {}
    await run(profile.buildCommand.command, profile.buildCommand.args, config.appDir, runOpts)
  }

  const version = await loadV5AppVersion(config)
  const stageDir = path.resolve(config.appDir, String(opts.stageDir || defaultV5AppStageDir(config, profile.id)))
  const parent = path.dirname(stageDir)
  const base = path.basename(stageDir)
  const packageDir = v5AppStagePackageDir(stageDir)
  const tmpDir = path.join(stageDir, `.tmp-stage-package-${base}-${Date.now()}`)
  await fs.mkdir(parent, { recursive: true })
  await prepareStageContainer(stageDir)
  await fs.rm(tmpDir, { recursive: true, force: true })
  await fs.mkdir(tmpDir, { recursive: true })

  try {
    const manifest = await populateV5AppStageDir(config, profile, tmpDir, version)
    await replaceDirAtomic(tmpDir, packageDir)
    return {
      appId: config.id,
      profile: profile.id,
      version,
      stageDir,
      packageDir,
      executablePath: path.join(packageDir, manifest.package.windowsExecutable),
      manifestPath: path.join(packageDir, 'fw-app.json'),
      manifest,
    }
  } catch (error) {
    await fs.rm(tmpDir, { recursive: true, force: true }).catch(() => {})
    throw error
  }
}

// 成品产出边界：装配 release 包并输出扁平商店基础包，发布由上层的中央工具负责。
export async function buildV5AppPackage(config, opts) {
  const profile = normalizeV5AppProfile(opts?.profile)
  if (profile !== DEFAULT_V5_APP_PROFILE) throw new Error('v5 app 正式打包只允许 release profile')

  const staged = await stageV5AppPackage(config, {
    noBuild: opts?.noBuild,
    profile,
    stageDir: opts?.stageDir,
    env: opts?.env,
  })
  const { version } = staged
  const outDir = String(opts?.outDir || DEFAULT_V5_APP_OUT_DIR)

  const zipName = `${config.id}-${version}-windows.zip`
  const zipPath = path.join(outDir, zipName)
  await zipDirContents(staged.packageDir, zipPath)

  const sha256 = await sha256FileHex(zipPath)
  const sizeBytes = (await fs.stat(zipPath)).size

  return {
    appId: config.id,
    version,
    zipName,
    zipPath,
    sha256,
    sizeBytes,
    stageDir: staged.stageDir,
    manifest: staged.manifest,
  }
}
