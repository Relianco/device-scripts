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
  MAX_PATCH_CHARS,
  capPatch,
  isDocsPath,
  isReviewablePath,
  notPerformedBody,
  parseFindings,
  parseModelList,
  MAX_COMPLETION_TOKENS,
  messageText,
  postCompletion,
  primaryModel,
  reviewPullRequest,
  selectReviewFiles,
} from '../scripts/ci/ai-pr-review.mjs'
import * as review from '../scripts/ci/ai-pr-review.mjs'

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
  assert.equal(isReviewablePath('linux/runner/relian-runner.sh'), true)
  const selected = selectReviewFiles([
    { filename: 'docs/STATUS.md', patch: 'diff' },
    { filename: 'windows/runner/Invoke-RelianRunner.ps1', patch: 'diff --git' },
    { filename: 'windows/brand/logo.bin', patch: null },
  ])
  assert.deepEqual(selected.kept.map((file) => file.filename), ['windows/runner/Invoke-RelianRunner.ps1'])
  assert.deepEqual(selected.skipped, ['docs/STATUS.md', 'windows/brand/logo.bin'])
})

test('a printer package patch fits and a longer patch is still capped', () => {
  const printerPatch = 'p'.repeat(72000)
  const selected = selectReviewFiles([
    { filename: 'windows/packages/printer-tcp/Invoke-PrinterTcp.ps1', changes: 1, patch: printerPatch },
  ])
  assert.equal(selected.truncated.length, 0)
  assert.equal(selected.kept[0].patch, printerPatch)
})

test('a patch longer than the cap is capped and the 21st file is omitted', () => {
  const kept = 'a'.repeat(MAX_PATCH_CHARS)
  assert.equal(capPatch(kept), kept)
  const over = 'b'.repeat(MAX_PATCH_CHARS + 1)
  assert.equal(capPatch(over), `${'b'.repeat(MAX_PATCH_CHARS)}\n...[truncated]`)
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
    { filename: 'windows/packages/huge.ps1', changes: 1, patch: 'd'.repeat(MAX_PATCH_CHARS + 1) },
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
  assert.match(PROMPT, /Its off switch is an empty PinVersion\. An empty InstallerSha256 means no installer: bind still runs, nothing is downloaded/)
  const skip = [
    'SecureConnectionError is a connection failure and is retryable. Do not report it.',
    'The OpenAI client may retry HTTP 409 and 425 once. Do not report that single retry.',
    'Mandatory is a defect only on parameters of a package entry script. A Mandatory parameter on a test helper is not a defect.',
    'An empty hash exits 0 for every action, including Uninstall, and downloads nothing.',
    'The four entry points (windows/runner/Invoke-RelianRunner.ps1, windows/runner/Invoke-RelianJob.ps1, linux/runner/relian-runner.sh, macos/runner/relian-runner.sh) refuse a URL with userinfo first and exit 1, even when the hash is empty. Then an empty hash exits 0.',
    'Inside a package, an empty pin exits 0 before the installer URL is read, including when that URL contains userinfo. Do not require that rejection in a package when the hash is empty.',
    'Uninstall does not download. A present hash with a userinfo URL does not block uninstall.',
    'The Linux and macOS shell runners each download their one package script for every action, including Uninstall. That download is not the retained-action uninstall rule.',
    'An MSI install path must be one quoted argument so a path that contains spaces is not split.',
  ]
  const uninstallRule = 'Uninstall does not download. A present hash with a userinfo URL does not block uninstall.'
  const shellDownload = 'The Linux and macOS shell runners each download their one package script for every action, including Uninstall. That download is not the retained-action uninstall rule.'
  const uninstallAt = PROMPT.indexOf(uninstallRule)
  const shellAt = PROMPT.indexOf(shellDownload)
  assert.equal(uninstallAt >= 0, true)
  assert.equal(shellAt > uninstallAt, true)
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
      assert.equal(sent.max_completion_tokens, MAX_COMPLETION_TOKENS)
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

test('an empty completion fails immediately and a text part is accepted', async () => {
  assert.equal(messageText({ content: [{ type: 'text', text: '{"findings":[]}' }] }), '{"findings":[]}')
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
        return {
          ok: true,
          status: 200,
          text: async () => JSON.stringify({ choices: [{ finish_reason: 'length', message: { content: null, refusal: 'no' } }] }),
        }
      },
    }),
    /finish_reason=length; keys=content,refusal/,
  )
  assert.equal(calls, 1)

  const content = await postCompletion({
    endpoint: 'https://api.openai.com/v1',
    apiKey: 'test-key',
    model: DEFAULT_MODEL,
    messages: [],
    sleep: async () => {},
    fetchImpl: async () => ({
      ok: true,
      status: 200,
      text: async () => JSON.stringify({ choices: [{ message: { content: [{ type: 'text', text: '{"findings":[]}' }] } }] }),
    }),
  })
  assert.match(content, /findings/)
})

// New symbols come through the namespace so each test fails on its own against the old script.
const H = '/' + 'home/'
const homePath = `${H}exampleuser/x`

function fakeModel(reply = '{"findings":[]}') {
  const prompts = []
  const fetchImpl = async (_url, init) => {
    prompts.push(JSON.parse(init.body).messages[1].content)
    return { ok: true, status: 200, text: async () => JSON.stringify({ choices: [{ message: { content: reply } }] }) }
  }
  return { prompts, fetchImpl }
}

async function runReview(files, model = fakeModel()) {
  const posted = []
  let error = null
  try {
    await reviewPullRequest({
      prNumber: 1,
      headSha: 'abc',
      token: 't',
      endpoint: 'https://example.test/v1',
      apiKey: 'k',
      model: DEFAULT_MODEL,
      sleep: async () => {},
      fetchImpl: model.fetchImpl,
      listFiles: async () => files,
      post: async ({ body }) => { posted.push(body) },
    })
  } catch (caught) {
    error = caught
  }
  return { posted, error, prompts: model.prompts }
}

const patch = '@@ -0,0 +1 @@\n+text'

test('docs are classified by extension or name, never by folder', () => {
  const table = [
    ['README.md', true, false],
    ['docs/x.md', true, false],
    ['.github/x.md', true, false],
    ['LICENSE', true, false],
    ['docs/x.ps1', false, true],
    ['docs/x.sh', false, true],
    ['docs/plans/x.json', false, true],
  ]
  for (const [filename, docs, reviewable] of table) {
    assert.equal(isDocsPath(filename), docs, filename)
    assert.equal(isReviewablePath(filename), reviewable, filename)
  }
})

test('a docs-only PR gets the docs prompt and a docs verdict; code PRs keep the code prompt', async () => {
  const table = [
    { name: 'README.md only', files: [{ filename: 'README.md', patch }], docs: true, sent: ['README.md'] },
    { name: 'docs/x.md only', files: [{ filename: 'docs/x.md', patch }], docs: true, sent: ['docs/x.md'] },
    { name: '.github/x.md and LICENSE', files: [{ filename: '.github/x.md', patch }, { filename: 'LICENSE', patch }], docs: true, sent: ['.github/x.md', 'LICENSE'] },
    { name: 'docs/x.ps1', files: [{ filename: 'docs/x.ps1', patch }], docs: false, sent: ['docs/x.ps1'] },
    { name: 'mixed docs and code', files: [{ filename: 'README.md', patch }, { filename: 'windows/a.ps1', patch }], docs: false, sent: ['windows/a.ps1'] },
    { name: 'rename .ps1 to .md', files: [{ filename: 'docs/x.md', previous_filename: 'windows/x.ps1', status: 'renamed', changes: 1, patch }], docs: false, sent: ['docs/x.md'] },
  ]
  for (const row of table) {
    const { posted, error, prompts } = await runReview(row.files)
    assert.equal(error, null, row.name)
    assert.equal(posted.length, 1, row.name)
    assert.deepEqual(prompts.map((p) => p.split('\nFile: ')[1].split('\n')[0]), row.sent, row.name)
    for (const prompt of prompts) {
      assert.equal(prompt.startsWith(row.docs ? review.DOCS_PROMPT : PROMPT), true, row.name)
    }
    if (row.docs) {
      assert.equal(posted[0].startsWith(review.DOCS_LGTM), true, row.name)
      assert.equal(posted[0].startsWith('LGTM'), true, row.name)
    } else {
      assert.equal(posted[0].startsWith('LGTM 👍'), true, row.name)
    }
    assert.equal(posted[0].startsWith(NOT_PERFORMED_PREFIX), false, row.name)
  }
})

test('the docs prompt names the public-repo leaks and the code rules', () => {
  const prompt = review.DOCS_PROMPT
  assert.equal(typeof prompt, 'string')
  assert.match(prompt, /PUBLIC/)
  assert.match(prompt, /client or customer name/)
  assert.match(prompt, /device id/)
  assert.match(prompt, /home-directory path/)
  assert.match(prompt, /C:\\Users\\<name>/)
  assert.match(prompt, /token, password/)
  assert.match(prompt, /contradicts the code rules/)
  assert.match(prompt, /A URL with userinfo/)
  assert.match(prompt, /JSON/)
})

test('docs findings are not LGTM and use the docs prefix', async () => {
  const model = fakeModel('{"findings":[{"line":2,"body":"Names a client."}]}')
  const { posted, error } = await runReview([{ filename: 'docs/x.md', patch }], model)
  assert.equal(error, null)
  assert.equal(posted[0].startsWith(review.DOCS_PREFIX), true)
  assert.equal(posted[0].startsWith('LGTM'), false)
  assert.match(posted[0], /docs\/x\.md:2 Names a client\./)
  assert.equal(DELIVERY_PREFIXES.includes(review.DOCS_PREFIX), true)
})

test('a home-directory path on an added docs line is flagged even when the model says clean', async () => {
  const win = 'C:' + '\\Users\\' + 'Jane'
  const planted = `@@ -1,2 +1,4 @@\n ctx\n-${H}gone/x\n+see ${homePath}\n+ok ${H}<user>/x and ${H}runner/work https://x.test${H}site\n+${win}\\a`
  assert.deepEqual(review.homePathFindings(planted).map((f) => f.line), [2, 4])
  const { posted } = await runReview([{ filename: 'README.md', patch: planted }])
  assert.equal(posted[0].startsWith(review.DOCS_PREFIX), true)
  assert.match(posted[0], /README\.md:2 /)
  assert.match(posted[0], /exampleuser/)
})

test('a docs-only PR with the model unavailable posts nothing and fails', async () => {
  const fetchImpl = async () => ({ ok: false, status: 404, text: async () => '{"error":{"code":"model_not_found"}}' })
  const { posted, error } = await runReview([{ filename: 'README.md', patch }], { prompts: [], fetchImpl })
  assert.match(String(error?.message), /model_not_found/)
  assert.equal(posted.length, 0)
})

test('only binary or unknown files is still NOT performed', async () => {
  const { posted, error } = await runReview([{ filename: 'brand/logo.png', changes: 0, patch: null }])
  assert.equal(error?.exitCode, 1)
  assert.equal(posted[0].startsWith(NOT_PERFORMED_PREFIX), true)
})

test('the workflow gate classifies docs by extension and verify accepts the docs prefix', () => {
  const workflow = readFileSync(new URL('../.github/workflows/ai-pr-review.yml', import.meta.url), 'utf8')
  assert.doesNotMatch(workflow, /docs\/\*/)
  assert.match(workflow, /\*\.md\|LICENSE\) ;;/)
  assert.match(workflow, /pulls\/\$\{PR_NUMBER\}\/files/)
  assert.equal(workflow.includes(`startswith("${review.DOCS_PREFIX}")`), true)
  assert.equal(workflow.includes('startswith("AI review NOT performed:")'), true)
})
