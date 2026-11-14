"""Supervisor of the agent image: Codex behind A2A 1.0 (docs/agent-image.md).

One actor is one agent session. The first message starts a Codex session,
every later message resumes it, one task at a time; the actor serves only the
contextId of its first message. Codex reaches the OpenAI API with
AGENT_OPENAI_API_KEY, a placeholder that Agent Substrate's egress gateway
replaces with the real key (ADR 0030): the actor never holds it.

There is no authentication: the actor is reachable only through Agent
Substrate's router, which decides who may call it. Tasks are kept in memory:
the caller (the dispatcher) holds the canonical record, and the actor's
snapshot keeps the Codex session.
"""

import asyncio
import contextlib
import json
import os
import signal
import subprocess
import sys
import tempfile
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
CONFIG_FILE = os.path.join(CODEX_HOME, "config.toml")
API_KEY_ENV = "AGENT_OPENAI_API_KEY"
TASK_TIMEOUT = int(os.environ.get("AGENT_TASK_TIMEOUT", "3600"))
TAIL_BYTES = 4000
# One --json event per line; a command's output can make one long.
EVENT_LINE_LIMIT = 64 * 1024 * 1024

# Codex's configuration, owned by the supervisor: written at every start.
CONFIG = f"""# Written by the agent supervisor at every start (docs/agent-image.md).
model_provider = "openai-api"

[features]
# Fail a turn after Codex's 5 retries when the API is unreachable, instead
# of retrying until AGENT_TASK_TIMEOUT.
unbounded_connection_retries = false

# Not the built-in `openai` provider: that one opens a WebSocket first, which
# Substrate's egress gateway refuses with 403. This one uses HTTPS only and
# sends ${API_KEY_ENV} as `Authorization: Bearer`.
[model_providers.openai-api]
name = "OpenAI API"
base_url = "https://api.openai.com/v1"
wire_api = "responses"
env_key = "{API_KEY_ENV}"
supports_websockets = false
"""


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


def write_file(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def write_record(path, value):
    write_file(path, value + "\n")


def write_config():
    """Writes Codex's configuration, unless it is already the supervisor's."""
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE) as f:
            if f.read() == CONFIG:
                return
    write_file(CONFIG_FILE, CONFIG)
    log(msg="wrote config", path=CONFIG_FILE)


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

        # The first event is the task itself. A message can name only a
        # new task: the SDK rejects one for an ended task, and the handler
        # one while a task runs.
        state = TaskState.TASK_STATE_WORKING
        await event_queue.enqueue_event(
            Task(
                id=task_id,
                context_id=context_id,
                status=TaskStatus(state=state),
                history=[context.message],
            )
        )
        log(msg="task", task=task_id, context=context_id, state=TaskState.Name(state))

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

    routes = [
        Route(AGENT_CARD_WELL_KNOWN_PATH, serve_card, methods=["GET"]),
        Route("/healthz", healthz, methods=["GET"]),
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
    if not os.environ.get(API_KEY_ENV, "").strip():
        # Codex would fail every task with a missing-key error; say so once.
        log(
            msg=f"{API_KEY_ENV} is not set: set it to a placeholder the egress "
            "gateway replaces with the OpenAI API key (docs/agent-image.md)",
            error="no_api_key",
        )
        sys.exit(1)
    # Both may be on an empty volume mounted at HOME; Codex needs CODEX_HOME
    # to exist.
    os.makedirs(CODEX_HOME, mode=0o700, exist_ok=True)
    os.makedirs(WORKDIR, exist_ok=True)
    write_config()
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
