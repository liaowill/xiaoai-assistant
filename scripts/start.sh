#!/usr/bin/env bash
# 第一代小米AI音箱（S12A）接大模型 · 一键启动
set -euo pipefail
cd "$(dirname "$0")"

# 优先读环境变量；没给就从 macOS 钥匙串读（安装.command 存进去的）
# 这样开机自动启动时也不需要有人来输密码
kc_get() { security find-generic-password -a "xiaoai" -s "$1" -w 2>/dev/null || true; }
: "${MI_USER:=$(kc_get XiaoAI-LLM-MI-USER)}"
: "${MI_PASS:=$(kc_get XiaoAI-LLM-MI-PASS)}"
: "${OPENAI_API_KEY:=$(kc_get XiaoAI-LLM-API-KEY)}"
: "${MI_DID:=$(kc_get XiaoAI-LLM-DID)}"
export MI_USER MI_PASS OPENAI_API_KEY MI_DID

: "${MI_USER:?缺小米账号（填手机号即可），请双击 安装.command 填一次}"
: "${MI_PASS:?缺小米密码，请双击 安装.command 填一次}"
: "${OPENAI_API_KEY:?缺模型 API key，请双击 安装.command 填一次}"
: "${MI_DID:?缺设备 DID，请双击 安装.command 填一次}"

if [ ! -x .venv/bin/xiaogpt ]; then
  echo "首次运行，创建虚拟环境并安装依赖…"
  python3 -m venv .venv
  ./.venv/bin/pip install -q -U pip
  # 实测有效组合：国内源 + 只装预编译 wheel
  # 不用 xiaogpt[locked]：锁定的依赖在 Python 3.13 上会卡在源码编译
  # 只装 xiaogpt，它会自己带 miservice==3.0.1。
  # 千万别再加 miservice_fork：两个包都写 miservice/ 目录，会把官方版覆盖掉，
  # 导致 await load_token() 崩溃、短信验证码登录能力丢失。
  ./.venv/bin/pip install -q -U -i https://pypi.tuna.tsinghua.edu.cn/simple \
    --no-cache-dir --only-binary=:all: --timeout 20 --retries 1 \
    xiaogpt
fi

# xiaogpt 与登录脚本共用同一个 token 文件
export XIAOGPT_MI_TOKEN_PATH="$PWD/.mi.token"

# 已有有效凭证就跳过；首次（或凭证过期）会弹窗收一次小米短信验证码。
# 官方 miservice 3.0.1 自带 OTP 流程，不需要去浏览器复制 passToken。
if ! ./.venv/bin/python 小米登录.py; then
  echo "小米账号没验证完，服务未启动。请重新双击 安装.command 再试一次。"
  exit 1
fi

echo "启动 xiaogpt | 设备编号 ${MI_DID} | 模型与硬件代号见 xiao_config.yaml"
echo "提示：小米接口走直连，接国内模型不要开全局代理"
# 不带 -v：DEBUG 日志会把完整配置（含密码与 API key）写进 service.log
exec ./.venv/bin/xiaogpt --config xiao_config.yaml
