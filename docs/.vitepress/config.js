import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitepress'

// `moon.mod` is the single home of the two facts read below. Reading them at
// build time is what stops a release from having to remember a second place —
// the mistake that once left the README promising log generations the code no
// longer kept.
const moonMod = readFileSync(
  fileURLToPath(new URL('../../moon.mod', import.meta.url)),
  'utf8',
)

function moonModField(name) {
  const found = new RegExp(`^\\s*${name}\\s*=\\s*"([^"]+)"`, 'm').exec(moonMod)
  if (found === null) {
    throw new Error(`docs: cannot read ${name} from moon.mod`)
  }
  return found[1]
}

const version = moonModField('version')
const repository = moonModField('repository')

// The version is rendered from here rather than written into a page: a page is
// a copy that goes stale, while this is read from the release itself. It links
// to the releases list, which is what a reader wants when they click it.
const sidebar = [
  {
    text: '开始',
    items: [
      { text: '安装与升级 bm2', link: '/guide/install' },
      { text: '网络与国内镜像', link: '/guide/registry-mirror' },
      { text: '十五分钟上手', link: '/guide/quickstart' },
    ],
  },
  {
    text: '配置',
    items: [
      { text: '配置参考', link: '/guide/configuration' },
      { text: '环境变量', link: '/guide/environment' },
      { text: '状态与日志', link: '/guide/state-and-logs' },
    ],
  },
  {
    text: '执行模式',
    items: [
      { text: '两种模式怎么选', link: '/guide/load-balancing' },
      { text: 'cluster 模式', link: '/guide/mode-cluster' },
      { text: 'fork 模式', link: '/guide/mode-fork' },
    ],
  },
  {
    text: '使用',
    items: [
      { text: '命令参考', link: '/guide/commands' },
      { text: '通知', link: '/guide/notifications' },
    ],
  },
  {
    text: '参考',
    items: [
      { text: '能力总览', link: '/guide/features' },
      { text: '排障与常见问题', link: '/guide/troubleshooting' },
      { text: '从 pm2 迁移', link: '/guide/migration-from-pm2' },
    ],
  },
]

export default defineConfig({
  // 站点挂在 https://bm2.moonbitlang.dev 这个子域名下,是根路径,所以 base 为 '/'。
  // 这是部署形态唯一的切换点:换回子路径部署时,这里要和路径前缀一致,否则资源与
  // 内部链接会指向站点根,打开就是白屏。
  base: '/',
  lang: 'zh-CN',
  title: 'bm2',
  description: 'Bun 与 Node.js 的进程管理器，MoonBit 编写。',
  cleanUrls: true,
  lastUpdated: true,
  // 产物落在 docs/dist/(默认是 .vitepress/dist,藏在配置目录里,部署脚本引用它
  // 容易写错)。部署侧只认 docs/dist 这一处,改这里就要同步改部署脚本。
  outDir: 'dist',
  // 图标统一用 site 仓库的那套素材(favicon.svg + icons/*.png),所有项目共用同一个印记;
  // 项目自己的 logo 由 yicode-tech/scripts/moduleLogo 生成为长方形字标。
  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/favicon.svg' }],
    ['link', { rel: 'apple-touch-icon', sizes: '180x180', href: '/icons/apple-touch-icon-180.png' }],
  ],
  themeConfig: {
    logo: { src: '/logo.svg', width: 46, height: 26, alt: 'bm2' },
    siteTitle: false,
    socialLinks: [{ icon: 'github', link: repository }],
    nav: [
      // 官网门户入口:每个页面顶栏都能一键回到 moonbitlang.dev。
      { text: 'Moonkit 官网', link: 'https://moonbitlang.dev' },
      { text: '指南', link: '/guide/install' },
      // 版本号来自 moon.mod，不在任何页面里硬编码。
      { text: `v${version}`, link: `${repository}/releases` },
    ],
    sidebar: { '/guide/': sidebar },
    outline: { label: '本页目录', level: [2, 3] },
    docFooter: { prev: '上一页', next: '下一页' },
    // 2.0 移除了平铺的 lastUpdatedText,改写成嵌套对象。这类文案键被移除后不报错、
    // 静默失效,所以每次升级 VitePress 都值得逐个核对一遍。
    lastUpdated: { text: '最后更新' },
    darkModeSwitchLabel: '外观',
    sidebarMenuLabel: '目录',
    returnToTopLabel: '回到顶部',
  },
})
