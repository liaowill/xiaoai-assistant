#!/usr/bin/env python3
"""局域网发现 miIO 设备，取回音箱 DID 供 xiaogpt 的 MI_DID 使用。

只读探测：仅向 54321 端口发一个标准 hello 广播，不修改设备任何配置。
"""

import socket
import struct
import subprocess
import time

HELLO = bytes.fromhex(
    "21310020ffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
)
PORT = 54321


def local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("223.5.5.5", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def mac_of(ip):
    try:
        out = subprocess.check_output(["arp", "-a", "-n"], text=True, timeout=2)
        for line in out.splitlines():
            if f"({ip})" in line and " at " in line and "incomplete" not in line:
                return line.split(" at ")[1].split()[0]
    except Exception:
        pass
    return "-"


def main():
    ip = local_ip()
    subnet_bcast = ".".join(ip.split(".")[:3]) + ".255"
    print(f"本机 IP: {ip}")
    print(f"广播目标: {subnet_bcast} / 255.255.255.255 : {PORT}")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("", PORT))
    except OSError:
        sock.bind(("", 0))
    sock.settimeout(0.5)

    for target in (subnet_bcast, "255.255.255.255"):
        try:
            sock.sendto(HELLO, (target, PORT))
        except OSError:
            # macOS 上 255.255.255.255 常报 No route to host，子网广播够用，静默跳过
            continue

    seen = {}
    deadline = time.time() + 4
    while time.time() < deadline:
        try:
            data, addr = sock.recvfrom(2048)
        except socket.timeout:
            continue
        except OSError:
            break
        if len(data) < 32 or data[:2] != b"\x21\x31":
            continue
        try:
            _magic, _length, _unknown, did, _stamp = struct.unpack(">HHIII", data[:16])
        except struct.error:
            continue
        # 本机广播被自己收回来时 DID 是 0xffffffff，属于噪声
        if addr[0] == ip or did == 0xFFFFFFFF:
            continue
        key = (addr[0], did)
        if key in seen:
            continue
        seen[key] = True
        print(f"设备 IP: {addr[0]:<16} DID: {did:<12} MAC: {mac_of(addr[0])}")

    sock.close()
    if not seen:
        print("\n未收到 miIO 应答。可能原因：")
        print("  1. 设备与本机不在同一子网，或路由器开了 AP 隔离")
        print("  2. 运行环境禁止 UDP 广播")
        print("  3. 音箱休眠中，先喊一声『小爱同学』再重试")
        print("兜底：micli list 从米家云端取 DID，效果一样。")
    else:
        print(f"\n共发现 {len(seen)} 台。把对应 DID 填进 MI_DID，再用 micli list 核对一次。")


if __name__ == "__main__":
    main()
