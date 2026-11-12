"""HTTP supervisor of the agent image (docs/agent-image.md).

Runs Codex for one agent: the device-code login with the user's ChatGPT
subscription, and one non-interactive task at a time. There is no
authentication: the actor is reachable only through Agent Substrate's
router, which decides who may call it.
"""

import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8080
WORKDIR = os.path.join(os.environ["HOME"], "work")
TASK_TIMEOUT = int(os.environ.get("AGENT_TASK_TIMEOUT", "3600"))
LOGIN_PROMPT_TIMEOUT = 30
TAIL_BYTES = 4000

ANSI = re.compile(r"\x1b\[[0-9;]*m")
URL = re.compile(r"https://\S+")
USER_CODE = re.compile(r"^\s*([A-Z0-9]+-[A-Z0-9]+)\s*$", re.MULTILINE)

task_lock = threading.Lock()
login_lock = threading.Lock()
login = None  # the last `codex login --device-auth`, see start_login


def tail(text):
    return text[-TAIL_BYTES:]


def start_login():
    """Starts a device-code login, or returns the one still running.

    Returns once Codex has printed the verification URL and the user code
    (or has exited); the login then completes in the background when the
    user enters the code.
    """
    global login
    with login_lock:
        if login is not None and login["exit_code"] is None:
            return login
        proc = subprocess.Popen(
            ["codex", "login", "--device-auth"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        state = {
            "url": None,
            "code": None,
            "output": "",
            "exit_code": None,
            "prompted": threading.Event(),
        }

        def follow():
            for line in proc.stdout:
                state["output"] = tail(state["output"] + ANSI.sub("", line))
                if state["url"] is None and (m := URL.search(state["output"])):
                    state["url"] = m.group(0)
                if state["code"] is None and (m := USER_CODE.search(state["output"])):
                    state["code"] = m.group(1)
                if state["url"] and state["code"]:
                    state["prompted"].set()
            state["exit_code"] = proc.wait()
            state["prompted"].set()

        threading.Thread(target=follow, daemon=True).start()
        login = state
    state["prompted"].wait(LOGIN_PROMPT_TIMEOUT)
    return state


def login_status():
    result = subprocess.run(
        ["codex", "login", "status"],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
    )
    return {
        "logged_in": result.returncode == 0,
        "status": (result.stdout + result.stderr).strip(),
        "login_running": login is not None and login["exit_code"] is None,
    }


def run_task(prompt):
    # The actor is the sandbox (gVisor), so Codex runs commands without its
    # own sandbox and never asks for approval.
    with tempfile.TemporaryDirectory() as tmp:
        last = os.path.join(tmp, "last-message.txt")
        proc = subprocess.Popen(
            [
                "codex",
                "exec",
                "--dangerously-bypass-approvals-and-sandbox",
                "--skip-git-repo-check",
                "--color",
                "never",
                "--cd",
                WORKDIR,
                "--output-last-message",
                last,
                "-",  # the prompt from stdin
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        timed_out = False
        try:
            _, stderr = proc.communicate(prompt, timeout=TASK_TIMEOUT)
        except subprocess.TimeoutExpired:
            timed_out = True
            # Codex and every command it started.
            os.killpg(proc.pid, signal.SIGKILL)
            _, stderr = proc.communicate()
        final_message = ""
        if os.path.exists(last):
            with open(last) as f:
                final_message = f.read()
        return {
            "exit_code": proc.returncode,
            "timed_out": timed_out,
            "final_message": final_message,
            "stderr_tail": tail(stderr),
        }


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.reply(200, {"ok": True})
        elif self.path == "/login":
            self.reply(200, login_status())
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/login":
            state = start_login()
            if state["url"] and state["code"]:
                self.reply(
                    200,
                    {"verification_url": state["url"], "user_code": state["code"]},
                )
            else:
                self.reply(
                    502,
                    {
                        "error": "codex printed no verification URL and code",
                        "exit_code": state["exit_code"],
                        "output_tail": state["output"],
                    },
                )
        elif self.path == "/task":
            try:
                length = int(self.headers.get("Content-Length", 0))
                prompt = json.loads(self.rfile.read(length))["prompt"]
                if not isinstance(prompt, str) or not prompt.strip():
                    raise ValueError
            except (ValueError, KeyError, TypeError):
                self.reply(400, {"error": 'expected JSON {"prompt": "..."}'})
                return
            if not task_lock.acquire(blocking=False):
                self.reply(409, {"error": "a task is already running"})
                return
            try:
                self.reply(200, run_task(prompt))
            finally:
                task_lock.release()
        else:
            self.reply(404, {"error": "not found"})

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        log(
            method=self.command,
            path=self.path,
            status=status,
            duration_ms=round((time.monotonic() - self.started) * 1000),
        )

    def parse_request(self):
        self.started = time.monotonic()
        return super().parse_request()

    def log_request(self, code="-", size="-"):
        pass  # reply logs every request

    def log_message(self, format, *args):
        log(error=format % args)  # protocol errors


def log(**fields):
    fields = {"time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), **fields}
    sys.stdout.write(json.dumps(fields) + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    # Both may be on an empty volume mounted at HOME; Codex needs CODEX_HOME
    # to exist.
    os.makedirs(os.environ["CODEX_HOME"], mode=0o700, exist_ok=True)
    os.makedirs(WORKDIR, exist_ok=True)
    server = ThreadingHTTPServer(("", PORT), Handler)
    log(msg="listening", port=PORT, workdir=WORKDIR, task_timeout=TASK_TIMEOUT)
    server.serve_forever()
