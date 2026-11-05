#!/usr/bin/env bash
# 发布前自检：确认仓库里没有密钥、账号痕迹、个人路径或真实对话数据。
# 用法：bash scripts/check-secrets.sh
# 出现任何 [FAIL] 都不要 push。

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
FAIL=0

pass() { printf "  [OK]   %s\n" "$1"; }
fail() { printf "  [FAIL] %s\n" "$1"; FAIL=1; }

echo "小爱助手 · 发布前隐私自检"
echo "目录：$ROOT"
echo ""

# 1. 不该出现在仓库里的文件
DIRTY=0
for f in .mi.token .verify_url service.log install.log .env \
         conversations.jsonl conversations_backup.jsonl deleted_conversations.jsonl; do
  [ -e "$f" ] && { fail "存在隐私文件：$f"; DIRTY=1; }
done
[ -d .venv ] && { fail "存在 .venv/（Python 虚拟环境）"; DIRTY=1; }
[ "$DIRTY" -eq 0 ] && pass "未发现 token / 日志 / 对话记录 / 虚拟环境"

# 2. 源码里写死的本机绝对路径
HITS=$(grep -rIlE '/Users/[A-Za-z0-9._-]+/' --include='*.swift' --include='*.sh' \
      --include='*.py' --include='*.yaml' --include='*.command' . 2>/dev/null || true)
if [ -n "$HITS" ]; then
  grep -rInE '/Users/[A-Za-z0-9._-]+/' --include='*.swift' --include='*.sh' \
      --include='*.py' --include='*.yaml' --include='*.command' . 2>/dev/null | head -20
  fail "源码里还有写死的本机绝对路径（会暴露姓名，且别人电脑上跑不起来）"
else
  pass "源码里没有写死的本机绝对路径"
fi

# 3. 真实 API Key
KEYS=$(grep -rIlE '(ak_|sk-)[A-Za-z0-9_-]{16,}' --exclude-dir=.git . 2>/dev/null || true)
if [ -n "$KEYS" ]; then
  printf '%s\n' "$KEYS" | head -20
  fail "发现疑似真实 API Key"
else
  pass "没有发现真实 API Key"
fi

# 4. 小米登录态
TOK=$(grep -rIlE '"(passToken|serviceToken|userId)"[[:space:]]*:' \
      --include='*.json' --include='*.jsonl' . 2>/dev/null || true)
if [ -n "$TOK" ]; then fail "发现小米登录态字段值"; else pass "没有小米登录态数据"; fi

# 5. 提交历史里是否混进了大文件或可疑文件
if [ -d .git ]; then
  TRACKED=$(git ls-files 2>/dev/null | grep -E '\.venv/|\.token$|\.jsonl$|service\.log$|\.app/' || true)
  if [ -n "$TRACKED" ]; then
    printf '%s\n' "$TRACKED" | head -20
    fail "git 已跟踪敏感文件，先用 git rm --cached 移出"
  else
    pass "git 跟踪列表干净"
  fi
fi

echo ""
echo "以下四项机器查不出来，请人工再看一眼："
echo "  - Bundle ID / LaunchAgent 名称里有没有带你的姓名或昵称"
echo "  - README、配置、截图里有没有出现小米 ID、手机号、邮箱"
echo "  - 截图里有没有真实问答、浏览器后台页面、钥匙串窗口"
echo "  - git 历史里有没有「提交过又删掉」的敏感文件（公开后仍可被翻出来）"

echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "结论：不要发布。先清掉上面 [FAIL] 的项目，再跑一次。"
  exit 1
fi
echo "结论：自动检查通过，人工项确认无误后可以发布。"
