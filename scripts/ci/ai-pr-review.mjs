/**
 * Pull-request review for PowerShell device scripts.
 * Zero dependencies. The workflow pins MODEL to gpt-6.1-sol.
 * A missing or unentitled model fails the job. This script does not
 * substitute another model.
 */

import { pathToFileURL } from 'node:url'

export const INCOMPLETE_PREFIX = 'AI review incomplete:'

export const DELIVERY_PREFIXES = [
  'Code review by ChatGPT',
  'LGTM',
  'AI review skipped for this push:',
  INCOMPLETE_PREFIX,
]

export const NOT_PERFORMED_PREFIX = 'AI review NOT performed:'

export const DEFAULT_MODEL = 'gpt-6.1-sol'

// Reasoning tokens count against this budget. 2000 came back with an empty
// message on a full package file. The JSON reply itself is small.
export const MAX_COMPLETION_TOKENS = 16000

// A new package file is one patch. 64000 cut the printer script and its plan test.
export const MAX_PATCH_CHARS = 96000

export const PROMPT = `You review one file from a pull request of PowerShell device-deployment scripts.
Report defects a maintainer must fix before merge. Skip style and naming.

Rules for code the diff adds or changes:
- A committed file must not contain a secret, a token, a password, a client name, a device id, or a home-directory path.
- Relian is the product name. It is not a client name. Do not report Relian in a namespace, a filename, or UI text.
- A URL with userinfo (scheme://user@host) must exit 1 before any download.
- An empty hash must exit 0 and must not download.
- An empty hash exits 0 for every action, including Uninstall, and downloads nothing.
- An empty hash exits 0 before the URL is read, including when the URL contains userinfo. Do not require that rejection when the hash is empty.
- Uninstall does not download. A present hash with a userinfo URL does not block uninstall.
- The Linux and macOS shell runners each download their one package script for every action, including Uninstall. That download is not the retained-action uninstall rule.
- An MSI install path must be one quoted argument so a path that contains spaces is not split.
- A hash mismatch must exit 1, must not be retried, and must not run the package.
- Retries are only for timeout, connection, or DNS failure, or HTTP 408, 429, 500, 502, 503, 504. Three attempts. Any other HTTP status is one attempt.
- SecureConnectionError is a connection failure and is retryable. Do not report it.
- The OpenAI client may retry HTTP 409 and 425 once. Do not report that single retry.
- A new test must fail on the old behavior. A test with no assertion is a defect.
- The runner and a package must not call the NinjaOne API.
- Parameter blocks are not Mandatory. A Mandatory parameter prompts when the file is dot-sourced.
- Mandatory is a defect only on parameters of a package entry script. A Mandatory parameter on a test helper is not a defect.
- curl and az arguments are an array, or they are written inline. Arguments stored in one scalar string are a defect, because zsh does not word-split that string.
- The Teams package must not contain disableAutoUpdate, MsRdcWebRTCSvc, or Reset-AppxPackage.
- A pin hash is 64 lowercase hex characters. Do not treat a placeholder hash as valid.
- The user-check package installs nothing. It has no installer sha256. pagePin and codePin are mode labels, not pin hashes. Do not require a 64-character hash in windows/releases/user-check.json.

Reply with one JSON object and no other text:
{"findings":[{"line":1,"body":"what happens at runtime, then the fix"}]}
Use an empty findings array when the file has no defect.`

const REVIEW_EXT = new Set(['.ps1', '.json', '.yml', '.yaml', '.mjs', '.js', '.toml', '.sh'])
const TRANSIENT = new Set([408, 409, 425, 429, 500, 502, 503, 504])

export function parseModelList(value) {
  const names = String(value ?? '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean)
  return names.length > 0 ? names : [DEFAULT_MODEL]
}

export function primaryModel(value) {
  return parseModelList(value)[0]
}

export function isDocsPath(filename) {
  if (filename === 'LICENSE') return true
  if (filename.startsWith('docs/')) return true
  return filename.endsWith('.md')
}

export function isReviewablePath(filename) {
  if (!filename || isDocsPath(filename)) return false
  const base = filename.split('/').pop()
  const dot = base.lastIndexOf('.')
  if (dot < 0) return false
  return REVIEW_EXT.has(base.slice(dot).toLowerCase())
}

export function capPatch(patch, max = MAX_PATCH_CHARS) {
  const text = patch || ''
  if (text.length <= max) return text
  return `${text.slice(0, max)}\n...[truncated]`
}

export function selectReviewFiles(files, { limit = 20, maxPatch = MAX_PATCH_CHARS } = {}) {
  const reviewable = []
  const skipped = []
  const unread = []
  for (const file of files) {
    if (!isReviewablePath(file.filename)) {
      skipped.push(file.filename)
      continue
    }
    if (!file.patch) {
      if (Number(file.changes) > 0) unread.push(file.filename)
      else skipped.push(file.filename)
      continue
    }
    const patch = String(file.patch)
    reviewable.push({
      filename: file.filename,
      patch: capPatch(patch, maxPatch),
      truncated: patch.length > maxPatch,
    })
  }
  const kept = reviewable.slice(0, limit)
  return {
    kept,
    omitted: reviewable.slice(limit).map((file) => file.filename),
    skipped,
    unread,
    truncated: kept.filter((file) => file.truncated).map((file) => file.filename),
  }
}

export function parseFindings(content) {
  let parsed
  try {
    parsed = JSON.parse(content)
  } catch {
    throw new Error('review JSON parse failed')
  }
  if (!parsed || !Array.isArray(parsed.findings)) {
    throw new Error('findings array missing')
  }
  return parsed.findings
    .map((finding) => ({
      line: Number.isInteger(finding.line) && finding.line > 0 ? finding.line : 1,
      body: String(finding.body || '').trim(),
    }))
    .filter((finding) => finding.body.length > 0)
}

function coverageNotes({ omitted = [], unread = [], truncated = [] }) {
  const notes = []
  if (omitted.length > 0) {
    notes.push(`Not sent, over the 20-file cap: ${omitted.join(', ')}`)
  }
  if (unread.length > 0) {
    notes.push(`Diff withheld, so the file was not read: ${unread.join(', ')}`)
  }
  if (truncated.length > 0) {
    notes.push(`Patch truncated, so the file was not fully read: ${truncated.join(', ')}`)
  }
  return notes
}

export function buildReviewBody({ findings, omitted = [], unread = [], truncated = [], model }) {
  const notes = coverageNotes({ omitted, unread, truncated })
  const note = notes.length > 0 ? `\n\n${notes.join('\n\n')}` : ''
  if (findings.length === 0 && notes.length === 0) {
    return `LGTM 👍\n\nReviewed with ${model}. No defects to fix before merge.`
  }
  if (findings.length === 0) {
    return `${INCOMPLETE_PREFIX} the model did not read every changed file. No defect was reported in the files it did read.${note}`
  }
  const lines = findings.map((finding) => `- ${finding.path}:${finding.line} ${finding.body}`)
  return `Code review by ChatGPT\n\n${lines.join('\n')}${note}`
}

export function notPerformedBody(filenames) {
  const names = filenames.length > 0 ? filenames.join(', ') : '(none)'
  return `${NOT_PERFORMED_PREFIX} no reviewable source files. Files: ${names}`
}

export function isModelUnavailable(status, body) {
  return String(body || '').includes('model_not_found') || status === 404
}

export function messageText(message) {
  const content = message?.content
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content.map((part) => {
    if (typeof part === 'string') return part
    if (part && typeof part.text === 'string') return part.text
    return ''
  }).join('')
}

export async function postCompletion({
  endpoint,
  apiKey,
  model,
  messages,
  fetchImpl = globalThis.fetch,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
}) {
  const url = `${String(endpoint).replace(/\/$/, '')}/chat/completions`
  const payload = JSON.stringify({
    model,
    messages,
    response_format: { type: 'json_object' },
    max_completion_tokens: MAX_COMPLETION_TOKENS,
  })
  let lastError = null
  for (let attempt = 1; attempt <= 2; attempt++) {
    let response
    try {
      response = await fetchImpl(url, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${apiKey}`,
          'Content-Type': 'application/json',
        },
        body: payload,
      })
    } catch (error) {
      lastError = error
      if (attempt === 1) {
        await sleep(1000)
        continue
      }
      throw error
    }
    const text = await response.text()
    if (response.ok) {
      let parsed
      try {
        parsed = JSON.parse(text)
      } catch {
        throw new Error('completion body is not JSON')
      }
      const choice = parsed?.choices?.[0]
      const content = messageText(choice?.message)
      if (content.trim() !== '') return content
      const reason = choice?.finish_reason || 'none'
      const keys = choice?.message ? Object.keys(choice.message).sort().join(',') : 'none'
      throw new Error(`completion content missing (finish_reason=${reason}; keys=${keys})`)
    }
    if (isModelUnavailable(response.status, text) || response.status === 401 || response.status === 403) {
      const error = new Error(`openai ${response.status}${String(text).includes('model_not_found') ? ' model_not_found' : ''}`)
      error.status = response.status
      throw error
    }
    if (TRANSIENT.has(response.status) && attempt === 1) {
      await sleep(1000)
      continue
    }
    const error = new Error(`openai ${response.status}`)
    error.status = response.status
    lastError = error
    throw error
  }
  throw lastError ?? new Error('completion failed')
}

async function github(path, { method = 'GET', body, token }) {
  const response = await fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'relian-device-scripts-review',
      'X-GitHub-Api-Version': '2022-11-28',
    },
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await response.text()
  if (!response.ok) {
    throw new Error(`github ${method} ${path} ${response.status} ${text.slice(0, 300)}`)
  }
  return text ? JSON.parse(text) : null
}

async function listPullFiles(prNumber, token) {
  const files = []
  for (let page = 1; page <= 10; page++) {
    const batch = await github(`/repos/${process.env.GITHUB_REPOSITORY}/pulls/${prNumber}/files?per_page=100&page=${page}`, { token })
    if (!Array.isArray(batch) || batch.length === 0) break
    files.push(...batch)
    if (batch.length < 100) break
  }
  return files
}

async function postReview({ prNumber, headSha, body, token }) {
  await github(`/repos/${process.env.GITHUB_REPOSITORY}/pulls/${prNumber}/reviews`, {
    method: 'POST',
    token,
    body: { commit_id: headSha, event: 'COMMENT', body },
  })
}

export function messagesFor(file) {
  return [
    { role: 'system', content: 'You reply with JSON only.' },
    { role: 'user', content: `${PROMPT}\n\nFile: ${file.filename}\n\n${file.patch}` },
  ]
}

export async function reviewPullRequest({
  prNumber,
  headSha,
  token,
  endpoint,
  apiKey,
  model,
  fetchImpl,
  sleep,
  listFiles = listPullFiles,
  post = postReview,
}) {
  const files = await listFiles(prNumber, token)
  const selected = selectReviewFiles(files)
  if (selected.kept.length === 0 && selected.unread.length > 0) {
    const body = buildReviewBody({
      findings: [],
      omitted: selected.omitted,
      unread: selected.unread,
      truncated: selected.truncated,
      model,
    })
    await post({ prNumber, headSha, body, token })
    return body
  }
  if (selected.kept.length === 0) {
    const body = notPerformedBody(files.map((file) => file.filename))
    await post({ prNumber, headSha, body, token })
    const error = new Error(body)
    error.exitCode = 1
    throw error
  }
  const findings = []
  for (const file of selected.kept) {
    let content
    try {
      content = await postCompletion({
        endpoint,
        apiKey,
        model,
        messages: messagesFor(file),
        fetchImpl,
        sleep,
      })
    } catch (error) {
      const wrapped = new Error(`${file.filename}: ${error.message}`)
      wrapped.exitCode = error.exitCode
      throw wrapped
    }
    for (const finding of parseFindings(content)) {
      findings.push({ path: file.filename, line: finding.line, body: finding.body })
    }
  }
  const body = buildReviewBody({
    findings,
    omitted: selected.omitted,
    unread: selected.unread,
    truncated: selected.truncated,
    model,
  })
  await post({ prNumber, headSha, body, token })
  return body
}

async function main() {
  const token = process.env.GITHUB_TOKEN
  const apiKey = process.env.OPENAI_API_KEY
  const endpoint = process.env.OPENAI_API_ENDPOINT || 'https://api.openai.com/v1'
  const prNumber = process.env.PR_NUMBER
  const headSha = process.env.HEAD_SHA
  const model = primaryModel(process.env.MODEL)
  if (!token || !apiKey || !prNumber || !headSha) {
    throw new Error('GITHUB_TOKEN, OPENAI_API_KEY, PR_NUMBER, and HEAD_SHA are required')
  }
  if (model !== DEFAULT_MODEL && String(process.env.MODEL || '').trim() === '') {
    throw new Error('MODEL resolved empty')
  }
  await reviewPullRequest({
    prNumber,
    headSha,
    token,
    endpoint,
    apiKey,
    model,
  })
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href
if (isMain) {
  main().catch((error) => {
    console.error(error.message)
    process.exit(error.exitCode || 1)
  })
}
