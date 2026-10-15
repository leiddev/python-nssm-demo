# -*- coding: utf-8 -*-
"""Python + NSSM Windows 服务示例程序。

配合 NSSM 使用时，Python 端不需要 pywin32 / win32serviceutil，
只要满足下面 5 条"服务友好"约定即可：

  1. 常驻循环：程序不能跑完就退出，必须一直待着。
  2. 可优雅停止：注册 SIGINT(Ctrl+C) / SIGBREAK(Ctrl+Break) 处理函数，
     收到信号后把 stop_event 置位，让主循环自己收尾（NSSM 停止服务时
     默认就是先发 Ctrl+C，超时后才强杀进程）。
  3. 退出码有语义：0 = 正常结束（NSSM 不再重启），非 0 = 异常
     （配合 AppExit Default Restart，NSSM 会自动拉起）。
  4. 日志自己写文件：stdout 被重定向到文件时 Python 会做缓冲，
     只靠 print 会出现"日志半天不落盘"的假象。
  5. 用 python.exe 而不是 pythonw.exe：没有控制台就收不到 Ctrl+C。

自检用法（不需要管理员）：
    python -u service_demo.py --once          # 只跑一轮
    python -u service_demo.py --interval 2    # 前台常驻，Ctrl+C 退出
"""
from __future__ import annotations

import argparse
import json
import logging
import logging.handlers
import os
import signal
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent

# 主循环与信号处理函数之间的通信桥梁：
# 只要它被 set()，主循环就会立刻结束，不用等 sleep 走完。
stop_event = threading.Event()

log = logging.getLogger("demo-service")

EXIT_OK = 0
EXIT_FATAL = 1


def now_str() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


# --------------------------------------------------------------------------- #
# 命令行 / 配置
# --------------------------------------------------------------------------- #
def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="NSSM + Python Windows 服务示例")
    parser.add_argument(
        "--interval", type=float,
        default=float(os.environ.get("DEMO_INTERVAL", 5)),
        help="心跳间隔秒数，也可用环境变量 DEMO_INTERVAL（默认 5）",
    )
    parser.add_argument(
        "--log-dir",
        default=os.environ.get("DEMO_LOG_DIR", str(BASE_DIR / "logs")),
        help="日志目录（默认 <脚本目录>/logs）",
    )
    parser.add_argument(
        "--data-dir",
        default=os.environ.get("DEMO_DATA_DIR", str(BASE_DIR / "data")),
        help="数据目录（默认 <脚本目录>/data）",
    )
    parser.add_argument(
        "--graceful-timeout", type=float,
        default=float(os.environ.get("DEMO_GRACEFUL_TIMEOUT", 5)),
        help="收到停止信号后最多花多久收尾（默认 5 秒）",
    )
    parser.add_argument(
        "--log-level",
        default=os.environ.get("DEMO_LOG_LEVEL", "INFO"),
        help="日志级别（默认 INFO）",
    )
    parser.add_argument(
        "--once", action="store_true",
        help="只执行一轮就退出，用于自检",
    )
    return parser.parse_args(argv)


def setup_logging(log_dir: Path, level: str) -> None:
    """写自己的日志文件，并做按大小滚动。"""
    log_dir.mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter(
        "%(asctime)s [%(levelname)-5s] %(process)d %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    file_handler = logging.handlers.RotatingFileHandler(
        log_dir / "service.log",
        maxBytes=5 * 1024 * 1024,
        backupCount=5,
        encoding="utf-8",
    )
    file_handler.setFormatter(fmt)

    root = logging.getLogger()
    root.setLevel(getattr(logging, str(level).upper(), logging.INFO))
    root.handlers.clear()
    root.addHandler(file_handler)

    # 前台调试时顺便打到控制台；被 NSSM 重定向到文件时 isatty() 为 False，
    # 就不会重复记一遍。
    if sys.stdout is not None and sys.stdout.isatty():
        stream_handler = logging.StreamHandler(sys.stdout)
        stream_handler.setFormatter(fmt)
        root.addHandler(stream_handler)


# --------------------------------------------------------------------------- #
# 优雅停止：信号处理
# --------------------------------------------------------------------------- #
def install_stop_handlers() -> None:
    """注册 Ctrl+C / Ctrl+Break 处理函数。

    处理函数里只做"置一个标志"这种最轻量的操作，真正的收尾放主循环做。
    """

    def _handle(signum, _frame):
        try:
            name = signal.Signals(signum).name
        except ValueError:  # pragma: no cover
            name = str(signum)
        log.warning("收到停止信号 %s(%s)，开始优雅退出", name, signum)
        stop_event.set()

    for sig_name in ("SIGINT", "SIGBREAK", "SIGTERM"):
        sig = getattr(signal, sig_name, None)
        if sig is None:
            continue
        try:
            signal.signal(sig, _handle)
        except (ValueError, OSError) as exc:  # 非主线程等情况
            log.warning("注册信号 %s 失败：%s", sig_name, exc)


# --------------------------------------------------------------------------- #
# 业务逻辑（示例：处理投递到 inbox 的文件 + 写状态文件）
# --------------------------------------------------------------------------- #
def write_status(path: Path, payload: dict) -> None:
    """原子写状态文件，方便外部（或人）确认服务还活着。"""
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def process_inbox(inbox: Path, done: Path) -> int:
    """把 data/inbox/*.txt 处理掉并移到 data/done/。"""
    processed = 0
    for item in sorted(inbox.glob("*.txt")):
        try:
            text = item.read_text(encoding="utf-8", errors="replace")
            log.info("处理任务文件 %s（%d 字符）", item.name, len(text))
            item.replace(done / item.name)
            processed += 1
        except OSError as exc:
            log.error("处理 %s 失败：%s", item.name, exc)
    return processed


# --------------------------------------------------------------------------- #
# 主流程
# --------------------------------------------------------------------------- #
def main(argv=None) -> int:
    args = parse_args(argv)

    log_dir = Path(args.log_dir)
    data_dir = Path(args.data_dir)
    inbox, done = data_dir / "inbox", data_dir / "done"
    for directory in (log_dir, data_dir, inbox, done):
        directory.mkdir(parents=True, exist_ok=True)

    setup_logging(log_dir, args.log_level)
    install_stop_handlers()
    status_file = data_dir / "status.json"

    log.info("=" * 64)
    log.info("服务启动 | pid=%s | Python %s", os.getpid(), sys.version.split()[0])
    log.info("解释器=%s", sys.executable)
    log.info("工作目录=%s", os.getcwd())
    log.info("心跳=%.1fs | 日志目录=%s | 数据目录=%s", args.interval, log_dir, data_dir)

    started_at = time.time()
    rounds = 0
    processed_total = 0
    exit_code = EXIT_OK

    try:
        while not stop_event.is_set():
            round_start = time.monotonic()
            rounds += 1

            processed = process_inbox(inbox, done)
            processed_total += processed

            write_status(status_file, {
                "state": "running",
                "pid": os.getpid(),
                "rounds": rounds,
                "interval": args.interval,
                "started_at": datetime.fromtimestamp(started_at).strftime("%Y-%m-%d %H:%M:%S"),
                "last_heartbeat": now_str(),
                "uptime_seconds": round(time.time() - started_at, 1),
                "processed_total": processed_total,
            })
            log.info("第 %d 轮心跳 | 本轮处理 %d 个任务 | 已运行 %.0fs | pid=%d",
                     rounds, processed, time.time() - started_at, os.getpid())

            if args.once:
                log.info("--once 模式：执行一轮后退出")
                break

            # 关键点：用 Event.wait 代替 time.sleep，
            # 收到 Ctrl+C 时能"立刻"醒过来，而不是傻等 interval 秒。
            remaining = args.interval - (time.monotonic() - round_start)
            stop_event.wait(max(0.0, remaining))

    except Exception:  # noqa: BLE001 - 兜底，保证异常时也能返回非 0 退出码
        log.exception("主循环发生未处理异常，服务将以退出码 %d 结束", EXIT_FATAL)
        exit_code = EXIT_FATAL

    # ---------------- 收尾（优雅退出的"真正干活"部分） ----------------
    log.info("进入收尾流程，最多等待 %.1fs……", args.graceful_timeout)
    try:
        # 真实项目里这里放：关闭数据库连接、flush 缓冲、提交事务、
        # 通知上游"我要下线了"、等待线程池任务完成……
        deadline = time.monotonic() + min(1.0, args.graceful_timeout)
        while time.monotonic() < deadline:
            time.sleep(0.05)
        write_status(status_file, {
            "state": "stopped",
            "pid": os.getpid(),
            "rounds": rounds,
            "processed_total": processed_total,
            "started_at": datetime.fromtimestamp(started_at).strftime("%Y-%m-%d %H:%M:%S"),
            "stopped_at": now_str(),
            "uptime_seconds": round(time.time() - started_at, 1),
        })
    except Exception:  # noqa: BLE001
        log.exception("收尾过程出错")
        exit_code = EXIT_FATAL

    log.info("服务已停止 | 共运行 %d 轮 | 存活 %.0fs | 退出码 %d",
             rounds, time.time() - started_at, exit_code)
    logging.shutdown()
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
