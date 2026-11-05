#!/usr/bin/env bash
# 小爱助手 · 双击安装
# 全程中文弹窗，不用敲命令。凭据只写进这台 Mac 的「钥匙串」，不写进任何文件。
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$HOME/Library/Application Support/XiaoAIAssistant"
APP="/Applications/小爱助手.app"
LABEL="com.xiaoai-assistant.mac"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

KC_ACCOUNT="xiaoai"
S_USER="XiaoAI-LLM-MI-USER"
S_PASS="XiaoAI-LLM-MI-PASS"
S_KEY="XiaoAI-LLM-API-KEY"
S_DID="XiaoAI-LLM-DID"
TITLE="小爱助手 · 安装"

say() {
  osascript -e "display dialog \"$1\" buttons {\"好\"} default button \"好\" with title \"$TITLE\"" >/dev/null 2>&1 || true
}
ask() {
  # $1 提示  $2 默认值  $3 yes=隐藏输入
  local hidden=""
  [ "${3:-no}" = "yes" ] && hidden=" with hidden answer"
  osascript -e "text returned of (display dialog \"$1\" default answer \"$2\"$hidden buttons {\"好\"} default button \"好\" with title \"$TITLE\")" 2>/dev/null || true
}
confirm() {
  osascript -e "button returned of (display dialog \"$1\" buttons {\"取消\",\"继续\"} default button \"继续\" with title \"$TITLE\")" 2>/dev/null || true
}
kc_get() { security find-generic-password -a "$KC_ACCOUNT" -s "$1" -w 2>/dev/null || true; }
kc_set() { security add-generic-password -a "$KC_ACCOUNT" -s "$1" -w "$2" -U >/dev/null 2>&1; }

clear
echo "=========================================="
echo "  小爱助手 · 安装"
echo "=========================================="
echo ""

# ---------- 前置说明 ----------
go=$(confirm "安装前请确认已备好：\n\n1 第一代小米 AI 音箱（MDZ-25-DA / MDZ-25-DT）\n2 小米账号和密码，手机能收短信验证码\n3 一个大模型 API Key（示例用 LongCat，也可换其他 OpenAI 兼容服务）\n\n账号和密钥只存进这台 Mac 的钥匙串，不写进任何文件，也不会上传。\n\n安装约需 3-5 分钟，中间请不要关闭这个窗口。")
if [ "$go" != "继续" ]; then echo "已取消。"; exit 0; fi

# ---------- 环境检查 ----------
if ! command -v python3 >/dev/null 2>&1; then
  say "没有找到 python3。请先安装 Python 3.11 或更新版本，再重新双击 安装.command。"
  exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
  say "缺少 Xcode 命令行工具。请打开「终端」执行一次 xcode-select --install，装完后再回来双击 安装.command。"
  exit 1
fi

# ---------- 收集凭据（已存过就跳过） ----------
saved_user=$(kc_get "$S_USER")
saved_pass=$(kc_get "$S_PASS")
saved_key=$(kc_get "$S_KEY")
saved_did=$(kc_get "$S_DID")

if [ -n "$saved_user" ] && [ -n "$saved_pass" ] && [ -n "$saved_key" ] && [ -n "$saved_did" ]; then
  echo "==> 钥匙串里已有设置，跳过填写"
  mi_user="$saved_user"; mi_pass="$saved_pass"; api_key="$saved_key"; did="$saved_did"
else
  mi_user=$(ask "第 1 步 / 共 4 步\n\n小米账号（手机号 / 邮箱 / 数字 ID 都行）" "$saved_user" no)
  [ -z "$mi_user" ] && { say "没填账号，已取消。"; exit 1; }

  mi_pass=$(ask "第 2 步 / 共 4 步\n\n小米账号密码（输入不显示，只存进钥匙串）\n\n如果平时只用短信登录、没设过密码，请先去小米账号网页设一个。" "$saved_pass" yes)
  [ -z "$mi_pass" ] && { say "没填密码，已取消。"; exit 1; }

  api_key=$(ask "第 3 步 / 共 4 步\n\n大模型 API Key（可直接 Cmd+V 粘贴）" "$saved_key" yes)
  [ -z "$api_key" ] && { say "没填 API Key，已取消。"; exit 1; }

  # 局域网自动探测设备编号；探测不到才让用户手填，绝不内置任何人的 DID
  found=$(python3 "$ROOT/scripts/discover.py" 2>/dev/null | sed -n 's/.*DID:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)
  did=$(ask "第 4 步 / 共 4 步\n\n音箱设备编号 DID\n\n已在局域网自动探测，直接点「好」即可；如果这里是空的，请手动填入。" "${saved_did:-$found}" no)
  [ -z "$did" ] && { say "没填设备编号，已取消。"; exit 1; }
fi

kc_set "$S_USER" "$mi_user" || { say "写入钥匙串失败，请检查系统权限后重试。"; exit 1; }
kc_set "$S_PASS" "$mi_pass"
kc_set "$S_KEY" "$api_key"
kc_set "$S_DID" "$did"
echo "==> 凭据已存入钥匙串"

# ---------- 布置运行目录 ----------
mkdir -p "$WORK"
cp "$ROOT/scripts/start.sh" "$WORK/start.sh"
cp "$ROOT/scripts/小米登录.py" "$WORK/小米登录.py"
cp "$ROOT/scripts/discover.py" "$WORK/discover.py"
cp "$ROOT/config/xiao_config.example.yaml" "$WORK/xiao_config.yaml"
cp "$ROOT/安装.command" "$WORK/重新设置.command"
chmod +x "$WORK/start.sh" "$WORK/重新设置.command"
echo "==> 运行目录：$WORK"

# ---------- Python 依赖 ----------
if [ ! -x "$WORK/.venv/bin/xiaogpt" ]; then
  echo "==> 首次安装依赖，约 2-5 分钟，请不要关窗口…"
  python3 -m venv "$WORK/.venv" || { say "创建虚拟环境失败。"; exit 1; }
  "$WORK/.venv/bin/pip" install -q -U pip >/dev/null 2>&1 || true
  if ! "$WORK/.venv/bin/pip" install -q -U -i https://pypi.tuna.tsinghua.edu.cn/simple \
      --no-cache-dir --only-binary=:all: --timeout 20 --retries 1 xiaogpt; then
    say "依赖没装好，多半是网络问题。请连上网络后重新双击 安装.command 再试一次。"
    exit 1
  fi
fi
echo "==> 依赖就绪"

# ---------- 编译并安装应用 ----------
echo "==> 编译并安装应用"
if ! bash "$ROOT/scripts/build_app.sh"; then
  say "编译没成功。请把这个窗口里的报错内容截图发给维护者。"
  exit 1
fi

# ---------- 开机自启（可选） ----------
auto=$(osascript -e "button returned of (display dialog \"要不要开机自动打开小爱助手？\n\n选「要」：以后 Mac 一登录就自动连上。\n选「不用」：以后自己双击软件。\" buttons {\"不用\",\"要\"} default button \"要\" with title \"$TITLE\")" 2>/dev/null || true)
if [ "$auto" = "要" ]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>$APP</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
</dict>
</plist>
PLIST
  launchctl unload "$PLIST" >/dev/null 2>&1 || true
  launchctl load "$PLIST" >/dev/null 2>&1 || true
  echo "==> 开机自启配置已写入（若未立即生效，下次登录会自动加载）"
fi

# ---------- 小米账号验证 ----------
echo "==> 校验小米账号，可能会弹一次短信验证码，请留意屏幕"
if ! XIAOGPT_MI_TOKEN_PATH="$WORK/.mi.token" "$WORK/.venv/bin/python" "$WORK/小米登录.py"; then
  say "小米账号还没验证完。请重新双击 安装.command 再走一次，填入收到的验证码。"
  exit 1
fi

# ---------- 完成 ----------
echo "==> 打开小爱助手"
open "$APP"
say "装好了。\n\n以后只要双击「小爱助手」，状态变绿就能用。对音箱说「小爱同学，请问……」开头提问。\n\n这个黑色窗口可以直接关掉。"
echo ""
echo "安装完成。"
