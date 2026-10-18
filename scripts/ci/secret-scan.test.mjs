import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

const read = (path) => readFileSync(new URL(path, import.meta.url), 'utf8')

test('the local policy and the CI fallback allow only the fixture value secret', () => {
  const policy = read('../../.betterleaks.toml')
  const workflow = read('../../.github/workflows/secret-scan.yml')
  const hook = read('../../.githooks/pre-push')
  const scan = read('../scan-secrets.sh')

  assert.match(policy, /useDefault = true/)
  assert.match(policy, /\^secret\$/)
  assert.match(workflow, /git show "\$\{base\}:\.betterleaks\.toml"/)
  assert.match(workflow, /useDefault = true/)
  assert.match(workflow, /\^secret\$/)
  assert.match(hook, /betterleaks git/)
  assert.match(hook, /\.betterleaks\.toml/)
  assert.match(scan, /betterleaks git/)
  assert.match(scan, /origin\/teams-package/)
})
