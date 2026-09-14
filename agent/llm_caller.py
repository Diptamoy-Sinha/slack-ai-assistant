import asyncio
import threading
from collections import defaultdict
from typing import Any

from slack_sdk.models.messages.chunk import TaskUpdateChunk
from slack_sdk.web.chat_stream import ChatStream
from strands.hooks import (
    AfterToolCallEvent,
    BeforeToolCallEvent,
    HookProvider,
    HookRegistry,
)

from agent.agent import build_agent

_session_locks: dict[tuple[str, str], threading.Lock] = defaultdict(threading.Lock)
_event_loop: asyncio.AbstractEventLoop | None = None
_event_loop_ready = threading.Event()


def _background_event_loop() -> None:
    global _event_loop
    _event_loop = asyncio.new_event_loop()
    asyncio.set_event_loop(_event_loop)
    _event_loop_ready.set()
    _event_loop.run_forever()


def _get_event_loop() -> asyncio.AbstractEventLoop:
    global _event_loop
    if _event_loop is None:
        threading.Thread(
            target=_background_event_loop,
            name="agent-event-loop",
            daemon=True,
        ).start()
        _event_loop_ready.wait()
    return _event_loop  # type: ignore[return-value]


def _run_on_event_loop(coro: Any) -> None:
    future = asyncio.run_coroutine_threadsafe(coro, _get_event_loop())
    future.result()


class SlackToolStatusHook(HookProvider):
    """Mirror Strands tool calls as Slack task update chunks."""

    def __init__(self, streamer: ChatStream) -> None:
        self._streamer = streamer

    def register_hooks(self, registry: HookRegistry, **kwargs: Any) -> None:
        registry.add_callback(BeforeToolCallEvent, self._before_tool_call)
        registry.add_callback(AfterToolCallEvent, self._after_tool_call)

    def _before_tool_call(self, event: BeforeToolCallEvent) -> None:
        tool_use = event.tool_use
        self._streamer.append(
            chunks=[
                TaskUpdateChunk(
                    id=tool_use["toolUseId"],
                    title=f"Running {tool_use['name']}...",
                    status="in_progress",
                ),
            ],
        )

    def _after_tool_call(self, event: AfterToolCallEvent) -> None:
        tool_use = event.tool_use
        if event.exception is not None:
            self._streamer.append(
                chunks=[
                    TaskUpdateChunk(
                        id=tool_use["toolUseId"],
                        title=str(event.exception),
                        status="error",
                    ),
                ],
            )
            return

        result = event.result
        status = result.get("status", "success")
        title = _tool_result_title(
            tool_use["name"],
            tool_use.get("input", {}),
            result.get("content", []),
            status,
        )
        self._streamer.append(
            chunks=[
                TaskUpdateChunk(
                    id=tool_use["toolUseId"],
                    title=title,
                    status="complete" if status == "success" else "error",
                ),
            ],
        )


def _tool_result_title(
    tool_name: str,
    tool_input: dict[str, Any],
    content: list,
    status: str,
) -> str:
    if status != "success":
        return f"{tool_name} failed"

    if tool_name == "web_search":
        query = tool_input.get("query")
        if isinstance(query, str) and query:
            if len(query) <= 100:
                return f"Searched: {query}"
            return f"Searched: {query[:97]}..."

    for block in content:
        if isinstance(block, dict) and isinstance(block.get("text"), str):
            text = block["text"]
            if len(text) <= 120:
                return text
            return text[:117] + "..."

    return f"{tool_name} complete"


async def _stream_agent(
    streamer: ChatStream,
    user_id: str,
    session_id: str,
    message: str,
) -> None:
    slack_hook = SlackToolStatusHook(streamer)
    agent = build_agent(user_id, session_id, extra_hooks=[slack_hook])

    async for event in agent.stream_async(message):
        text = event.get("data")
        if isinstance(text, str):
            streamer.append(markdown_text=text)


def call_llm(
    streamer: ChatStream,
    user_id: str,
    session_id: str,
    message: str,
) -> None:
    """Stream a Strands agent response into a Slack conversation."""
    session_key = (user_id, session_id)
    with _session_locks[session_key]:
        _run_on_event_loop(_stream_agent(streamer, user_id, session_id, message))
