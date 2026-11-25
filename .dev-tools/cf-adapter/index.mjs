import crypto from 'node:crypto'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import process from 'node:process'
import { execFileSync, spawn, spawnSync } from 'node:child_process'

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
      if ((code ?? 0) === 0) resolve()
      else reject(new Error(`${command} ${args.join(' ')} 失败（退出码 ${code}）`))
    })
  })
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
    } catch {
      // ignore
    }
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

function resolveMsvcClExe() {
  if (process.platform !== 'win32') return ''
  try {
    const vswhere = path.join(
      process.env['ProgramFiles(x86)'] || 'C:\\Program Files (x86)',
      'Microsoft Visual Studio',
      'Installer',
      'vswhere.exe',
    )
    if (!fs.existsSync(vswhere)) return ''
    const vsRoot = execFileSync(
      vswhere,
      ['-latest', '-products', '*', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'],
      { encoding: 'utf8' },
    ).trim()
    if (!vsRoot) return ''
    const msvcBase = path.join(vsRoot, 'VC', 'Tools', 'MSVC')
    if (!fs.existsSync(msvcBase)) return ''
    const versions = fs.readdirSync(msvcBase).sort()
    for (let i = versions.length - 1; i >= 0; i -= 1) {
      const cand = path.join(msvcBase, versions[i], 'bin', 'Hostx64', 'x64', 'cl.exe')
      if (fs.existsSync(cand)) return cand
    }
  } catch {
    // ignore
  }
  return ''
}

function configureBuildAcceleration(env, depsStore, flutterBuildDir) {
  const cpus = String(Math.max(4, os.cpus().length))
  env.CMAKE_BUILD_PARALLEL_LEVEL = cpus

  const sccacheBin = findSccacheBin(env.PATH || env.Path)
  const propsPath = flutterBuildDir ? path.join(flutterBuildDir, 'Directory.Build.props') : ''
  const targetsPath = flutterBuildDir ? path.join(flutterBuildDir, 'Directory.Build.targets') : ''

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
    } catch {
      // ignore start errors; sccache client retries transparently
    }
  }

  if (!flutterBuildDir || process.platform !== 'win32') return

  fs.mkdirSync(flutterBuildDir, { recursive: true })
  const clExe = sccacheBin ? resolveMsvcClExe() : ''
  if (sccacheBin && clExe) {
    const toolsDir = path.join(depsStore, 'sccache-tools')
    fs.mkdirSync(toolsDir, { recursive: true })
    fs.writeFileSync(path.join(toolsDir, 'sccache-cl.cmd'), `@echo off\r\n"${sccacheBin}" "${clExe}" %*\r\n`, 'ascii')
    fs.writeFileSync(
      propsPath,
      `<Project>
  <PropertyGroup>
    <CLToolExe>sccache-cl.cmd</CLToolExe>
    <CLToolPath>${toolsDir}</CLToolPath>
    <TrackFileAccess>false</TrackFileAccess>
    <UseMultiToolTask>true</UseMultiToolTask>
    <EnforceProcessCountAcrossBuilds>true</EnforceProcessCountAcrossBuilds>
  </PropertyGroup>
</Project>
`,
      'utf8',
    )
    fs.writeFileSync(
      targetsPath,
      `<Project>
  <ItemDefinitionGroup>
    <ClCompile>
      <DebugInformationFormat>OldStyle</DebugInformationFormat>
    </ClCompile>
  </ItemDefinitionGroup>
</Project>
`,
      'utf8',
    )
    delete env.CL
  } else {
    // Graceful fallback without sccache: keep multi-core MSBuild parallelism
    fs.writeFileSync(
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
    if (fs.existsSync(targetsPath)) {
      try { fs.unlinkSync(targetsPath) } catch {}
    }
  }
}

function flutterEnv(depsStore, buildDir, flutterBuildDir) {
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
    configureBuildAcceleration(env, depsStore, flutterBuildDir)
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
    if (fs.existsSync(abs)) {
      snap.set(abs, fs.readFileSync(abs))
    }
  }
  return snap
}

function restoreGeneratedFiles(snap) {
  for (const [abs, origBuf] of snap.entries()) {
    try {
      const curBuf = fs.existsSync(abs) ? fs.readFileSync(abs) : null
      if (!curBuf || !curBuf.equals(origBuf)) {
        fs.writeFileSync(abs, origBuf)
      }
    } catch {
      // ignore restore errors
    }
  }
}

async function unlinkIfJunction(targetPath) {
  try {
    const st = fs.lstatSync(targetPath)
    if (st.isSymbolicLink()) {
      fs.unlinkSync(targetPath)
      return true
    }
  } catch {
    // ignore missing path
  }
  return false
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
      return await fn(worktree)
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
    } catch {
      // race with another process or unavailable letter; try next
    }
  }

  const shortRoot = drive ? path.join(`${drive}\\`, 'app') : worktree
  try {
    return await fn(shortRoot)
  } finally {
    if (drive) {
      try {
        execFileSync('subst', [drive, '/D'], { stdio: 'ignore' })
      } catch {
        // ignore detach errors
      }
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
  for (const dir of [depsDir, path.join(depsStore, 'pub'), path.join(depsStore, 'cargo')]) {
    await fsp.mkdir(dir, { recursive: true })
  }
  const snap = snapshotGeneratedFiles(worktree)
  try {
    await spawnCmd('flutter', ['pub', 'get'], {
      cwd: worktree,
      env: flutterEnv(depsStore),
    })
  } finally {
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
  const env = flutterEnv(depsStore, buildDir, flutterBuildDir)
  const snap = snapshotGeneratedFiles(worktree)
  try {
    await withCanonicalBuildEnv(worktree, buildDir, flutterBuildDir, async shortRoot => {
      const stageScript = path.join(shortRoot, 'scripts', 'stage-app.mjs')
      const nodeOpts = [env.NODE_OPTIONS, '--preserve-symlinks', '--preserve-symlinks-main'].filter(Boolean).join(' ')
      await spawnCmd('node', ['--preserve-symlinks', '--preserve-symlinks-main', stageScript, '--profile', 'release', '--stage-dir', stageDir], {
        cwd: shortRoot,
        env: { ...env, NODE_OPTIONS: nodeOpts },
      })
    })
    const manifest = JSON.parse(fs.readFileSync(path.join(worktree, '.fast-window-dev-protocol', 'fw-app.json'), 'utf8'))
    const exeName = String(manifest?.package?.windowsExecutable || '').trim()
    const exePath = path.join(stageDir, 'package', exeName)
    if (!exeName || !fs.existsSync(exePath)) {
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
