import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import process from 'node:process'
import { execFileSync, spawn } from 'node:child_process'

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

function flutterEnv(depsStore, buildDir) {
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
  }
  return env
}

const GENERATED_TRACKED_FILES = [
  'pubspec.lock',
  'linux/flutter/generated_plugin_registrant.cc',
  'linux/flutter/generated_plugin_registrant.h',
  'linux/flutter/generated_plugins.cmake',
  'macos/Flutter/GeneratedPluginRegistrant.swift',
  'windows/flutter/generated_plugin_registrant.cc',
  'windows/flutter/generated_plugin_registrant.h',
  'windows/flutter/generated_plugins.cmake',
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

async function withShortWorktreePath(worktree, fn) {
  if (process.platform !== 'win32') {
    return await fn(worktree)
  }
  const letters = ['Z', 'Y', 'X', 'W', 'V', 'U', 'T', 'S', 'R', 'Q', 'P', 'O', 'N', 'M']
  let drive = ''
  for (const letter of letters) {
    const candidate = `${letter}:`
    if (fs.existsSync(`${candidate}\\`)) continue
    try {
      execFileSync('subst', [candidate, path.dirname(worktree)], { stdio: 'ignore' })
      drive = candidate
      break
    } catch {
      // race with another process or unavailable letter; try next
    }
  }
  if (!drive) {
    return await fn(worktree)
  }
  try {
    return await fn(path.join(`${drive}\\`, path.basename(worktree)))
  } finally {
    try {
      execFileSync('subst', [drive, '/D'], { stdio: 'ignore' })
    } catch {
      // ignore detach errors
    }
  }
}

async function cleanupBuildOutput(worktree) {
  for (const rel of ['build', 'dist-app', '.tmp', path.join('plugins', 'rhttp', 'rhttp', 'rust', 'target')]) {
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
  const stageDir = path.join(buildDir, 'stage')
  await fsp.mkdir(buildDir, { recursive: true })
  const env = flutterEnv(depsStore, buildDir)
  const snap = snapshotGeneratedFiles(worktree)
  try {
    await withShortWorktreePath(worktree, async shortRoot => {
      const stageScript = path.join(shortRoot, 'scripts', 'stage-app.mjs')
      await spawnCmd('node', [stageScript, '--profile', 'release', '--stage-dir', stageDir], {
        cwd: shortRoot,
        env,
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
    await cleanupBuildOutput(worktree)
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
