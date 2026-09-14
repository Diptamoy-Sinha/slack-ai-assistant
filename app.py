from app_config import get_config, init_config
from logging_setup import setup_logging

setup_logging()
init_config()
config = get_config()

from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler
from slack_sdk import WebClient

from listeners import register_listeners

app = App(
    token=config.slack_bot_token,
    client=WebClient(
        base_url=config.slack_api_url,
        token=config.slack_bot_token,
    ),
)

register_listeners(app)

if __name__ == "__main__":
    SocketModeHandler(app, config.slack_app_token).start()
