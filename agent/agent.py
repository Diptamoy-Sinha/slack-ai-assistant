import time
from datetime import datetime, timezone
from functools import lru_cache

from strands import Agent, tool
from tavily import TavilyClient

from agent.hooks import AGENT_CALL_LOGGER
from agent.model import openai_model
from agent.session_manager import build_session_manager
from app_config import get_config


@lru_cache(maxsize=1)
def _tavily_client() -> TavilyClient:
    api_key = get_config().tavily_api_key
    if not api_key:
        raise RuntimeError("TAVILY_API_KEY is required for web_search")
    return TavilyClient(api_key=api_key)


def _is_transient_network_error(exc: BaseException) -> bool:
    if isinstance(exc, (ConnectionError, ConnectionResetError, TimeoutError, OSError)):
        return True
    message = str(exc).lower()
    return "connection" in message and ("reset" in message or "aborted" in message)


@tool
def web_search(query: str) -> str:
    """Search the web for information about the given query."""
    for attempt in range(3):
        try:
            return _tavily_client().search(query)
        except BaseException as exc:
            if not _is_transient_network_error(exc) or attempt == 2:
                raise
            time.sleep(0.5 * (2**attempt))
    raise RuntimeError("web_search failed without an error")


@tool
def get_time(tz_name: str = "UTC") -> str:
    """Return the current time as an ISO-8601 string.

    Args:
        tz_name: IANA timezone name (e.g. "America/Los_Angeles"). Defaults to UTC.

    Returns:
        Current time formatted as "YYYY-MM-DDTHH:MM:SS+HH:MM".
    """
    if tz_name.upper() == "UTC":
        return datetime.now(timezone.utc).isoformat(timespec="seconds")

    from zoneinfo import ZoneInfo

    return datetime.now(ZoneInfo(tz_name)).isoformat(timespec="seconds")


SYSTEM_PROMPT = """
You are a helpful assistant that can search the web for information and get the current time.
"""


def build_agent(
    user_id: str,
    session_id: str,
    extra_hooks: list | None = None,
) -> Agent:
    session_manager = build_session_manager(user_id, session_id)
    hooks = [AGENT_CALL_LOGGER]
    if extra_hooks:
        hooks.extend(extra_hooks)

    return Agent(
        model=openai_model,
        tools=[web_search, get_time],
        system_prompt=SYSTEM_PROMPT,
        session_manager=session_manager,
        hooks=hooks,
        trace_attributes={
            "session.id": session_id,
            "user.id": user_id,
        },
    )
