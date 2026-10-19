import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'
import {
  DEFAULT_MODEL,
  DELIVERY_PREFIXES,
  INCOMPLETE_PREFIX,
  NOT_PERFORMED_PREFIX,
  PROMPT,
  buildReviewBody,
  capPatch,
  isDocsPath,
  isReviewablePath,
  notPerformedBody,
  parseFindings,
  parseModelList,
  postCompletion,
  primaryModel,
  reviewPullRequest,
  selectReviewFiles,
} from '../scripts/ci/ai-pr-review.mjs'

test('an empty MODEL pin is gpt-6.1-sol and a second name is not the primary', () => {
  assert.deepEqual(parseModelList(''), [DEFAULT_MODEL])
  assert.deepEqual(parseModelList(undefined), [DEFAULT_MODEL])
  assert.equal(primaryModel('gpt-6.1-sol,gpt-6-sol'), 'gpt-6.1-sol')
  assert.equal(DEFAULT_MODEL, 'gpt-6.1-sol')
})

test('markdown and docs are skipped and PowerShell is reviewed', () => {
  assert.equal(isDocsPath('README.md'), true)
  assert.equal(isDocsPath('docs/STATUS.md'), true)
  assert.equal(isDocsPath('LICENSE'), true)
  assert.equal(isReviewablePath('README.md'), false)
  assert.equal(isReviewablePath('windows/packages/teams/Invoke-Teams.ps1'), true)
  assert.equal(isReviewablePath('windows/releases/teams.json'), true)
  assert.equal(isReviewablePath('.github/workflows/pr-verify.yml'), true)
  const selected = selectReviewFiles([
    { filename: 'docs/STATUS.md', patch: 'diff' },
    { filename: 'windows/runner/Invoke-RelianRunner.ps1', patch: 'diff --git' },
    { filename: 'windows/brand/logo.bin', patch: null },
  ])
  assert.deepEqual(selected.kept.map((file) => file.filename), ['windows/runner/Invoke-RelianRunner.ps1'])
  assert.deepEqual(selected.skipped, ['docs/STATUS.md', 'windows/brand/logo.bin'])
})

test('a patch longer than 64000 characters is capped and the 21st file is omitted', () => {
  const kept = 'a'.repeat(64000)
  assert.equal(capPatch(kept), kept)
  const over = 'b'.repeat(64001)
  assert.equal(capPatch(over), `${'b'.repeat(64000)}\n...[truncated]`)
  const files = []
  for (let i = 0; i < 21; i++) {
    files.push({ filename: `windows/packages/p${i}.ps1`, patch: 'diff' })
  }
  const selected = selectReviewFiles(files)
  assert.equal(selected.kept.length, 20)
  assert.deepEqual(selected.omitted, ['windows/packages/p20.ps1'])
  const body = buildReviewBody({
    findings: [],
    omitted: selected.omitted,
    model: DEFAULT_MODEL,
  })
  assert.equal(body.startsWith('LGTM'), false)
  assert.equal(body.startsWith(INCOMPLETE_PREFIX), true)
  assert.match(body, /windows\/packages\/p20\.ps1/)
})

test('a withheld diff and a truncated patch are not LGTM', async () => {
  const withheld = selectReviewFiles([
    { filename: 'windows/packages/hidden.ps1', changes: 4, patch: null },
    { filename: 'windows/runner/Invoke-RelianRunner.ps1', changes: 0, patch: null },
    { filename: 'README.md', changes: 3, patch: 'diff' },
  ])
  assert.deepEqual(withheld.unread, ['windows/packages/hidden.ps1'])
  assert.deepEqual(withheld.skipped, ['windows/runner/Invoke-RelianRunner.ps1', 'README.md'])
  assert.equal(withheld.kept.length, 0)

  const huge = selectReviewFiles([
    { filename: 'windows/packages/huge.ps1', changes: 1, patch: 'd'.repeat(64001) },
  ])
  assert.deepEqual(huge.truncated, ['windows/packages/huge.ps1'])
  const partial = buildReviewBody({
    findings: [],
    omitted: huge.omitted,
    unread: huge.unread,
    truncated: huge.truncated,
    model: DEFAULT_MODEL,
  })
  assert.equal(partial.startsWith('LGTM'), false)
  assert.equal(partial.startsWith(INCOMPLETE_PREFIX), true)
  assert.match(partial, /windows\/packages\/huge\.ps1/)

  const withFindings = buildReviewBody({
    findings: [{ path: 'a.ps1', line: 1, body: 'The mismatch still runs the package.' }],
    omitted: ['b.ps1'],
    model: DEFAULT_MODEL,
  })
  assert.equal(withFindings.startsWith(DELIVERY_PREFIXES[0]), true)
  assert.equal(withFindings.startsWith('LGTM'), false)

  let posted = ''
  const body = await reviewPullRequest({
    prNumber: 1,
    headSha: 'abc',
    token: 't',
    endpoint: 'https://example.test/v1',
    apiKey: 'k',
    model: DEFAULT_MODEL,
    listFiles: async () => [{ filename: 'windows/packages/hidden.ps1', changes: 4, patch: null }],
    post: async ({ body: reviewBody }) => {
      posted = reviewBody
    },
  })
  assert.equal(body, posted)
  assert.equal(body.startsWith(INCOMPLETE_PREFIX), true)
  assert.equal(body.startsWith('LGTM'), false)
  assert.equal(body.startsWith(NOT_PERFORMED_PREFIX), false)
  assert.match(body, /windows\/packages\/hidden\.ps1/)
})

test('review bodies use the delivery prefixes and a nothing-reviewable body does not', () => {
  const clean = buildReviewBody({ findings: [], omitted: [], model: DEFAULT_MODEL })
  const dirty = buildReviewBody({
    findings: [{ path: 'a.ps1', line: 4, body: 'The mismatch still runs the package.' }],
    omitted: [],
    model: DEFAULT_MODEL,
  })
  const skipped = 'AI review skipped for this push: docs-only'
  assert.equal(clean.startsWith(DELIVERY_PREFIXES[1]), true)
  assert.equal(dirty.startsWith(DELIVERY_PREFIXES[0]), true)
  assert.equal(skipped.startsWith(DELIVERY_PREFIXES[2]), true)
  const none = notPerformedBody(['README.md'])
  assert.equal(none.startsWith(NOT_PERFORMED_PREFIX), true)
  for (const prefix of DELIVERY_PREFIXES) {
    assert.equal(none.startsWith(prefix), false)
  }
})

test('findings JSON without an array fails', () => {
  assert.equal(parseFindings('{"findings":[]}').length, 0)
  assert.throws(() => parseFindings('{"ok":true}'), /findings array missing/)
})

test('the prompt is PowerShell rules and names JSON', () => {
  assert.match(PROMPT, /JSON/)
  assert.match(PROMPT, /userinfo/)
  assert.match(PROMPT, /empty hash/)
  assert.match(PROMPT, /hash mismatch/)
  assert.match(PROMPT, /NinjaOne/)
  assert.doesNotMatch(PROMPT, /Nuxt/)
  assert.match(PROMPT, /Relian is the product name\. It is not a client name\. Do not report Relian in a namespace, a filename, or UI text\./)
  assert.match(PROMPT, /The user-check package installs nothing\. It has no installer sha256\. pagePin and codePin are mode labels, not pin hashes\. Do not require a 64-character hash in windows\/releases\/user-check\.json\./)
  const skip = [
    'SecureConnectionError is a connection failure and is retryable. Do not report it.',
    'The OpenAI client may retry HTTP 409 and 425 once. Do not report that single retry.',
    'Mandatory is a defect only on parameters of a package entry script. A Mandatory parameter on a test helper is not a defect.',
    'An empty hash exits 0 for every action, including Uninstall, and downloads nothing.',
    'An empty hash exits 0 before the URL is read, including when the URL contains userinfo. Do not require that rejection when the hash is empty.',
    'Uninstall does not download. A present hash with a userinfo URL does not block uninstall.',
    'An MSI install path must be one quoted argument so a path that contains spaces is not split.',
  ]
  for (const sentence of skip) {
    assert.equal(PROMPT.includes(sentence), true)
  }
})

test('the workflow pins gpt-6.1-sol on ubuntu-latest', () => {
  const workflow = readFileSync(new URL('../.github/workflows/ai-pr-review.yml', import.meta.url), 'utf8')
  const verify = readFileSync(new URL('../.github/workflows/pr-verify.yml', import.meta.url), 'utf8')
  assert.match(workflow, /previous_filename/)
  assert.match(workflow, /MODEL:\s*gpt-6\.1-sol/)
  assert.match(workflow, /runs-on:\s*ubuntu-24\.04/)
  assert.doesNotMatch(workflow, /self-hosted/)
  assert.doesNotMatch(workflow, /ubuntu-latest/)
  assert.doesNotMatch(workflow, /gpt-6-sol/)
  for (const prefix of DELIVERY_PREFIXES) {
    assert.equal(workflow.includes(prefix), true)
  }
  assert.equal(workflow.includes(NOT_PERFORMED_PREFIX), true)
  assert.match(verify, /runs-on:\s*ubuntu-24\.04/)
  assert.match(verify, /tests\/run-all\.ps1/)
  assert.match(verify, /tests\/ai-pr-review\.test\.mjs/)
  assert.match(verify, /tests\/secret-scan\.test\.mjs/)
  assert.doesNotMatch(verify, /scripts\/ci\/.*\.test\.mjs/)
  assert.doesNotMatch(verify, /self-hosted/)
})

test('model_not_found fails without a second model and a 503 is retried once', async () => {
  let calls = 0
  await assert.rejects(
    () => postCompletion({
      endpoint: 'https://api.openai.com/v1',
      apiKey: 'test-key',
      model: DEFAULT_MODEL,
      messages: [],
      sleep: async () => {},
      fetchImpl: async () => {
        calls += 1
        return { ok: false, status: 404, text: async () => '{"error":{"code":"model_not_found"}}' }
      },
    }),
    /model_not_found/,
  )
  assert.equal(calls, 1)

  calls = 0
  const content = await postCompletion({
    endpoint: 'https://api.openai.com/v1/',
    apiKey: 'test-key',
    model: DEFAULT_MODEL,
    messages: [{ role: 'user', content: 'ping' }],
    sleep: async () => {},
    fetchImpl: async (_url, init) => {
      calls += 1
      const sent = JSON.parse(init.body)
      assert.equal(sent.max_completion_tokens, 2000)
      assert.equal(sent.max_tokens, undefined)
      assert.equal(sent.model, DEFAULT_MODEL)
      assert.equal(init.headers.Authorization, 'Bearer test-key')
      if (calls === 1) {
        return { ok: false, status: 503, text: async () => 'unavailable' }
      }
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ choices: [{ message: { content: '{"findings":[]}' } }] }),
      }
    },
  })
  assert.equal(calls, 2)
  assert.match(content, /findings/)
})
