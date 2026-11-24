import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import process from 'node:process'
import { spawn } from 'node:child_process'

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

function flutterEnv(depsStore, buildDir) {
  const env = { ...process.env }
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

async function cleanupBuildOutput(worktree) {
  for (const rel of ['build', 'dist-app', '.tmp', path.join('plugins', 'rhttp', 'rhttp', 'rust', 'target')]) {
    await fsp.rm(path.join(worktree, rel), { recursive: true, force: true })
  }
}

async function cmdDeps() {
  const worktree = requireEnv('EUCLI_CF_WORKTREE')
  const depsDir = requireEnv('EUCLI_CF_DEPS_DIR')
  const depsStore = requireEnv('EUCLI_CF_DEPS_STORE')
  for (const dir of [depsDir, path.join(depsStore, 'pub'), path.join(depsStore, 'cargo')]) {
    await fsp.mkdir(dir, { recursive: true })
  }
  await spawnCmd('flutter', ['pub', 'get'], {
    cwd: worktree,
    env: flutterEnv(depsStore),
  })
}

async function cmdBuild() {
  const worktree = requireEnv('EUCLI_CF_WORKTREE')
  const buildDir = requireEnv('EUCLI_CF_BUILD_DIR')
  const depsStore = requireEnv('EUCLI_CF_DEPS_STORE')
  const stageDir = path.join(buildDir, 'stage')
  await fsp.mkdir(buildDir, { recursive: true })
  const env = flutterEnv(depsStore, buildDir)
  try {
    await spawnCmd('node', ['scripts/stage-app.mjs', '--profile', 'release', '--stage-dir', stageDir], {
      cwd: worktree,
      env,
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
