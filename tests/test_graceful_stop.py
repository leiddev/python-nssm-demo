# -*- coding: utf-8 -*-
"""验证 service_demo.py 能不能被"优雅停止"——不需要管理员权限。

原理
----
NSSM 停止服务时，第一步就是给子进程发 Ctrl+C(SIGINT)，超时才强杀。
这个测试用 CTRL_BREAK_EVENT(SIGBREAK) 来触发，因为脚本里两个信号
绑的是同一个处理函数，走的是完全相同的退出路径；
而 CTRL_BREAK_EVENT 可以只发给子进程所在的进程组，不会误伤测试进程本身。

用法：
    python tests\\test_graceful_stop.py
"""
import json
import signal
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "service_demo.py"
TMP = Path(__file__).resolve().parent / "_tmp"

failures = []


def check(condition, message):
    marker = "PASS" if condition else "FAIL"
    print("  [{}] {}".format(marker, message))
    if not condition:
        failures.append(message)


def reset_tmp():
    import shutil
    if TMP.exists():
        shutil.rmtree(TMP)
    (TMP / "logs").mkdir(parents=True)


def read_log():
    path = TMP / "logs" / "service.log"
    return path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""


def test_once():
    """--once 跑一轮就退出，退出码必须是 0。"""
    print("\n[1] --once 自检")
    reset_tmp()
    proc = subprocess.run(
        [sys.executable, "-u", str(SCRIPT), "--once",
         "--log-dir", str(TMP / "logs"), "--data-dir", str(TMP / "data")],
        capture_output=True, text=True, timeout=60,
    )
    check(proc.returncode == 0, "退出码为 0（实际 {}）".format(proc.returncode))
    check("服务已停止" in read_log(), "日志里有收尾记录")
    status = TMP / "data" / "status.json"
    check(status.exists(), "生成了 status.json")
    if status.exists():
        check(json.loads(status.read_text(encoding="utf-8"))["state"] == "stopped",
              "status.json 状态为 stopped")


def test_graceful_stop():
    """常驻运行，收到停止信号后必须自己走完收尾流程并返回 0。"""
    print("\n[2] 常驻运行 + 优雅停止")
    reset_tmp()
    log_dir, data_dir = TMP / "logs", TMP / "data"

    proc = subprocess.Popen(
        [sys.executable, "-u", str(SCRIPT), "--interval", "1",
         "--log-dir", str(log_dir), "--data-dir", str(data_dir)],
        creationflags=subprocess.CREATE_NEW_PROCESS_GROUP,
    )
    try:
        time.sleep(4)  # 让它跑几轮
        check(proc.poll() is None, "4 秒后进程仍在运行")

        status_file = data_dir / "status.json"
        rounds_before = 0
        if status_file.exists():
            payload = json.loads(status_file.read_text(encoding="utf-8"))
            rounds_before = payload.get("rounds", 0)
            check(payload.get("state") == "running", "status.json 状态为 running")
        check(rounds_before >= 3, "已完成 {} 轮心跳（>=3）".format(rounds_before))

        # 丢一个任务文件进去，验证业务逻辑真的在跑
        inbox = data_dir / "inbox"
        inbox.mkdir(parents=True, exist_ok=True)
        (inbox / "job1.txt").write_text("hello", encoding="utf-8")
        time.sleep(2.5)
        check((data_dir / "done" / "job1.txt").exists(), "inbox 里的任务被处理并移走")

        # 发停止信号（NSSM 发的是 Ctrl+C，同一处理函数）
        print("  --> 发送 CTRL_BREAK_EVENT")
        proc.send_signal(signal.CTRL_BREAK_EVENT)
        try:
            code = proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
            code = None
        check(code == 0, "优雅退出，退出码为 0（实际 {}）".format(code))

        log_text = read_log()
        check("收到停止信号" in log_text, "日志记录了停止信号")
        check("进入收尾流程" in log_text, "执行了收尾流程")

        payload = json.loads((data_dir / "status.json").read_text(encoding="utf-8"))
        check(payload.get("state") == "stopped", "status.json 被更新为 stopped")
    finally:
        if proc.poll() is None:
            proc.kill()


if __name__ == "__main__":
    print("测试 service_demo.py 的优雅停止（python {}）".format(sys.version.split()[0]))
    test_once()
    test_graceful_stop()
    print("\n" + "=" * 40)
    if failures:
        print("失败 {} 项：".format(len(failures)))
        for item in failures:
            print("  - " + item)
        sys.exit(1)
    print("全部通过")
