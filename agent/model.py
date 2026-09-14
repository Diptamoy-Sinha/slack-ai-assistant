from strands.models.openai import OpenAIModel

from app_config import get_config

openai_model = OpenAIModel(
    client_args={
        "api_key": get_config().openai_api_key,
    },
    model_id="gpt-4o-mini",
    params={
        "max_tokens": 4096,
        "temperature": 0.7,
    },
)
