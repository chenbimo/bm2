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
      { text: '安装与升级', link: '/guide/install' },
      { text: '配置', link: '/guide/configuration' },
      { text: '环境变量', link: '/guide/environment' },
    ],
  },
  {
    text: '使用',
    items: [
      { text: '命令', link: '/guide/commands' },
      { text: '负载均衡', link: '/guide/load-balancing' },
      { text: '状态与日志', link: '/guide/state-and-logs' },
    ],
  },
  {
    text: '上报',
    items: [{ text: '通知', link: '/guide/notifications' }],
  },
  {
    text: '参考',
    items: [{ text: '功能特性', link: '/guide/features' }],
  },
]

export default defineConfig({
  // 站点挂在 https://yicode.tech/bm2 这个子路径下,base 必须与它一致。不声明
  // 的话,资源与内部链接会指向站点根目录(那里是官网 SPA),打开就是白屏。
  // 这是部署形态唯一的切换点:换到独立域名(根路径)时改成 '/',挂子路径时写回来。
  base: '/bm2/',
  lang: 'zh-CN',
  title: 'bm2',
  description: 'Bun 与 Node.js 的进程管理器，MoonBit 编写。',
  cleanUrls: true,
  lastUpdated: true,
  // 产物落在 docs/dist/(默认是 .vitepress/dist,藏在配置目录里,部署脚本引用它
  // 容易写错)。部署侧只认 docs/dist 这一处,改这里就要同步改部署脚本。
  outDir: 'dist',
  themeConfig: {
    socialLinks: [{ icon: 'github', link: repository }],
    nav: [
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
