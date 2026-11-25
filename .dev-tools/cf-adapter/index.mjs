import crypto from 'node:crypto'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { execFileSync, spawn, spawnSync } from 'node:child_process'

const VERIFY_PROFILE = 'dev'
const VERIFY_CMAKE_CONFIG = 'Debug'

function emit(payload, exitCode) {
  process.stdout.write(`${JSON.stringify(payload)}\n`)
  process.exit(exitCode)
}

function ok(data) {
  emit(data === undefined ? { status: 'ok' } : { status: 'ok', data }, 0)
}

function fail(reason) {
  emit({ status: 'failed', reason: String(reason || '未知错误') }, 1)
}

function requireEnv(name) {
  const value = String(process.env[name] || '').trim()
  if (!value) throw new Error(`缺少必需环境变量 ${name}`)
  return value
}

function cmdQuote(value) {
  const raw = String(value)
  if (!raw) return '""'
  if (!/[\s"^&|<>%]/.test(raw)) return raw
  return `"${raw.replaceAll('%', '%%').replace(/["^]/g, m => `^${m}`)}"`
}

function spawnCmd(command, args, opts = {}) {
  return new Promise((resolve, reject) => {
    let specCommand = command
    let specArgs = args
    if (process.platform === 'win32' && (command === 'flutter' || command === 'dart')) {
      specCommand = process.env.ComSpec || 'cmd.exe'
      specArgs = ['/d', '/s', '/c', [`${command}.bat`, ...args].map(cmdQuote).join(' ')]
    }
    process.stderr.write(`[cf-adapter] (${opts.cwd || process.cwd()}) ${command} ${args.join(' ')}\n`)
    const child = spawn(specCommand, specArgs, {
      stdio: ['ignore', process.stderr, process.stderr],
      shell: false,
      ...opts,
    })
    child.on('error', reject)
    child.on('exit', code => {
      const okCodes = opts.okExitCodes || [0]
      if (okCodes.includes(code ?? 0)) resolve()
      else reject(new Error(`${command} ${args.join(' ')} 失败（退出码 ${code}）`))
    })
  })
}

async function runRobocopy(src, dst, extraFlags = ['/E']) {
  await fsp.mkdir(dst, { recursive: true })
  const args = [src, dst, ...extraFlags, '/MT:32', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/NC', '/NS']
  await spawnCmd('robocopy', args, { okExitCodes: [0, 1, 2, 3, 4, 5, 6, 7] })
}

function resolveNugetExeDir(currentPath) {
  if (process.platform !== 'win32') return ''
  const dirs = String(currentPath || '').split(';').map(s => s.trim()).filter(Boolean)
  for (const dir of dirs) {
    if (fs.existsSync(path.join(dir, 'nuget.exe'))) return ''
  }
  for (const dir of dirs) {
    const cmdPath = path.join(dir, 'nuget.cmd')
    if (!fs.existsSync(cmdPath)) continue
    try {
      const text = fs.readFileSync(cmdPath, 'utf8')
      const m = text.match(/"([^"]+\\nuget\.exe)"/i) || text.match(/rem\s+target:\s*(.+nuget\.exe)/i)
      if (m && fs.existsSync(m[1].trim())) {
        return path.dirname(m[1].trim())
      }
    } catch {}
  }
  return ''
}

function findSccacheBin(currentPath) {
  const exeName = process.platform === 'win32' ? 'sccache.exe' : 'sccache'
  const sep = process.platform === 'win32' ? ';' : ':'
  for (const dir of String(currentPath || '').split(sep).map(s => s.trim()).filter(Boolean)) {
    const candidate = path.join(dir, exeName)
    if (fs.existsSync(candidate)) return candidate
  }
  return ''
}

function spaceSccachePort(depsStore) {
  const hash = crypto.createHash('sha256').update(path.resolve(depsStore).toLowerCase()).digest()
  const num = hash.readUInt16BE(0)
  return 42300 + (num % 10000)
}

function resolveVsCmakeExe() {
  if (process.platform === 'win32') {
    try {
      const vswhere = path.join(
        process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)',
        'Microsoft Visual Studio',
        'Installer',
        'vswhere.exe',
      )
      if (fs.existsSync(vswhere)) {
        const vsRoot = execFileSync(
          vswhere,
          ['-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'],
          { encoding: 'utf8' },
        ).trim()
        if (vsRoot) {
          const cand = path.join(vsRoot, 'Common7', 'IDE', 'CommonExtensions', 'Microsoft', 'CMake', 'CMake', 'bin', 'cmake.exe')
          if (fs.existsSync(cand)) return cand
        }
      }
    } catch {}
  }
  return 'cmake'
}

function writeFileIfChanged(filePath, content, encoding = 'utf8') {
  try {
    if (fs.existsSync(filePath) && fs.readFileSync(filePath, encoding) === content) return false
  } catch {}
  fs.writeFileSync(filePath, content, encoding)
  return true
}

function configureBuildAcceleration(env, depsStore, flutterBuildDir, fastIncremental = false) {
  const cpus = String(Math.max(4, os.cpus().length))
  env.CMAKE_BUILD_PARALLEL_LEVEL = cpus

  const sccacheBin = findSccacheBin(env.PATH || env.Path)
  if (sccacheBin) {
    const cacheDir = path.join(depsStore, 'sccache')
    fs.mkdirSync(cacheDir, { recursive: true })
    env.RUSTC_WRAPPER = sccacheBin
    env.SCCACHE_DIR = cacheDir
    env.SCCACHE_SERVER_PORT = String(spaceSccachePort(depsStore))
    env.SCCACHE_IDLE_TIMEOUT = '180'
    env.SCCACHE_CACHE_SIZE = '4G'
    env.CARGO_INCREMENTAL = '0'
    try {
      spawnSync(sccacheBin, ['--start-server'], { env, stdio: 'ignore' })
    } catch {}
  }

  if (!flutterBuildDir || process.platform !== 'win32') return
  fs.mkdirSync(flutterBuildDir, { recursive: true })
  const propsPath = path.join(flutterBuildDir, 'Directory.Build.props')
  const targetsPath = path.join(flutterBuildDir, 'Directory.Build.targets')

  // Use native cl.exe with UseMultiToolTask=true AND TrackFileAccess=true (default)
  // so MSBuild writes real .tlog files and seeded branches skip 100% of unchanged C++ plugins!
  writeFileIfChanged(
    propsPath,
    `<Project>
  <PropertyGroup>
    <UseMultiToolTask>true</UseMultiToolTask>
    <EnforceProcessCountAcrossBuilds>true</EnforceProcessCountAcrossBuilds>
  </PropertyGroup>
</Project>
`,
    'utf8',
  )

  const hasSeededPackages = fs.existsSync(path.join(flutterBuildDir, 'windows', 'x64', 'packages', 'Microsoft.Web.WebView2'))
  const skipNuget = fastIncremental && hasSeededPackages
    ? `  <PropertyGroup Condition="'$(MSBuildProjectName)' == 'flutter_inappwebview_windows_DEPS'">\n    <PreBuildEventUseInBuild>false</PreBuildEventUseInBuild>\n  </PropertyGroup>\n`
    : ''

  // Suppress Debug PDB/ILK emission so Debug outputs match fw-app.build.json dev profile with 0 repo edits
  writeFileIfChanged(
    targetsPath,
    `<Project>
  <ItemDefinitionGroup>
    <ClCompile>
      <DebugInformationFormat>None</DebugInformationFormat>
    </ClCompile>
    <Link>
      <GenerateDebugInformation>false</GenerateDebugInformation>
      <LinkIncremental>false</LinkIncremental>
    </Link>
  </ItemDefinitionGroup>
${skipNuget}</Project>
`,
    'utf8',
  )
  delete env.CL
}

function flutterEnv(depsStore, buildDir, flutterBuildDir, fastIncremental = false) {
  const env = { ...process.env }
  const nugetDir = resolveNugetExeDir(env.PATH || env.Path)
  if (nugetDir) {
    const key = Object.keys(env).find(k => k.toLowerCase() === 'path') || 'PATH'
    env[key] = `${nugetDir};${env[key] || ''}`
  }
  env.PUB_CACHE = path.join(depsStore, 'pub')
  env.GIT_CONFIG_COUNT = '1'
  env.GIT_CONFIG_KEY_0 = 'core.longpaths'
  env.GIT_CONFIG_VALUE_0 = 'true'
  env.CARGO_HOME = path.join(depsStore, 'cargo')
  if (buildDir) {
    env.CARGO_TARGET_DIR = path.join(buildDir, 'cargo-target')
    configureBuildAcceleration(env, depsStore, flutterBuildDir, fastIncremental)
  }
  return env
}

const GENERATED_TRACKED_FILES = [
  "pubspec.lock",
  "linux/flutter/generated_plugin_registrant.cc",
  "linux/flutter/generated_plugin_registrant.h",
  "linux/flutter/generated_plugins.cmake",
  "macos/Flutter/GeneratedPluginRegistrant.swift",
  "windows/flutter/generated_plugin_registrant.cc",
  "windows/flutter/generated_plugin_registrant.h",
  "windows/flutter/generated_plugins.cmake",
]

function snapshotGeneratedFiles(worktree) {
  const snap = new Map()
  for (const rel of GENERATED_TRACKED_FILES) {
    const abs = path.join(worktree, rel)
    if (fs.existsSync(abs)) snap.set(abs, fs.readFileSync(abs))
  }
  return snap
}

function restoreGeneratedFiles(snap) {
  for (const [abs, origBuf] of snap.entries()) {
    try {
      const curBuf = fs.existsSync(abs) ? fs.readFileSync(abs) : null
      if (!curBuf || !curBuf.equals(origBuf)) fs.writeFileSync(abs, origBuf)
    } catch {}
  }
}

async function unlinkIfJunction(targetPath) {
  try {
    const st = fs.lstatSync(targetPath)
    if (st.isSymbolicLink()) {
      fs.unlinkSync(targetPath)
      return true
    }
  } catch {}
  return false
}

function hashFiles(worktree, relPaths) {
  const hash = crypto.createHash('sha256')
  for (const rel of relPaths) {
    const abs = path.join(worktree, rel)
    hash.update(rel + '\0')
    if (fs.existsSync(abs)) hash.update(fs.readFileSync(abs))
    else hash.update('<MISSING>')
    hash.update('\0')
  }
  return hash.digest('hex')
}

function computePubLockHash(worktree) {
  return hashFiles(worktree, ['pubspec.yaml', 'pubspec.lock'])
}

function computeBuildGraphFingerprint(worktree) {
  return hashFiles(worktree, [
    'pubspec.yaml',
    'pubspec.lock',
    'windows/CMakeLists.txt',
    'windows/flutter/CMakeLists.txt',
    'windows/flutter/generated_plugins.cmake',
    'windows/runner/CMakeLists.txt',
    'fw-app.build.json',
  ])
}

function computeWindowsSourceHashes(worktree) {
  const winRoot = path.join(worktree, 'windows')
  const map = {}
  if (!fs.existsSync(winRoot)) return map
  const walk = (dir, relBase) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (e.name === 'ephemeral' || e.name === '.plugin_symlinks') continue
      const fp = path.join(dir, e.name)
      const rel = relBase ? `${relBase}/${e.name}` : e.name
      if (e.isDirectory()) walk(fp, rel)
      else if (e.isFile()) map[rel] = crypto.createHash('sha256').update(fs.readFileSync(fp)).digest('hex')
    }
  }
  walk(winRoot, '')
  return map
}

async function alignUnchangedWindowsMtimes(worktree, flutterBuildDir, exeName, seedWindowsHashes) {
  if (!seedWindowsHashes) return 0
  const seedExe = path.join(flutterBuildDir, 'windows', 'x64', 'runner', VERIFY_CMAKE_CONFIG, exeName)
  const seedCache = path.join(flutterBuildDir, 'windows', 'x64', 'CMakeCache.txt')
  const candidates = [seedCache, seedExe].filter(p => fs.existsSync(p)).map(p => fs.statSync(p).mtimeMs)
  if (candidates.length === 0) return 0
  const targetDate = new Date(Math.min(...candidates) - 10000)
  let aligned = 0
  for (const [rel, expectedSha] of Object.entries(seedWindowsHashes)) {
    const abs = path.join(worktree, 'windows', rel)
    if (!fs.existsSync(abs)) continue
    try {
      const actualSha = crypto.createHash('sha256').update(fs.readFileSync(abs)).digest('hex')
      if (actualSha === expectedSha) {
        await fsp.utimes(abs, targetDate, targetDate)
        aligned += 1
      }
    } catch {}
  }
  return aligned
}

async function touchCmakeGenerateStamps(flutterBuildDir) {
  const x64Dir = path.join(flutterBuildDir, 'windows', 'x64')
  if (!fs.existsSync(x64Dir)) return 0
  const now = new Date()
  let touched = 0
  const stack = [x64Dir]
  while (stack.length > 0) {
    const cur = stack.pop()
    let entries
    try { entries = fs.readdirSync(cur, { withFileTypes: true }) } catch { continue }
    for (const e of entries) {
      const fp = path.join(cur, e.name)
      if (e.isDirectory()) {
        if (e.name !== 'packages') stack.push(fp)
      } else if (e.isFile() && (e.name === 'generate.stamp' || e.name === 'generate.stamp.depend' || e.name === 'generate.stamp.list')) {
        await fsp.utimes(fp, now, now)
        touched += 1
      }
    }
  }
  return touched
}

const PUB_LOCK_META_FILES = [
  '.dart_tool/package_config.json',
  '.dart_tool/package_graph.json',
  '.dart_tool/version',
  '.flutter-plugins',
  '.flutter-plugins-dependencies',
]

async function snapshotPubLockCache(worktree, depsStore) {
  const lockHash = computePubLockHash(worktree)
  const entryDir = path.join(depsStore, 'pub-lock-cache', lockHash)
  const tmpDir = path.join(depsStore, 'pub-lock-cache', `${lockHash}.tmp.${process.pid}.${Date.now()}`)
  await fsp.mkdir(tmpDir, { recursive: true })
  try {
    for (const rel of PUB_LOCK_META_FILES) {
      const src = path.join(worktree, rel)
      if (fs.existsSync(src)) {
        const dst = path.join(tmpDir, rel)
        await fsp.mkdir(path.dirname(dst), { recursive: true })
        await fsp.copyFile(src, dst)
      }
    }
    const symlinksDir = path.join(worktree, 'windows', 'flutter', 'ephemeral', '.plugin_symlinks')
    const links = {}
    if (fs.existsSync(symlinksDir)) {
      for (const entry of fs.readdirSync(symlinksDir)) {
        try { links[entry] = fs.realpathSync(path.join(symlinksDir, entry)) } catch {}
      }
    }
    await fsp.writeFile(path.join(tmpDir, 'plugin_symlinks.json'), JSON.stringify(links, null, 2) + '\n', 'utf8')
    if (fs.existsSync(entryDir)) await fsp.rm(entryDir, { recursive: true, force: true }).catch(() => {})
    await fsp.rename(tmpDir, entryDir)
  } catch {
    await fsp.rm(tmpDir, { recursive: true, force: true }).catch(() => {})
  }
}

async function restorePubLockCacheIfHit(worktree, depsStore) {
  if (process.platform !== 'win32') return false
  const lockHash = computePubLockHash(worktree)
  const entryDir = path.join(depsStore, 'pub-lock-cache', lockHash)
  const pkgCfg = path.join(entryDir, '.dart_tool', 'package_config.json')
  const pkgGraph = path.join(entryDir, '.dart_tool', 'package_graph.json')
  const symlinksJson = path.join(entryDir, 'plugin_symlinks.json')
  if (!fs.existsSync(pkgCfg) || !fs.existsSync(pkgGraph) || !fs.existsSync(symlinksJson)) return false

  // Verify every symlink target still exists inside PUB_CACHE/worktree
  const links = JSON.parse(fs.readFileSync(symlinksJson, 'utf8'))
  for (const target of Object.values(links)) {
    if (!fs.existsSync(target)) return false
  }

  for (const rel of PUB_LOCK_META_FILES) {
    const src = path.join(entryDir, rel)
    if (fs.existsSync(src)) {
      const dst = path.join(worktree, rel)
      await fsp.mkdir(path.dirname(dst), { recursive: true })
      await fsp.copyFile(src, dst)
    }
  }
  const symlinksDir = path.join(worktree, 'windows', 'flutter', 'ephemeral', '.plugin_symlinks')
  await fsp.mkdir(symlinksDir, { recursive: true })
  for (const [name, target] of Object.entries(links)) {
    const dst = path.join(symlinksDir, name)
    await unlinkIfJunction(dst)
    if (fs.existsSync(dst)) await fsp.rm(dst, { recursive: true, force: true })
    fs.symlinkSync(target, dst, 'junction')
  }
  process.stderr.write(`[cf-adapter] 命中空间级 Flutter pub 快照 (${lockHash.slice(0, 12)})，秒级恢复\n`)
  return true
}

function readFlutterSeedMeta(depsStore) {
  const metaPath = path.join(depsStore, 'seed-flutter-meta.json')
  if (!fs.existsSync(metaPath)) return null
  try { return JSON.parse(fs.readFileSync(metaPath, 'utf8')) } catch { return null }
}

async function restoreSeedIntoBranch(worktree, depsStore, flutterBuildDir) {
  const seedBuild = path.join(depsStore, 'seed-flutter-build-dev')
  const seedEph = path.join(depsStore, 'seed-flutter-ephemeral-dev')
  const seedDartTool = path.join(depsStore, 'seed-flutter-dart-tool-dev')
  process.stderr.write('[cf-adapter] 命中仓内 Flutter 基线底稿，快速复制到当前分支构建区\n')
  await runRobocopy(seedBuild, flutterBuildDir, ['/E'])
  if (fs.existsSync(seedEph)) {
    await runRobocopy(seedEph, path.join(worktree, 'windows', 'flutter', 'ephemeral'), ['/E'])
  }
  if (fs.existsSync(seedDartTool)) {
    await runRobocopy(seedDartTool, path.join(worktree, '.dart_tool', 'flutter_build'), ['/E'])
  }
}

async function snapshotFlutterDevSeed(worktree, depsStore, flutterBuildDir, buildGraphFp) {
  const seedBuild = path.join(depsStore, 'seed-flutter-build-dev')
  const seedEph = path.join(depsStore, 'seed-flutter-ephemeral-dev')
  const seedDartTool = path.join(depsStore, 'seed-flutter-dart-tool-dev')
  const metaPath = path.join(depsStore, 'seed-flutter-meta.json')
  const stamp = `${process.pid}.${Date.now()}`
  const tmpBuild = path.join(depsStore, `seed-flutter-build-dev.tmp.${stamp}`)
  const tmpEph = path.join(depsStore, `seed-flutter-ephemeral-dev.tmp.${stamp}`)
  const tmpDart = path.join(depsStore, `seed-flutter-dart-tool-dev.tmp.${stamp}`)
  try {
    process.stderr.write('[cf-adapter] 写入仓内 Flutter 基线底稿供后续新分支分钟级复用\n')
    await runRobocopy(flutterBuildDir, tmpBuild, ['/MIR'])
    const srcEph = path.join(worktree, 'windows', 'flutter', 'ephemeral')
    if (fs.existsSync(srcEph)) await runRobocopy(srcEph, tmpEph, ['/E', '/XD', '.plugin_symlinks'])
    const srcDart = path.join(worktree, '.dart_tool', 'flutter_build')
    if (fs.existsSync(srcDart)) await runRobocopy(srcDart, tmpDart, ['/E'])

    const swapDir = async (tmp, dst) => {
      if (!fs.existsSync(tmp)) return
      const old = `${dst}.old.${stamp}`
      if (fs.existsSync(dst)) await fsp.rename(dst, old).catch(() => fsp.rm(dst, { recursive: true, force: true }))
      await fsp.rename(tmp, dst)
      if (fs.existsSync(old)) await fsp.rm(old, { recursive: true, force: true }).catch(() => {})
    }
    await swapDir(tmpBuild, seedBuild)
    await swapDir(tmpEph, seedEph)
    await swapDir(tmpDart, seedDartTool)
    await fsp.writeFile(
      metaPath,
      JSON.stringify({
        version: 'flutter-dev-seed-v1',
        buildGraphFingerprint: buildGraphFp,
        windowsSourceHashes: computeWindowsSourceHashes(worktree),
        updatedAt: new Date().toISOString(),
      }, null, 2) + '\n',
      'utf8',
    )
  } catch (err) {
    process.stderr.write(`[cf-adapter] 写入 Flutter 基线底稿跳过（不影响本次构建）: ${err.message}\n`)
    for (const d of [tmpBuild, tmpEph, tmpDart]) await fsp.rm(d, { recursive: true, force: true }).catch(() => {})
  }
}

async function withCanonicalBuildEnv(worktree, buildDir, flutterBuildDir, fn) {
  await fsp.mkdir(flutterBuildDir, { recursive: true })
  const buildLink = path.join(worktree, 'build')
  const wasLink = await unlinkIfJunction(buildLink)
  if (!wasLink && fs.existsSync(buildLink)) {
    await fsp.rm(buildLink, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 })
  }

  if (process.platform !== 'win32') {
    fs.symlinkSync(flutterBuildDir, buildLink, 'dir')
    try {
      return await fn(worktree, false)
    } finally {
      await unlinkIfJunction(buildLink)
    }
  }

  fs.symlinkSync(flutterBuildDir, buildLink, 'junction')

  const mountRoot = path.join(buildDir, `_subst_${process.pid}_${Date.now()}`)
  await fsp.mkdir(mountRoot, { recursive: true })
  const appLink = path.join(mountRoot, 'app')
  fs.symlinkSync(worktree, appLink, 'junction')

  const letters = ['Z', 'Y', 'X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q', 'P', 'O', 'N', 'M']
  let drive = ''
  for (const letter of letters) {
    const candidate = `${letter}:`
    if (fs.existsSync(`${candidate}\\`)) continue
    try {
      execFileSync('subst', [candidate, mountRoot], { stdio: 'ignore' })
      drive = candidate
      break
    } catch {}
  }

  const shortRoot = drive ? path.join(`${drive}\\`, 'app') : worktree
  try {
    return await fn(shortRoot, drive === 'Z:')
  } finally {
    if (drive) {
      try { execFileSync('subst', [drive, '/D'], { stdio: 'ignore' }) } catch {}
    }
    await unlinkIfJunction(appLink)
    await fsp.rm(mountRoot, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 }).catch(() => {})
    await unlinkIfJunction(buildLink)
  }
}

async function cleanupWorktreeIntermediates(worktree) {
  await unlinkIfJunction(path.join(worktree, 'build'))
  for (const rel of ['dist-app', '.tmp', path.join('plugins', 'rhttp', 'rhttp', 'rust', 'target')]) {
    await fsp.rm(path.join(worktree, rel), { recursive: true, force: true, maxRetries: 5, retryDelay: 200 })
  }
}

async function cmdDeps() {
  const worktree = requireEnv('EUCLI_CF_WORKTREE')
  const depsDir = requireEnv('EUCLI_CF_DEPS_DIR')
  const depsStore = requireEnv('EUCLI_CF_DEPS_STORE')
  for (const dir of [depsDir, path.join(depsStore, 'pub'), path.join(depsStore, 'cargo'), path.join(depsStore, 'pub-lock-cache')]) {
    await fsp.mkdir(dir, { recursive: true })
  }

  if (await restorePubLockCacheIfHit(worktree, depsStore)) {
    return
  }

  const snap = snapshotGeneratedFiles(worktree)
  try {
    await spawnCmd('flutter', ['pub', 'get'], {
      cwd: worktree,
      env: flutterEnv(depsStore),
    })
    await snapshotPubLockCache(worktree, depsStore)
  } finally {
    const depBuildPath = path.join(worktree, 'build')
    const wasLink = await unlinkIfJunction(depBuildPath)
    if (!wasLink && fs.existsSync(depBuildPath)) {
      await fsp.rm(depBuildPath, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 })
    }
    restoreGeneratedFiles(snap)
  }
}

async function cmdBuild() {
  const worktree = requireEnv('EUCLI_CF_WORKTREE')
  const buildDir = requireEnv('EUCLI_CF_BUILD_DIR')
  const depsStore = requireEnv('EUCLI_CF_DEPS_STORE')
  const flutterBuildDir = path.join(buildDir, 'flutter-build')
  const stageDir = path.join(buildDir, 'stage')
  await fsp.mkdir(buildDir, { recursive: true })
  await fsp.rm(stageDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 })

  const manifest = JSON.parse(fs.readFileSync(path.join(worktree, '.fast-window-dev-protocol', 'fw-app.json'), 'utf8'))
  const exeName = String(manifest?.package?.windowsExecutable || '').trim()
  if (!exeName) throw new Error('fw-app.json 缺少 package.windowsExecutable')

  const curFp = computeBuildGraphFingerprint(worktree)
  const seedMeta = readFlutterSeedMeta(depsStore)
  const seedBuildDir = path.join(depsStore, 'seed-flutter-build-dev')
  const seedValid = Boolean(seedMeta && seedMeta.version === 'flutter-dev-seed-v1' && seedMeta.buildGraphFingerprint === curFp && fs.existsSync(path.join(seedBuildDir, 'windows', 'x64', 'CMakeCache.txt')))

  // Clone dev seed into empty branch flutter-build
  const branchAlreadyBuilt = fs.existsSync(path.join(flutterBuildDir, 'windows', 'x64', 'CMakeCache.txt'))
  let usedSeed = false
  if (!branchAlreadyBuilt && seedValid) {
    await restoreSeedIntoBranch(worktree, depsStore, flutterBuildDir)
    usedSeed = true
  }

  const snap = snapshotGeneratedFiles(worktree)
  try {
    await withCanonicalBuildEnv(worktree, buildDir, flutterBuildDir, async (shortRoot, isCanonicalZ) => {
      const canFastPath = Boolean(
        process.platform === 'win32' &&
        isCanonicalZ &&
        seedValid &&
        fs.existsSync(path.join(flutterBuildDir, 'windows', 'x64', 'CMakeCache.txt')),
      )

      const env = flutterEnv(depsStore, buildDir, flutterBuildDir, canFastPath)
      const nodeOpts = [env.NODE_OPTIONS, '--preserve-symlinks', '--preserve-symlinks-main'].filter(Boolean).join(' ')
      const runEnv = { ...env, NODE_OPTIONS: nodeOpts }

      if (canFastPath) {
        await alignUnchangedWindowsMtimes(worktree, flutterBuildDir, exeName, seedMeta.windowsSourceHashes)
        await touchCmakeGenerateStamps(flutterBuildDir)
        const cmakeExe = resolveVsCmakeExe()
        const cmakeBuildDir = path.join(shortRoot, 'build', 'windows', 'x64')
        await spawnCmd(
          cmakeExe,
          ['--build', cmakeBuildDir, '--config', VERIFY_CMAKE_CONFIG, '--target', 'INSTALL', '--parallel', '8', '--', '/nr:false'],
          { cwd: shortRoot, env: runEnv },
        )
        const outDir = path.join(shortRoot, 'build', 'windows', 'x64', 'runner', VERIFY_CMAKE_CONFIG)
        const checkCode = `import { assertArtifactCovered } from './scripts/build-windows.mjs'; await assertArtifactCovered(${JSON.stringify(outDir)}, ${JSON.stringify(VERIFY_PROFILE)});`
        await spawnCmd(
          'node',
          ['--preserve-symlinks', '--preserve-symlinks-main', '--input-type=module', '-e', checkCode],
          { cwd: shortRoot, env: runEnv },
        )
        const stageScript = path.join(shortRoot, 'scripts', 'stage-app.mjs')
        let stageErr = null
        for (let attempt = 0; attempt < 3; attempt += 1) {
          try {
            if (attempt > 0) {
              await fsp.rm(stageDir, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 }).catch(() => {})
              await new Promise(r => setTimeout(r, 800 * attempt))
            }
            await spawnCmd(
              'node',
              ['--preserve-symlinks', '--preserve-symlinks-main', stageScript, '--profile', VERIFY_PROFILE, '--no-build', '--stage-dir', stageDir],
              { cwd: shortRoot, env: runEnv },
            )
            stageErr = null
            break
          } catch (e) {
            stageErr = e
          }
        }
        if (stageErr) throw stageErr
      } else {
        // Full dev profile build (also fixes pubspec.lock mtime > pubspec.yaml to avoid duplicate pub get)
        const yamlPath = path.join(worktree, 'pubspec.yaml')
        const lockPath = path.join(worktree, 'pubspec.lock')
        if (fs.existsSync(yamlPath) && fs.existsSync(lockPath)) {
          try {
            const ySt = fs.statSync(yamlPath)
            const lSt = fs.statSync(lockPath)
            if (lSt.mtimeMs <= ySt.mtimeMs) {
              const t = new Date(ySt.mtimeMs + 1000)
              await fsp.utimes(lockPath, t, t)
            }
          } catch {}
        }
        const stageScript = path.join(shortRoot, 'scripts', 'stage-app.mjs')
        await spawnCmd(
          'node',
          ['--preserve-symlinks', '--preserve-symlinks-main', stageScript, '--profile', VERIFY_PROFILE, '--stage-dir', stageDir],
          { cwd: shortRoot, env: runEnv },
        )
        if (isCanonicalZ && !seedValid && !usedSeed) {
          await snapshotFlutterDevSeed(worktree, depsStore, flutterBuildDir, curFp)
          await snapshotPubLockCache(worktree, depsStore)
        }
      }
    })

    const exePath = path.join(stageDir, 'package', exeName)
    if (!fs.existsSync(exePath)) {
      throw new Error(`未找到构建成品入口: ${exePath}`)
    }
    return { stageDir, packageDir: path.join(stageDir, 'package'), executable: exePath }
  } finally {
    await cleanupWorktreeIntermediates(worktree)
    restoreGeneratedFiles(snap)
  }
}

async function cmdTest() {
  const worktree = requireEnv('EUCLI_CF_WORKTREE')
  const buildDir = requireEnv('EUCLI_CF_BUILD_DIR')
  const depsStore = requireEnv('EUCLI_CF_DEPS_STORE')
  const env = flutterEnv(depsStore, buildDir)

  const manifest = JSON.parse(fs.readFileSync(path.join(worktree, '.fast-window-dev-protocol', 'fw-app.json'), 'utf8'))
  const exeName = String(manifest?.package?.windowsExecutable || '').trim()
  const exePath = path.join(buildDir, 'stage', 'package', exeName)
  if (!exeName || !fs.existsSync(exePath)) {
    throw new Error(`正式构建产物缺失: ${exePath}`)
  }

  await spawnCmd('node', ['scripts/bump-app-version.mjs', '--check'], { cwd: worktree, env })

  const testsDir = path.join(worktree, 'scripts', 'tests')
  if (fs.existsSync(testsDir)) {
    const testFiles = fs.readdirSync(testsDir).filter(f => f.endsWith('.test.mjs')).map(f => path.join('scripts', 'tests', f))
    if (testFiles.length > 0) {
      await spawnCmd('node', ['--test', ...testFiles], { cwd: worktree, env })
    }
  }
}

async function main() {
  const sub = process.argv[2]
  switch (sub) {
    case 'deps':
      await cmdDeps()
      ok()
      break
    case 'build':
      ok(await cmdBuild())
      break
    case 'start':
    case 'health':
    case 'stop':
    case 'seed':
      emit({ status: 'not-applicable' }, 0)
      break
    case 'test':
      await cmdTest()
      ok()
      break
    default:
      fail(`未知适配器子命令: ${sub || '(空)'}`)
  }
}

main().catch(err => fail(err?.message || err))
