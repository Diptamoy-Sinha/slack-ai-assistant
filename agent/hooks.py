"""Hook provider that logs every model call and tool call an agent makes.

Attach the same ``AGENT_CALL_LOGGER`` instance to the orchestrator *and* every
sub-agent (``Agent(hooks=[AGENT_CALL_LOGGER])``) so calls at any level of the
agents-as-tools tree get a matching before/after log line tagged with the
emitting agent's ``agent_id`` — e.g. ``orchestrator`` calling the ``release``
tool, which internally calls its own model and ``search_wiki`` tool.

https://strandsagents.com/docs/user-guide/concepts/agents/hooks/
"""

from __future__ import annotations

import logging
import time
from typing import Any

from strands.hooks import (
    AfterModelCallEvent,
    AfterToolCallEvent,
    BeforeModelCallEvent,
    BeforeToolCallEvent,
    HookProvider,
    HookRegistry,
)

logger = logging.getLogger("agent.hooks")

_MAX_LOGGED_INPUT_CHARS = 300


def _truncate(value: Any) -> str:
    text = str(value)
    if len(text) <= _MAX_LOGGED_INPUT_CHARS:
        return text
    return text[:_MAX_LOGGED_INPUT_CHARS] + "…"


def _fmt_ms(elapsed_s: float | None) -> str:
    return f"{elapsed_s * 1000:.1f}" if elapsed_s is not None else "unknown"


class AgentCallLogger(HookProvider):
    """Logs the start/end of every model call and tool call, per agent.

    Model calls are keyed by ``id(agent)`` (an agent only runs one model call
    at a time). Tool calls are keyed by ``tool_use["toolUseId"]`` since a
    single agent round can dispatch several tool calls concurrently.
    """

    def __init__(self) -> None:
        self._model_call_started_at: dict[int, float] = {}
        self._tool_call_started_at: dict[str, float] = {}

    def register_hooks(self, registry: HookRegistry, **kwargs: Any) -> None:
        registry.add_callback(BeforeModelCallEvent, self._before_model_call)
        registry.add_callback(AfterModelCallEvent, self._after_model_call)
        registry.add_callback(BeforeToolCallEvent, self._before_tool_call)
        registry.add_callback(AfterToolCallEvent, self._after_tool_call)

    def _before_model_call(self, event: BeforeModelCallEvent) -> None:
        self._model_call_started_at[id(event.agent)] = time.perf_counter()
        logger.info("model_call.start agent=%s", event.agent.agent_id)

    def _after_model_call(self, event: AfterModelCallEvent) -> None:
        started_at = self._model_call_started_at.pop(id(event.agent), None)
        elapsed = time.perf_counter() - started_at if started_at is not None else None

        if event.exception is not None:
            logger.warning(
                "model_call.error agent=%s duration_ms=%s error=%s",
                event.agent.agent_id,
                _fmt_ms(elapsed),
                event.exception,
            )
            return

        usage = event.agent.event_loop_metrics.accumulated_usage
        stop_reason = event.stop_response.stop_reason if event.stop_response else None
        logger.info(
            "model_call.end agent=%s duration_ms=%s stop_reason=%s "
            "input_tokens=%s output_tokens=%s",
            event.agent.agent_id,
            _fmt_ms(elapsed),
            stop_reason,
            usage.get("inputTokens"),
            usage.get("outputTokens"),
        )

    def _before_tool_call(self, event: BeforeToolCallEvent) -> None:
        self._tool_call_started_at[event.tool_use["toolUseId"]] = time.perf_counter()
        logger.info(
            "tool_call.start agent=%s tool=%s input=%s",
            event.agent.agent_id,
            event.tool_use["name"],
            _truncate(event.tool_use.get("input")),
        )

    def _after_tool_call(self, event: AfterToolCallEvent) -> None:
        started_at = self._tool_call_started_at.pop(event.tool_use["toolUseId"], None)
        elapsed = time.perf_counter() - started_at if started_at is not None else None

        if event.exception is not None:
            logger.warning(
                "tool_call.error agent=%s tool=%s duration_ms=%s error=%s",
                event.agent.agent_id,
                event.tool_use["name"],
                _fmt_ms(elapsed),
                event.exception,
            )
            return

        logger.info(
            "tool_call.end agent=%s tool=%s status=%s duration_ms=%s result=%s",
            event.agent.agent_id,
            event.tool_use["name"],
            event.result.get("status"),
            _fmt_ms(elapsed),
            _truncate(event.result.get("content")),
        )


AGENT_CALL_LOGGER = AgentCallLogger()
