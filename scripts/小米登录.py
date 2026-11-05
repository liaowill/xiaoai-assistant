#!/usr/bin/env python3
"""小米账号登录：已有有效 token 就跳过，否则弹窗收一次短信/邮件验证码。

只负责生成 .mi.token，不打印任何账号、密码、token 内容。
依赖官方 miservice==3.0.1（不能用 miservice_fork 覆盖）。
"""
import asyncio
import json
import pathlib
import subprocess
import sys

from aiohttp import ClientSession
from miservice import MiAccount

ROOT = pathlib.Path(__file__).parent
TOKEN_PATH = str(ROOT / ".mi.token")
DEVICE_ID = "A1B2C3D4E5F60718"
SID = "micoapi"


def kc(service: str) -> str:
    try:
        return subprocess.check_output(
            ["security", "find-generic-password", "-a", "xiaoai", "-s", service, "-w"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except Exception:
        return ""


def popup(title: str, message: str) -> str:
    """中文弹窗输入框；用户取消或超时返回空串。"""
    script = (
        'text returned of (display dialog "'
        + message
        + '" default answer "" buttons {"好"} default button "好" with title "'
        + title
        + '")'
    )
    try:
        r = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=300,
        )
        return r.stdout.strip()
    except Exception:
        return ""


async def otp_callback(otp_method: str) -> str:
    label = "手机短信" if otp_method == "Phone" else "邮箱"
    message = (
        "小米账号需要一次安全验证。\\n\\n"
        f"验证码已经发到你的{label}，请查收后填在下面。\\n\\n"
        "填完点「好」，剩下的我来处理。"
    )
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(None, lambda: popup("小爱音箱 · 安全验证", message))


def saved_token() -> dict | None:
    try:
        d = json.loads(pathlib.Path(TOKEN_PATH).read_text())
    except Exception:
        return None
    if isinstance(d, dict) and all(k in d for k in ("deviceId", "userId", "passToken")):
        return d
    return None


async def token_is_valid(session, token: dict) -> bool:
    """只走第一步 serviceLogin，不调 login()：登录失败会删掉 token 文件。"""
    acc = MiAccount(session, "unused", "unused", None)
    acc.token = {
        "deviceId": token["deviceId"],
        "userId": token["userId"],
        "passToken": token["passToken"],
    }
    try:
        resp = await acc._serviceLogin(f"serviceLogin?sid={SID}&_json=true")
        return resp.get("code") == 0 and "userId" in resp
    except Exception:
        return False


async def main() -> int:
    user = kc("XiaoAI-LLM-MI-USER")
    password = kc("XiaoAI-LLM-MI-PASS")
    if not user or not password:
        print("小米账号或密码没存好，请双击 安装.command 填一次")
        return 1

    # 固定设备号：小米会把验证过的 deviceId 记住，减少再次风控
    if not pathlib.Path(TOKEN_PATH).exists():
        pathlib.Path(TOKEN_PATH).write_text(json.dumps({"deviceId": DEVICE_ID}))
        pathlib.Path(TOKEN_PATH).chmod(0o600)

    async with ClientSession() as session:
        token = saved_token()
        if token and await token_is_valid(session, token):
            print("小米账号已登录（沿用上次的凭证），无需再验证")
            return 0

        # 官方 OTP 流程会自动发送短信，然后回调弹窗收验证码，只需用户填一次
        acc = MiAccount(session, user, password, TOKEN_PATH, otp_callback=otp_callback)
        ok = await acc.login(SID)
        if ok:
            pathlib.Path(TOKEN_PATH).chmod(0o600)
            print("小米账号登录成功，凭证已保存，以后开机不用再验证")
            return 0
        print("小米账号验证没完成，可以重新双击 安装.command 再试一次")
        return 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
