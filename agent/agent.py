import time
from datetime import datetime, timezone
from functools import lru_cache

from strands import Agent, tool
from tavily import TavilyClient

from agent.hooks import AGENT_CALL_LOGGER
from agent.model import openai_model
from agent.session_manager import build_session_manager
from agent.tools.dynamodb import dynamodb_tools
from agent.tools.wiki import WikiTool, wiki_tools
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


@lru_cache(maxsize=1)
def _wiki() -> WikiTool:
    """One WikiTool for the process, so its slug index is built once."""
    return wiki_tools()


def _agent_tools() -> list:
    tools = [web_search, get_time, *_wiki().tools()]
    ddb = dynamodb_tools()
    if ddb is not None:
        tools.extend(ddb.tools())
    return tools


SYSTEM_PROMPT = """
You are a helpful assistant. You can answer from a curated knowledge base, search
the web, and get the current time.

## The water-knowledge wiki

You have a wiki compiled from a digital collection on water quality, testing and
analysis — with distillation and filtration, water-power, water hardness and
softening, and magnesium extraction from seawater as adjacent subjects. It is
built from three primary sources: Jane Marcet's Conversations on Chemistry
(COC-1809), a W. J. Bush & Co. trade manual on aerated mineral waters
(BUSH-1897), and a USDA civil-defence pamphlet on family food stockpiles
(FFS-1961).

For any question about these subjects, the wiki is your source — not the web and
not your own background knowledge:

- The wiki's index is included below — its table of contents and intent map. Use
  it to pick the entry-point page, or search_wiki when the index is not specific
  enough. Follow the [[wikilinks]] you find; read_wiki_page and read_wiki_pages
  take a bare slug, so "[[filtration]]" and "topics/filtration.md" both work. Use
  read_wiki_pages when you already know you need more than one page.
- Carry the citations through. Wiki claims are cited as [KEY p.PRINTED (scan N)];
  quote that citation with the claim so the answer stays auditable.
- These sources span 152 years and disagree with each other. When they do, say
  who says what and when, rather than flattening it into one answer. The wiki's
  contradictions.md page tracks known conflicts and OCR artefacts.
- Do not treat 1809, 1897 or 1961 claims as current guidance. They are historical
  evidence; flag them as such when a user might act on them.
- If the wiki does not cover something, say so plainly. Do not fill the gap with
  web results dressed up as wiki content — if you do use web_search there, label
  which parts came from the web.

## DynamoDB (Todo)

When a user asks about a specific todo item, use get_dynamodb_item. The Todo
table lives in a cross-account DynamoDB database; pass table_name ``Todo`` and
the todo id (e.g. ``todo-001``). The tool looks up by partition key ``id`` even
though the table also has a sort key. If no item is found, say so plainly.
"""


def _system_prompt() -> str:
    """SYSTEM_PROMPT plus the wiki's index, read fresh on every agent build.

    build_agent runs once per user message, so an index.md edited on EFS reaches
    the next message without redeploying or restarting the task.
    """
    index = _wiki().load_index()
    if index.startswith("(index.md not found)"):
        return (
            SYSTEM_PROMPT + "\n## Wiki index\n\n"
            "The index could not be read. Use search_wiki to find pages before "
            "answering from the wiki.\n"
        )
    return (
        SYSTEM_PROMPT + "\n## Wiki index\n\n"
        "The wiki's index.md as of this message:\n\n" + index
    )


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
        tools=_agent_tools(),
        system_prompt=_system_prompt(),
        session_manager=session_manager,
        hooks=hooks,
        trace_attributes={
            "session.id": session_id,
            "user.id": user_id,
        },
    )
