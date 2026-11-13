"""HTTP supervisor of the agent image (docs/agent-image.md).

Runs Codex for one agent, one non-interactive task at a time, in one of two
modes chosen by the environment:

- API key: AGENT_OPENAI_API_KEY is set (to a placeholder; Agent Substrate's
  egress gateway replaces it with the real key). The supervisor writes
  CODEX_HOME/config.toml for a model provider at https://api.openai.com/v1
  that sends that variable as the bearer token. No login.
- ChatGPT: otherwise; the device-code login with the user's subscription.

The actor is one agent session: its first task starts a Codex session, every
later task resumes it. There is no authentication: the actor is reachable
only through Agent Substrate's router, which decides who may call it.
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
HOME = os.environ["HOME"]
CODEX_HOME = os.environ["CODEX_HOME"]
WORKDIR = os.path.join(HOME, "work")
SESSION_FILE = os.path.join(HOME, "codex-session")  # the session's id
CONFIG = os.path.join(CODEX_HOME, "config.toml")
API_KEY_ENV = "AGENT_OPENAI_API_KEY"
API_KEY_MODE = bool(os.environ.get(API_KEY_ENV, "").strip())
TASK_TIMEOUT = int(os.environ.get("AGENT_TASK_TIMEOUT", "3600"))
LOGIN_PROMPT_TIMEOUT = 30
TAIL_BYTES = 4000

# The first line marks the file as the supervisor's: ChatGPT mode removes
# only this file, never a config.toml written by anyone else.
CONFIG_MARKER = "# Written by the agent supervisor for API-key mode (docs/agent-image.md).\n"
API_KEY_CONFIG = (
    CONFIG_MARKER
    + f"""model_provider = "openai-api"

[features]
# Fail the task when the API is unreachable instead of retrying until
# AGENT_TASK_TIMEOUT.
unbounded_connection_retries = false

# Not the built-in `openai` provider: that one opens a WebSocket first, which
# Substrate's egress gateway refuses with 403.
[model_providers.openai-api]
name = "OpenAI API"
base_url = "https://api.openai.com/v1"
wire_api = "responses"
env_key = "{API_KEY_ENV}"
supports_websockets = false
"""
)

ANSI = re.compile(r"\x1b\[[0-9;]*m")
URL = re.compile(r"https://\S+")
USER_CODE = re.compile(r"^\s*([A-Z0-9]+-[A-Z0-9]+)\s*$", re.MULTILINE)

task_lock = threading.Lock()
login_lock = threading.Lock()
login = None  # the last `codex login --device-auth`, see start_login


def tail(text):
    return text[-TAIL_BYTES:]


def write_config():
    """Makes config.toml match the mode; touches it only when it differs."""
    current = None
    if os.path.exists(CONFIG):
        with open(CONFIG) as f:
            current = f.read()
    if API_KEY_MODE and current != API_KEY_CONFIG:
        write_atomic(CONFIG, API_KEY_CONFIG)
        log(msg="wrote config", path=CONFIG)
    elif not API_KEY_MODE and current and current.startswith(CONFIG_MARKER):
        os.remove(CONFIG)
        log(msg="removed config of API-key mode", path=CONFIG)


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def load_session():
    if not os.path.exists(SESSION_FILE):
        return None
    with open(SESSION_FILE) as f:
        return f.read().strip() or None


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
    if API_KEY_MODE:
        return {"mode": "api_key", "login_needed": False}
    result = subprocess.run(
        ["codex", "login", "status"],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
    )
    return {
        "mode": "chatgpt",
        "login_needed": result.returncode != 0,
        "logged_in": result.returncode == 0,
        "status": (result.stdout + result.stderr).strip(),
        "login_running": login is not None and login["exit_code"] is None,
    }


def run_task(prompt):
    result = {
        "session": None,
        "error": None,
        "exit_code": None,
        "message": "",
        "final_message": "",
        "stderr_tail": "",
    }
    if not API_KEY_MODE and (status := login_status())["login_needed"]:
        return result | {"error": "needs_login", "message": status["status"]}
    session = result["session"] = load_session()
    with tempfile.TemporaryDirectory() as tmp:
        last = os.path.join(tmp, "last-message.txt")
        # The actor is the sandbox (gVisor), so Codex runs commands without
        # its own sandbox and never asks for approval. The options of `exec`
        # come before `resume`, which takes only the session and the prompt.
        command = [
            "codex",
            "exec",
            "--dangerously-bypass-approvals-and-sandbox",
            "--skip-git-repo-check",
            "--color",
            "never",
            "--cd",
            WORKDIR,
            "--json",
            "--output-last-message",
            last,
        ]
        command += ["resume", session, "-"] if session else ["-"]  # prompt on stdin
        proc = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        timed_out = False
        try:
            stdout, stderr = proc.communicate(prompt, timeout=TASK_TIMEOUT)
        except subprocess.TimeoutExpired:
            timed_out = True
            # Codex and every command it started.
            os.killpg(proc.pid, signal.SIGKILL)
            stdout, stderr = proc.communicate()
        if os.path.exists(last):
            with open(last) as f:
                result["final_message"] = f.read()
    # JSON Lines events: `thread.started` names the session, `error` and
    # `turn.failed` say why a turn failed.
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("type") == "thread.started":
            result["session"] = event.get("thread_id")
        elif event.get("type") == "turn.failed":
            result["message"] = event.get("error", {}).get("message", "")
    result["exit_code"] = proc.returncode
    result["stderr_tail"] = tail(stderr)
    if not session and result["session"]:
        # Codex records the session as soon as it starts, so after a failed
        # first task the next one continues it, with whatever it did.
        write_atomic(SESSION_FILE, result["session"] + "\n")
    if timed_out:
        result["error"] = "timeout"
    elif proc.returncode != 0:
        result["error"] = "codex_failed"
        result["message"] = result["message"] or tail(stderr).strip()
    return result


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
            if API_KEY_MODE:
                self.reply(
                    409,
                    login_status() | {"error": "API-key mode: no login needed"},
                )
                return
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
            **{k: body[k] for k in ("session", "error") if k in body},
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
    os.makedirs(CODEX_HOME, mode=0o700, exist_ok=True)
    os.makedirs(WORKDIR, exist_ok=True)
    write_config()
    server = ThreadingHTTPServer(("", PORT), Handler)
    log(
        msg="listening",
        port=PORT,
        mode="api_key" if API_KEY_MODE else "chatgpt",
        workdir=WORKDIR,
        task_timeout=TASK_TIMEOUT,
    )
    server.serve_forever()
