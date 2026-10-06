import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { assertArtifactCovered } from '../build-windows.mjs'

async function makeCoverageFixture() {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'picacomic-cover-'))
  const outDir = path.join(dir, 'Release')
  const configPath = path.join(dir, 'fw-app.build.json')
  await fs.mkdir(outDir, { recursive: true })
  await fs.writeFile(configPath, JSON.stringify({
    profiles: { release: { files: [{ from: 'Release/pica_comic.exe', to: 'pica_comic.exe' }] } },
  }))
  return { dir, outDir, configPath }
}

test('产物覆盖校验：产物存在未登记条目时报错', async () => {
  const { dir, outDir, configPath } = await makeCoverageFixture()
  await fs.writeFile(path.join(outDir, 'pica_comic.exe'), 'x')
  await fs.writeFile(path.join(outDir, 'mystery_plugin.dll'), 'x')
  await assert.rejects(
    () => assertArtifactCovered(outDir, 'release', { baseDir: dir, configPath }),
    /未登记/,
  )
})

test('产物覆盖校验：全部登记时通过', async () => {
  const { dir, outDir, configPath } = await makeCoverageFixture()
  await fs.writeFile(path.join(outDir, 'pica_comic.exe'), 'x')
  await assertArtifactCovered(outDir, 'release', { baseDir: dir, configPath })
})

test('产物覆盖校验：登记了不存在的条目时报错', async () => {
  const { dir, outDir, configPath } = await makeCoverageFixture()
  await fs.writeFile(path.join(outDir, 'pica_comic.exe'), 'x')
  await fs.writeFile(configPath, JSON.stringify({
    profiles: {
      release: {
        files: [
          { from: 'Release/pica_comic.exe', to: 'pica_comic.exe' },
          { from: 'Release/tools', to: 'tools' },
        ],
      },
    },
  }))
  await assert.rejects(
    () => assertArtifactCovered(outDir, 'release', { baseDir: dir, configPath }),
    /不存在的产物条目/,
  )
})
