# 发布到 GitHub 前，先看这一页

> 这份文档写给发布者，可以留在仓库里，方便以后每次升级版本复核。

## 一、三条结论

1. **不要整包上传现有工作目录。** 里面有小米登录 token、真实问答、写死了个人姓名路径的源码，以及一堆过程截图。
2. **直接把 `.app` 打包发出去，别人打不开也跑不起来。** 原因见第三节。
3. **别人不可能「下载就能用」。** 他必须自己有小米账号、大模型 Key 和第一代小爱音箱。这一条要写在 README 最前面，否则 issue 区会全是「怎么用」。

---

## 二、隐私黑名单（一个都别传）

| 文件 / 位置 | 里面有什么 | 处理 |
| --- | --- | --- |
| `.mi.token` | 小米 userId / passToken / micoapi serviceToken，等于账号登录态 | 绝不上传；若已上传立刻改密码 |
| `.verify_url` | 安全验证一次性票据 | 删除 |
| `service.log` | 真实问答、启动信息 | 不上传 |
| `conversations*.jsonl`、`deleted_conversations.jsonl` | 真实对话内容 | 不上传 |
| `app-src/*.png`（过程截图） | 真实问答、浏览器后台页面、API 平台页面 | 一律不传；重新截干净图 |
| `.venv/` | 已安装依赖与缓存 | 不上传 |
| `main.swift` 里的绝对路径 | 写死个人主目录的完整路径，既暴露姓名，也让别人跑不起来 | 改成动态路径 |
| `Info.plist` / LaunchAgent 的包名 | 带个人昵称的 Bundle ID | 换成中性名称 |
| `一键设置.command` / `start.sh` / `小米登录.py` / `discover.py` | 硬编码路径、本机 IP、音箱 DID、MAC 地址 | 脱敏后再传 |
| `install.log` | 本机路径 | 不上传 |

另外：**聊天里、日志里出现过的 API Key 和小米密码，即使不写进仓库，也建议轮换。**

---

## 三、为什么 `.app` 不能直接发

| 障碍 | 后果 | 怎么解决 |
| --- | --- | --- |
| 只有 ad-hoc 签名、未公证 | 从 GitHub 下载会带隔离属性，Gatekeeper 提示「身份不明的开发者」，多数人打不开 | Apple Developer 账号（约 $99/年）+ 正式签名 + 公证；或改走源码本地编译 |
| 路径写死到个人目录 | 别人电脑上没有这个目录，启动脚本直接失败 | 路径动态化 |
| 依赖本机 `.venv` 和钥匙串里 4 项凭据 | 别人两样都没有 | 首次安装引导填写 + 自动建虚拟环境 |
| 只编了 x86_64 | Apple Silicon 机器需要 Rosetta 2 | 本地编译天然解决；或编通用二进制 |

还有一个体验问题：`.app` 是目录，得先打包成 zip/dmg，GitHub 单文件也有大小限制；而 Python 依赖上百 MB，全打进包体积很可观。

---

## 四、推荐形态：源码 + 一键安装

| 对比 | 源码 + 一键安装（推荐） | 直接发二进制 |
| --- | --- | --- |
| 别人要做的 | 解压 → 双击一次安装向导 | 下载 dmg → 拖进应用程序 → 仍要填账号 |
| 费用 | 0 | 开发者账号 + 公证流程 |
| Gatekeeper 拦截 | 不受影响（本机编译） | 必须签名公证 |
| Intel / Apple Silicon | 都支持 | 要额外做通用二进制 |
| 凭据是否进仓库 | 零 | 零（但必须确认包里没预置） |
| 维护成本 | 小 | 大 |

**结论：走源码一键安装。** 安装只有一次，装完以后就是「双击软件打开」，体验上和下载软件几乎一样，且不用花一分钱、不用处理签名公证。

---

## 五、要准备的资料清单

已备好：

- [x] `README.md` —— 面向使用者，把「自己要准备什么」写在最前
- [x] `LICENSE` —— MIT + 第三方依赖声明
- [x] `PRIVACY.md` —— 凭据与数据流向说明
- [x] `.gitignore` —— 把隐私文件全挡在仓库外
- [x] `config/xiao_config.example.yaml` —— 不含密钥的配置模板
- [x] `config/credentials.example.env` —— 只有键名、值留空
- [x] `scripts/check-secrets.sh` —— 每次 push 前跑一遍
- [x] `assets/AppIcon.icns` + `make_icon.swift` —— 图标资源

已补齐：

- [x] `main.swift`：路径改为动态（Application Support）、Bundle ID / LaunchAgent 改为中性名
- [x] `Info.plist`：中性包名，版本号与源码一致
- [x] `安装.command`：中文弹窗收凭据 → 写钥匙串 → 布置运行目录 → 建 venv → 装依赖 → 编译 → 装进应用程序
- [x] `scripts/build_app.sh`：编译、组装 bundle、ad-hoc 签名、逐文件安装、刷新启动台图标
- [x] `scripts/start.sh`、`小米登录.py`、`discover.py`：全部去掉个人路径与设备信息
- [x] `assets/screenshot.png`：用示例问答重截，不含真实对话、浏览器后台、钥匙串窗口
- [x] `.github/ISSUE_TEMPLATE/bug_report.md`：写明不要贴 Key、token 和日志原文

发布时仍要注意：

- [ ] Release 里只放源码 zip，**不放 `.app` 二进制**（adhoc 签名 + 未公证，别人下载会被拦）
- [ ] 每次 push 前跑一遍 `bash scripts/check-secrets.sh`
- [ ] 设为公开后，用无痕窗口把仓库看一遍

**当前状态**：本地仓库已就绪，尚未推送、尚未公开。`gh` 命令行工具没有安装，也没有登录任何 GitHub 账号，所以推送这一步需要账号持有者完成，见 README 末尾的上传说明。

---

## 六、发布动作顺序

1. 在**全新空目录**里 `git init`，不要在现有工作目录里 `git add .`
2. 只把清单里打勾的文件拷进去
3. 运行 `bash scripts/check-secrets.sh`
4. `git add` 之前用 `git status` 逐个数一遍文件
5. 第一次提交后 `git show --stat` 复核
6. 设为公开后，用无痕窗口打开看一遍，搜一下自己的小米 ID、手机号、姓名
7. 以后每次升级版本，先跑自检脚本

---

## 七、万一已经误传过

**删文件没用，git 历史能翻出来。** 必须：

1. 立刻改小米账号密码，让旧 token 失效
2. 在模型平台作废并重建 API Key，检查有没有异常用量
3. 删除仓库或用 `git filter-repo` 重写历史
4. 提醒可能看到的人

---

## 八、合规提醒

- README 要有免责声明：非小米官方、账号风险自负、仅供个人学习自用。
- 上游 `xiaogpt 3.24`、`miservice 3.0.1` 均为 MIT，`republic` 按其随包 LICENSE；保留出处与许可证文件。
- 本方案通过小米云接口旁路实现，公开项目建议明确「个人自用性质」。
- 任何情况下都不要替使用者托管账号或密钥，也不要在 issue 里索要别人的 Key。
