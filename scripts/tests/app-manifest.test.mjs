import assert from 'node:assert/strict'
import test from 'node:test'

import { loadAppConfig } from '../lib/v5-app-package-manifest.mjs'

// 打包库必须能读取应用真实的协议清单与构建配置：清单规则一变，这里第一时间暴露两边脱节。
test('打包库能读取真实的应用清单与构建配置', async () => {
  const config = await loadAppConfig()
  assert.equal(config.type, 'desktop-app')
  assert.match(config.executable, /\.exe$/i)
  assert.ok(config.profiles.release, '缺少 release 构建配置')
  assert.equal(Object.hasOwn(config, 'displayMode'), false, '窗口模式已归宿主管理，打包库不应再产出 displayMode')
})
