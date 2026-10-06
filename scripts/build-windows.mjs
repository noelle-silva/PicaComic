import fs from 'node:fs/promises'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import { scriptArgs } from './lib/v5-cli-args.mjs'
import { readJson, run, rootDir } from './lib/v5-app-packaging.mjs'

const usageLine = [
  '用法：node scripts/build-windows.mjs [--profile release|dev]',
  '说明：拉取依赖 → Flutter Windows 构建 → 产物校验；stdout 输出 JSON 结果，构建日志走 stderr。',
].join('\n')

const BUILD_FLAG_BY_PROFILE = { release: '--release', dev: '--debug' }
const OUTPUT_DIR_BY_PROFILE = { release: 'Release', dev: 'Debug' }

function parseArgs(argv) {
  const out = { profile: 'release' }
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]
    if (arg === '-h' || arg === '--help') {
      console.log(usageLine)
      process.exit(0)
    }
    if (arg === '--profile' && i + 1 < argv.length) {
      const profile = String(argv[++i] || '').trim()
      if (!(profile in BUILD_FLAG_BY_PROFILE)) throw new Error(`未知 profile: ${profile || '(empty)'}`)
      out.profile = profile
      continue
    }
    throw new Error(`未知参数: ${arg}`)
  }
  return out
}

async function statType(filePath) {
  return await fs.stat(filePath).catch(() => null)
}

async function listTopLevelFiles(dir) {
  const entries = await fs.readdir(dir, { withFileTypes: true })
  return entries.filter(entry => entry.isFile()).map(entry => entry.name).sort()
}

export function collectCoveredEntryNames(files, prefix) {
  const covered = new Set()
  for (const file of files) {
    const from = String(file?.from || '').replaceAll('\\', '/')
    if (!from.startsWith(prefix)) continue
    covered.add(from.slice(prefix.length).split('/')[0])
  }
  return covered
}

// 产物覆盖校验：构建产物每个顶层条目都必须在 fw-app.build.json 的映射里出现，
// 反之映射条目也必须存在——防止插件增减后出现"没进包"或"打包缺文件"的静默偏差。
export async function assertArtifactCovered(outDir, profile, { configPath = path.join(rootDir, 'fw-app.build.json'), baseDir = rootDir } = {}) {
  const buildConfig = JSON.parse(await fs.readFile(configPath, 'utf8'))
  const profileConfig = buildConfig.profiles?.[profile]
  if (!profileConfig) throw new Error(`fw-app.build.json 缺少 profile: ${profile}`)
  const prefix = path.relative(baseDir, outDir).replaceAll('\\', '/') + '/'
  const covered = collectCoveredEntryNames(profileConfig.files || [], prefix)
  const entries = await fs.readdir(outDir)
  const actual = new Set(entries)
  const uncovered = entries.filter(name => !covered.has(name))
  const missing = [...covered].filter(name => !actual.has(name))
  if (uncovered.length > 0) {
    throw new Error(`构建产物存在未登记进 fw-app.build.json 的条目（会漏打包）: ${uncovered.join(', ')}`)
  }
  if (missing.length > 0) {
    throw new Error(`fw-app.build.json 登记了不存在的产物条目: ${missing.join(', ')}`)
  }
}

async function main() {
  const opts = parseArgs(scriptArgs(process.argv))
  const outDir = path.join(rootDir, 'build', 'windows', 'x64', 'runner', OUTPUT_DIR_BY_PROFILE[opts.profile])
  // 入口程序名以应用清单为唯一事实源，构建脚本不另行硬编码。
  const manifest = await readJson(path.join(rootDir, '.fast-window-dev-protocol', 'fw-app.json'))
  const executableName = String(manifest?.package?.windowsExecutable ?? '').trim()
  if (!executableName) throw new Error('fw-app.json 缺少 package.windowsExecutable')

  await run('flutter', ['pub', 'get'], rootDir)
  await run('flutter', ['build', 'windows', BUILD_FLAG_BY_PROFILE[opts.profile]], rootDir)

  const executable = path.join(outDir, executableName)
  if (!(await statType(executable))?.isFile()) {
    throw new Error(`Flutter 构建产物缺少入口程序: ${executable}`)
  }
  await assertArtifactCovered(outDir, opts.profile)

  console.log(JSON.stringify({
    profile: opts.profile,
    outDir,
    executable: path.basename(executable),
    files: await listTopLevelFiles(outDir),
  }))
}

const isDirectRun = process.argv[1] !== undefined && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
if (isDirectRun) {
  await main().catch(error => {
    process.stderr.write(`${String(error?.message || error)}\n`)
    process.exitCode = 1
  })
}
