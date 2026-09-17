#!/usr/bin/env node
/*
  生成 shell/Resources/catalog.json —— 插件市场的内置种子目录。

  为什么需要它：壳里的市场页要展示「基本信息 + 展示图 + 热门排序」，而 npm 的
  search 响应里其实带着 keywords / publisher / license / links / downloads /
  score / updated，但内置 catalog.json 早期只留了 name/version/description，
  热度与链接全丢了。这个脚本把那层补齐，并可重复运行。

  数据面（重要）：
    dsh 上游约定插件仓库打 `dsh-plugin` 话题（见 deepseek-harness 的 README 与
    CONTRIBUTING：https://github.com/topics/dsh-plugin）。壳最初只查了
    `keywords:dsh-bundle`——那是个几乎没人用的、与字段名同款的标签，只覆盖生态的
    约 2%（实测 83 / 4971）。所以这里查两路并取并集：dsh-plugin 为主，
    dsh-bundle 兜住老条目。

    抽样实测：`keywords:dsh-plugin` 的结果 100% 真的带该关键词（无蹭标签噪声），
    其中约 96% 声明了 dsh.bundle（即真的能被 dsh plugin add 装成层栈）。

  用法：
    node shell/tools/build-catalog.mjs                 # 写 shell/Resources/catalog.json
    node shell/tools/build-catalog.mjs --out /tmp/x.json
    node shell/tools/build-catalog.mjs --print         # 只打印摘要，不写文件
    node shell/tools/build-catalog.mjs --max-pages 4   # 少拉几页（调试用）
    node shell/tools/build-catalog.mjs --no-github-images

  展示图：npm 元数据里没有图标字段，所以从 repository 推导——
    · iconURL  = GitHub 归属者头像（正方形，适合卡片格子）
    · coverURL = 仓库的 OG 卡片图（宽图，适合详情页横幅）
  非 GitHub 或没有 repository 的条目留空，由壳侧退回「首字母 + 哈希配色」图块。
*/
import { writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const DEFAULT_OUT = resolve(HERE, '../Resources/catalog.json')
const REGISTRY = 'https://registry.npmjs.org/-/v1/search'
const PAGE = 250

// 上游约定的主关键词 + 兜底标签。并集去重后就是市场目录。
const QUERIES = ['dsh-plugin', 'dsh-bundle']
// 只保留 keywords 里真的带这些标签的条目（挡掉 npm 的相关性噪声）
const ACCEPTED = new Set(QUERIES)

const argv = process.argv.slice(2)
const PRINT_ONLY = argv.includes('--print')
const NO_IMAGES = argv.includes('--no-github-images')
const argValue = (name) => {
  const i = argv.indexOf(name)
  return i >= 0 ? (argv[i + 1] ?? null) : null
}
const OUT = argValue('--out') ? resolve(argValue('--out')) : DEFAULT_OUT
const MAX_PAGES = Number(argValue('--max-pages') ?? 60)

/** 从 npm 的 repository / homepage 串里抠出 GitHub 的 owner/repo。 */
function parseGitHub(url) {
  if (typeof url !== 'string' || !url) return null
  const m = url.match(/(?:github\.com|github:)[:/]+([^/]+)\/([^/#?]+)/i)
  if (!m) return null
  const owner = m[1]
  const repo = m[2].replace(/\.git$/i, '')
  if (!owner || !repo || owner === 'github.com') return null
  return { owner, repo }
}

/** 由链接推导展示图；拿不到就留空，交给壳侧退回落款图块。 */
function deriveImages(links) {
  if (NO_IMAGES) return { iconURL: null, coverURL: null }
  const gh = parseGitHub(links.repository) || parseGitHub(links.homepage)
  if (!gh) return { iconURL: null, coverURL: null }
  return {
    iconURL: `https://github.com/${gh.owner}.png?size=200`,
    coverURL: `https://opengraph.githubassets.com/1/${gh.owner}/${gh.repo}`,
  }
}

const str = (v) => (typeof v === 'string' && v ? v : null)
const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null)

// 全量要拉 ~20 页，registry 会限流：页间限速 + 429/5xx 退避重试。
const PAGE_DELAY_MS = 400
const MAX_RETRY = 6
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function fetchPage(keyword, from, attempt = 0) {
  const url = `${REGISTRY}?text=keywords:${encodeURIComponent(keyword)}&size=${PAGE}&from=${from}`
  const res = await fetch(url, { headers: { accept: 'application/json' } })
  if (res.status === 429 || res.status >= 500) {
    if (attempt >= MAX_RETRY) {
      throw new Error(`search 失败：HTTP ${res.status}（重试 ${attempt} 次仍失败） ${url}`)
    }
    const retryAfter = Number(res.headers.get('retry-after'))
    const wait = Number.isFinite(retryAfter) && retryAfter > 0
      ? retryAfter * 1000
      : Math.min(1000 * 2 ** attempt, 15000)
    console.log(`    ${keyword}: HTTP ${res.status}，${Math.round(wait / 1000)}s 后重试（第 ${attempt + 1}/${MAX_RETRY} 次）`)
    await sleep(wait)
    return fetchPage(keyword, from, attempt + 1)
  }
  if (!res.ok) throw new Error(`search 失败：HTTP ${res.status} ${url}`)
  return res.json()
}

/** 拉全某一路关键词的结果（受 MAX_PAGES 上限保护）。 */
async function collect(keyword) {
  const first = await fetchPage(keyword, 0)
  const total = Number(first.total) || 0
  let objects = first.objects ?? []
  console.log(`  ${keyword}: npm 报告 total=${total}`)
  for (let page = 1; page < MAX_PAGES && objects.length < total; page += 1) {
    await sleep(PAGE_DELAY_MS)
    const body = await fetchPage(keyword, page * PAGE)
    const batch = body.objects ?? []
    if (!batch.length) break
    objects = objects.concat(batch)
    console.log(`    ${keyword}: 已拉 ${objects.length}/${total}`)
  }
  if (objects.length < total) {
    throw new Error(`${keyword}: 只拉到 ${objects.length}/${total} 条，拒绝写入不完整的种子目录`)
  }
  return { total, objects }
}

function toEntry(o) {
  const p = o.package ?? {}
  const links = p.links ?? {}
  const downloads = o.downloads ?? {}
  const detail = (o.score ?? {}).detail ?? {}
  const keywords = Array.isArray(p.keywords) ? p.keywords.filter((k) => typeof k === 'string') : []
  return {
    name: p.name,
    version: p.version,
    description: str(p.description),
    keywords,
    publisher: str((p.publisher ?? {}).username),
    license: str(p.license),
    updated: str(o.updated) ?? str(p.date),
    links: {
      npm: str(links.npm) ?? `https://www.npmjs.com/package/${p.name}`,
      repository: str(links.repository),
      homepage: str(links.homepage),
    },
    downloads: { weekly: num(downloads.weekly), monthly: num(downloads.monthly) },
    score: { final: num(o.searchScore) ?? num(o.score?.final), popularity: num(detail.popularity) },
    ...deriveImages(links),
  }
}

const byName = new Map()
const totals = {}
for (const keyword of QUERIES) {
  const { total, objects } = await collect(keyword)
  totals[keyword] = total
  for (const o of objects) {
    const entry = toEntry(o)
    if (!entry.name) continue
    // 关键词必须真的命中，挡掉 npm 的相关性噪声
    if (!entry.keywords.some((k) => ACCEPTED.has(k))) continue
    const existing = byName.get(entry.name)
    // 同名重复时保留下载量更高的那份记录
    if (!existing || (entry.downloads.weekly ?? 0) > (existing.downloads.weekly ?? 0)) {
      byName.set(entry.name, entry)
    }
  }
}

// 名称排序：让文件 diffs 稳定（下载量天天变，按它排会让每次生成都整片翻动）
const plugins = [...byName.values()].sort((a, b) => a.name.localeCompare(b.name))

const doc = {
  catalogVersion: 2,
  generatedAt: new Date().toISOString(),
  source: `${REGISTRY}?text=keywords:${QUERIES.join(' | keywords:')}`,
  plugins,
}

const pct = (n) => `${Math.round((n / Math.max(plugins.length, 1)) * 100)}%`
const withIcon = plugins.filter((p) => p.iconURL).length
const withWeekly = plugins.filter((p) => p.downloads.weekly !== null).length
const withRepo = plugins.filter((p) => p.links.repository).length
const bytes = Buffer.byteLength(JSON.stringify(doc))
const summary = [
  QUERIES.map((k) => `${k}: npm total=${totals[k] ?? '?'}`).join('  |  '),
  `并集去重后 ${plugins.length} 条`,
  `有展示图 ${withIcon}/${plugins.length}（${pct(withIcon)}）`,
  `有周下载量 ${withWeekly}/${plugins.length}`,
  `有 repository ${withRepo}/${plugins.length}`,
  `序列化体积 ${(bytes / 1024 / 1024).toFixed(2)} MB`,
].join('\n  ')

if (PRINT_ONLY) {
  console.log('（--print，不写文件）\n  ' + summary)
} else {
  writeFileSync(OUT, JSON.stringify(doc) + '\n')
  console.log(`已写入 ${OUT}\n  ` + summary)
}
