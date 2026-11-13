"""Supervisor of the agent image: Codex behind A2A 1.0 (docs/agent-image.md).

One actor is one agent session. The first message starts a Codex session,
every later message resumes it, one task at a time; the actor serves only the
contextId of its first message. Codex reaches the model with the user's
ChatGPT subscription, logged in once per actor through `POST /login` (device
code), outside A2A.

There is no authentication: the actor is reachable only through Agent
Substrate's router, which decides who may call it. Tasks are kept in memory:
the caller (the dispatcher) holds the canonical record, and the actor's
snapshot keeps the Codex session.
"""

import asyncio
import contextlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time

import uvicorn
from a2a.server.agent_execution import AgentExecutor
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.request_handlers.response_helpers import agent_card_to_dict
from a2a.server.routes import create_jsonrpc_routes
from a2a.server.tasks import InMemoryTaskStore, TaskUpdater
from a2a.types import (
    AgentCapabilities,
    AgentCard,
    AgentInterface,
    AgentSkill,
    InvalidParamsError,
    Part,
    Task,
    TaskNotFoundError,
    TaskState,
    TaskStatus,
    UnsupportedOperationError,
)
from a2a.utils.constants import AGENT_CARD_WELL_KNOWN_PATH
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Route

PORT = 8080
HOME = os.environ["HOME"]
CODEX_HOME = os.environ["CODEX_HOME"]
WORKDIR = os.path.join(HOME, "work")
SESSION_FILE = os.path.join(HOME, "codex-session")  # Codex's session id
CONTEXT_FILE = os.path.join(HOME, "a2a-context")  # the contextId served
TASK_TIMEOUT = int(os.environ.get("AGENT_TASK_TIMEOUT", "3600"))
LOGIN_PROMPT_TIMEOUT = 30
TAIL_BYTES = 4000
# One --json event per line; a command's output can make one long.
EVENT_LINE_LIMIT = 64 * 1024 * 1024

ANSI = re.compile(r"\x1b\[[0-9;]*m")
URL = re.compile(r"https://\S+")
USER_CODE = re.compile(r"^\s*([A-Z0-9]+-[A-Z0-9]+)\s*$", re.MULTILINE)

login_lock = threading.Lock()
login = None  # the last `codex login --device-auth`, see start_login


def tail(text):
    return text[-TAIL_BYTES:]


def log(**fields):
    fields = {"time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), **fields}
    sys.stdout.write(json.dumps(fields) + "\n")
    sys.stdout.flush()


def read_record(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return f.read().strip() or None


def write_record(path, value):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(value + "\n")
    os.replace(tmp, path)


# Login: the device-code flow with the user's ChatGPT subscription, an
# operator action outside A2A.


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


# Codex: one session per actor.


async def run_codex(prompt):
    """Runs one turn: starts the actor's Codex session or resumes it.

    Returns {"session", "error", "message", "final_message"}; error is None,
    "timeout" (killed after AGENT_TASK_TIMEOUT) or "codex_failed" (Codex
    exited nonzero), message says why.
    """
    result = {"session": None, "error": None, "message": "", "final_message": ""}
    session = result["session"] = read_record(SESSION_FILE)
    with tempfile.TemporaryDirectory() as tmp:
        last = os.path.join(tmp, "last-message.txt")
        # The actor is the sandbox (gVisor), so Codex runs commands without
        # its own sandbox and never asks for approval. By default Codex
        # retries an unreachable backend until it is killed; without the
        # feature a turn fails after its 5 retries. The options of `exec`
        # come before `resume`, which takes only the session and the prompt.
        command = [
            "codex",
            "exec",
            "--dangerously-bypass-approvals-and-sandbox",
            "--skip-git-repo-check",
            "--disable",
            "unbounded_connection_retries",
            "--color",
            "never",
            "--cd",
            WORKDIR,
            "--json",
            "--output-last-message",
            last,
        ]
        command += ["resume", session, "-"] if session else ["-"]  # prompt on stdin
        proc = await asyncio.create_subprocess_exec(
            *command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
            limit=EVENT_LINE_LIMIT,
        )
        stderr = b""

        async def feed():
            try:
                proc.stdin.write(prompt.encode())
                await proc.stdin.drain()
                proc.stdin.close()
            except (BrokenPipeError, ConnectionResetError):
                pass  # Codex exited early; its exit status says why

        async def drain_stderr():
            nonlocal stderr
            while chunk := await proc.stderr.read(65536):
                stderr = stderr[-TAIL_BYTES:] + chunk

        async def follow():
            # JSON Lines events, read as they come: `thread.started` names
            # the session and is recorded at once, so a first turn that is
            # killed (timeout, cancel, a restart of the actor) still leaves
            # the session for the next message; `turn.failed` says why a
            # turn failed.
            while line := await proc.stdout.readline():
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if event.get("type") == "thread.started":
                    result["session"] = event.get("thread_id")
                    if not session and result["session"]:
                        write_record(SESSION_FILE, result["session"])
                elif event.get("type") == "turn.failed":
                    result["message"] = event.get("error", {}).get("message", "")
            await proc.wait()

        timed_out = False
        try:
            await asyncio.wait_for(
                asyncio.gather(feed(), drain_stderr(), follow()), TASK_TIMEOUT
            )
        except TimeoutError:
            timed_out = True
        finally:
            if proc.returncode is None:
                # Codex and every command it started.
                os.killpg(proc.pid, signal.SIGKILL)
                await proc.wait()
        if os.path.exists(last):
            with open(last) as f:
                result["final_message"] = f.read()
    stderr = stderr.decode(errors="replace")
    if timed_out:
        result["error"] = "timeout"
        result["message"] = f"killed after AGENT_TASK_TIMEOUT={TASK_TIMEOUT}s"
    elif proc.returncode != 0:
        result["error"] = "codex_failed"
        result["message"] = result["message"] or tail(stderr).strip()
    return result


# A2A


class CodexExecutor(AgentExecutor):
    def __init__(self):
        self.running = None  # the id of the task Codex works on

    async def execute(self, context, event_queue):
        self.running = context.task_id
        try:
            await self.run(context, event_queue)
        finally:
            self.running = None

    async def run(self, context, event_queue):
        task_id, context_id = context.task_id, context.context_id
        if read_record(CONTEXT_FILE) is None:
            write_record(CONTEXT_FILE, context_id)
        updater = TaskUpdater(event_queue, task_id, context_id)

        def agent_message(text, error=None):
            return updater.new_agent_message(
                [Part(text=text)], metadata={"error": error} if error else None
            )

        status = await asyncio.to_thread(login_status)
        state = TaskState.TASK_STATE_WORKING
        message = None
        if not status["logged_in"]:
            state = TaskState.TASK_STATE_AUTH_REQUIRED
            message = agent_message(
                f"Codex is not logged in to ChatGPT ({status['status']}). "
                "An operator logs the agent in (POST /login, docs/agent-image.md); "
                "then send the message again.",
                "needs_login",
            )
        if context.current_task is None:
            # A new task: the first event is the task itself.
            await event_queue.enqueue_event(
                Task(
                    id=task_id,
                    context_id=context_id,
                    status=TaskStatus(state=state, message=message),
                    history=[context.message],
                )
            )
        else:
            # A further message to a task waiting for the login.
            await updater.update_status(state, message=message)
        log(msg="task", task=task_id, context=context_id, state=TaskState.Name(state))
        if state == TaskState.TASK_STATE_AUTH_REQUIRED:
            return

        result = await run_codex(context.get_user_input())
        log(
            msg="turn",
            task=task_id,
            session=result["session"],
            error=result["error"],
            message=result["message"],
        )
        if result["error"]:
            await updater.failed(
                agent_message(f"{result['error']}: {result['message']}", result["error"])
            )
            return
        await updater.add_artifact([Part(text=result["final_message"])], name="response")
        await updater.complete()

    async def cancel(self, context, event_queue):
        # The framework then cancels execute(), which kills Codex.
        await TaskUpdater(event_queue, context.task_id, context.context_id).cancel()


class RequestHandler(DefaultRequestHandler):
    """Admits a message only for the actor's context and while it is idle."""

    def __init__(self, executor, **kwargs):
        super().__init__(agent_executor=executor, **kwargs)
        self.executor = executor
        self.admitting = False  # between admission and the start of execute()

    async def on_message_send(self, params, context):
        if self.admitting or self.executor.running:
            raise UnsupportedOperationError(
                message=f"the agent is working on task {self.executor.running}; "
                "it takes one task at a time"
            )
        message = params.message
        if message.task_id and not message.context_id:
            # A follow-up may name only its task; A2A infers the context from
            # it, which the SDK's handler does not (it would generate one).
            task = await self.task_store.get(message.task_id, context)
            if task is None:
                raise TaskNotFoundError(message=f"task {message.task_id} not found")
            message.context_id = task.context_id
        served = read_record(CONTEXT_FILE)
        if served and message.context_id != served:
            raise InvalidParamsError(
                message=f"this agent serves context {served} only (one actor is one session)"
            )
        if not any(part.HasField("text") for part in params.message.parts):
            raise InvalidParamsError(message="the message has no text part")
        self.admitting = True
        try:
            return await super().on_message_send(params, context)
        finally:
            self.admitting = False


def agent_card(version):
    return AgentCard(
        name="Codex agent",
        description="Codex in its own sandbox: one session, its files and commands kept across messages.",
        version=version,
        capabilities=AgentCapabilities(streaming=False, push_notifications=False),
        default_input_modes=["text/plain"],
        default_output_modes=["text/plain"],
        skills=[
            AgentSkill(
                id="codex",
                name="Codex",
                description="Works on a task with Codex: reads, writes and runs code in the actor.",
                tags=["coding"],
            )
        ],
        # The URL is the one the card was fetched from, see serve_card.
        supported_interfaces=[
            AgentInterface(
                protocol_binding="JSONRPC",
                protocol_version="1.0",
                url=f"http://localhost:{PORT}/",
            )
        ],
    )


def app(card):
    executor = CodexExecutor()
    handler = RequestHandler(executor, task_store=InMemoryTaskStore(), agent_card=card)

    async def serve_card(request):
        # Through `kubectl ate proxy` or Substrate's router the actor's
        # address is the client's, so the card names the URL it was fetched
        # from.
        served = AgentCard()
        served.CopyFrom(card)
        served.supported_interfaces[0].url = str(request.base_url)
        return JSONResponse(agent_card_to_dict(served))

    async def healthz(request):
        return JSONResponse({"ok": True})

    async def get_login(request):
        return JSONResponse(await asyncio.to_thread(login_status))

    async def post_login(request):
        state = await asyncio.to_thread(start_login)
        if state["url"] and state["code"]:
            return JSONResponse({"verification_url": state["url"], "user_code": state["code"]})
        return JSONResponse(
            {
                "error": "codex printed no verification URL and code",
                "exit_code": state["exit_code"],
                "output_tail": state["output"],
            },
            status_code=502,
        )

    routes = [
        Route(AGENT_CARD_WELL_KNOWN_PATH, serve_card, methods=["GET"]),
        Route("/healthz", healthz, methods=["GET"]),
        Route("/login", get_login, methods=["GET"]),
        Route("/login", post_login, methods=["POST"]),
        *create_jsonrpc_routes(handler, rpc_url="/"),
    ]

    @contextlib.asynccontextmanager
    async def lifespan(app):
        yield
        await handler.aclose()

    return Starlette(routes=routes, lifespan=lifespan)


class RequestLog:
    """Logs every request as one JSON line."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        started = time.monotonic()
        status = None

        async def send_logged(message):
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
            await send(message)

        try:
            await self.app(scope, receive, send_logged)
        finally:
            log(
                method=scope["method"],
                path=scope["path"],
                status=status,
                duration_ms=round((time.monotonic() - started) * 1000),
            )


if __name__ == "__main__":
    # Both may be on an empty volume mounted at HOME; Codex needs CODEX_HOME
    # to exist.
    os.makedirs(CODEX_HOME, mode=0o700, exist_ok=True)
    os.makedirs(WORKDIR, exist_ok=True)
    version = subprocess.run(
        ["codex", "--version"], capture_output=True, text=True, check=True
    ).stdout.split()[-1]
    log(
        msg="listening",
        port=PORT,
        codex=version,
        context=read_record(CONTEXT_FILE),
        session=read_record(SESSION_FILE),
        task_timeout=TASK_TIMEOUT,
    )
    uvicorn.run(
        RequestLog(app(agent_card(version))),
        host="0.0.0.0",
        port=PORT,
        log_config=None,
        access_log=False,
    )
