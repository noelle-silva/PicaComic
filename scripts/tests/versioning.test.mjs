import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { bumpV5AppVersion, checkV5AppVersion } from '../lib/v5-app-versioning.mjs'

async function makeAppDir({ releaseVersion = '1.6.3', pubspecVersion = '1.6.3+163' } = {}) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'picacomic-versioning-'))
  await fs.writeFile(path.join(dir, 'release.json'), JSON.stringify({ version: releaseVersion }, null, 2) + '\n')
  await fs.writeFile(
    path.join(dir, 'pubspec.yaml'),
    `name: pica_comic\ndescription: "A comic app."\nversion: ${pubspecVersion}\n`,
  )
  return dir
}

test('版本一致时 check 通过并列出两处来源', async () => {
  const dir = await makeAppDir()
  const result = await checkV5AppVersion({ appDir: dir })
  assert.equal(result.currentVersion, '1.6.3')
  assert.deepEqual(
    result.files.map(item => item.label).sort(),
    ['pubspec.yaml', 'release.json'],
  )
})

test('两处版本漂移时拒绝操作', async () => {
  const dir = await makeAppDir({ pubspecVersion: '1.6.2+163' })
  await assert.rejects(() => checkV5AppVersion({ appDir: dir }), /版本漂移/)
})

test('pubspec 无构建号时仍可校验，升版补上构建号', async () => {
  const dir = await makeAppDir({ pubspecVersion: '1.6.3' })
  const check = await checkV5AppVersion({ appDir: dir })
  assert.equal(check.currentVersion, '1.6.3')
  await bumpV5AppVersion({ appDir: dir, bump: 'patch' })
  const pubspec = await fs.readFile(path.join(dir, 'pubspec.yaml'), 'utf8')
  assert.match(pubspec, /version: 1\.6\.4\+1/)
})

test('pubspec 版本形态不合法时报错', async () => {
  const dir = await makeAppDir({ pubspecVersion: '1.6+163' })
  await assert.rejects(() => checkV5AppVersion({ appDir: dir }), /version 格式/)
})

test('bump patch 同步两处且构建号递增', async () => {
  const dir = await makeAppDir()
  const result = await bumpV5AppVersion({ appDir: dir, bump: 'patch' })
  assert.equal(result.oldVersion, '1.6.3')
  assert.equal(result.newVersion, '1.6.4')
  const release = JSON.parse(await fs.readFile(path.join(dir, 'release.json'), 'utf8'))
  assert.equal(release.version, '1.6.4')
  const pubspec = await fs.readFile(path.join(dir, 'pubspec.yaml'), 'utf8')
  assert.match(pubspec, /version: 1\.6\.4\+164/)
})

test('dry-run 只预演不写文件', async () => {
  const dir = await makeAppDir()
  const result = await bumpV5AppVersion({ appDir: dir, bump: 'minor', dryRun: true })
  assert.equal(result.newVersion, '1.7.0')
  assert.equal(result.dryRun, true)
  const release = JSON.parse(await fs.readFile(path.join(dir, 'release.json'), 'utf8'))
  assert.equal(release.version, '1.6.3')
  const pubspec = await fs.readFile(path.join(dir, 'pubspec.yaml'), 'utf8')
  assert.match(pubspec, /version: 1\.6\.3\+163/)
})

test('--to 指定版本同样同步两处', async () => {
  const dir = await makeAppDir()
  const result = await bumpV5AppVersion({ appDir: dir, to: '2.0.0' })
  assert.equal(result.newVersion, '2.0.0')
  const pubspec = await fs.readFile(path.join(dir, 'pubspec.yaml'), 'utf8')
  assert.match(pubspec, /version: 2\.0\.0\+164/)
})
