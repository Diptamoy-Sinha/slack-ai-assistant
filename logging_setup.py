import logging
import os
import sys
from pathlib import Path

HOOK_LOGGER_NAME = "agent.hooks"

# Keep third-party libraries quiet; hook logs stay visible at INFO.
_QUIET_LOGGERS = (
    "slack_sdk",
    "slack_bolt",
    "strands",
    "httpx",
    "httpcore",
    "httpcore2",
    "openai",
    "urllib3",
    "botocore",
    "boto3",
    "asyncio",
)


def setup_logging() -> None:
    log_level = os.getenv("LOG_LEVEL", "INFO").upper()
    root_level = getattr(logging, log_level, logging.INFO)

    formatter = logging.Formatter(
        "%(asctime)s %(levelname)s %(name)s — %(message)s",
        datefmt="%H:%M:%S",
    )

    console = logging.StreamHandler(sys.stdout)
    console.setFormatter(formatter)

    handlers: list[logging.Handler] = [console]

    log_file = os.getenv("AGENT_LOG_FILE", "logs/agent.log")
    if log_file:
        log_path = Path(log_file)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        file_handler = logging.FileHandler(log_path, encoding="utf-8")
        file_handler.setFormatter(formatter)
        file_handler.setLevel(logging.INFO)
        handlers.append(file_handler)

    logging.basicConfig(level=root_level, handlers=handlers, force=True)

    logging.getLogger(HOOK_LOGGER_NAME).setLevel(logging.INFO)

    for name in _QUIET_LOGGERS:
        logging.getLogger(name).setLevel(logging.WARNING)

    logging.getLogger(__name__).info(
        "Logging configured (console=%s, hook logger=%s, file=%s)",
        log_level,
        HOOK_LOGGER_NAME,
        log_file or "disabled",
    )
