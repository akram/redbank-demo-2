"""LangGraph ReAct agent wired to the RedBank MCP server via MultiServerMCPClient."""

from __future__ import annotations

import logging
import os

from langchain_core.tools import BaseTool
from langchain_mcp_adapters.client import MultiServerMCPClient
from langchain_openai import ChatOpenAI
from langgraph.prebuilt import create_react_agent

logger = logging.getLogger(__name__)

MCP_SERVER_URL = os.getenv("MCP_SERVER_URL", "http://redbank-mcp-server:8000/mcp")
LLM_BASE_URL = os.getenv("LLM_BASE_URL", "")
LLM_MODEL = os.getenv("LLM_MODEL", "")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "")

SYSTEM_PROMPT = """You are the RedBank Banking Operations Agent — an assistant that interacts \
with the RedBank customer database on behalf of the current user. Your access level depends \
on the user's role; you do NOT have independent admin privileges.

Tools available:
- get_customer(email=..., phone=...): look up a customer by email OR phone. \
  Exactly one of the two arguments must be provided. Do NOT call this with both arguments null.
- get_account_summary(customer_id): the correct tool when you only know the customer_id.
- get_customer_transactions(customer_id, start_date?, end_date?): transaction history.
- update_account(customer_id, phone?, address?, account_type?): requires admin role.
- create_transaction(customer_id, amount, description, transaction_type, merchant?, transaction_date?): \
  requires admin role. transaction_type must be exactly "CREDIT" or "DEBIT".

Behaviour:
- If a tool returns an empty result (empty dict {{}}, empty list [], or null), respond with \
  a clear statement like "No data was found for …" and stop. Do NOT retry with guessed values \
  and do NOT repeat the tool call as text.
- If a tool returns an error message such as "admin privileges", "not authorized", or \
  "Authentication error", tell the user they do not have permission. Do NOT retry the tool, \
  do NOT claim you have admin access, and do NOT invent a successful result.
- NEVER fabricate or guess data. Only include data that a tool actually returned.
- You must NEVER write out function/tool calls as text in your response. Phrases like \
  "[get_customer(...)]" or "get_customer_transactions(customer_id=1)" must never appear \
  in your response. If you have nothing to report, just say so in a normal sentence.
- Confirm write operations back to the user, including the returned record.
- Format data cleanly and include relevant identifiers (customer_id, transaction_id, etc.)."""


def create_llm() -> ChatOpenAI:
    """Build the ChatOpenAI instance from environment variables."""
    kwargs: dict = {
        "model": LLM_MODEL,
        "api_key": OPENAI_API_KEY,
        "temperature": 0,
    }
    if LLM_BASE_URL:
        kwargs["base_url"] = LLM_BASE_URL
    return ChatOpenAI(**kwargs)


def _patch_mcp_error_handling(tools: list[BaseTool]) -> list[BaseTool]:
    """Intercept MCP tool errors and return them as text to the LLM.

    Instead of raising ToolException (which the default ToolNode re-raises,
    crashing the agent), this wrapper catches all exceptions and returns the
    error message as a plain string.  The LLM sees the error in the
    ToolMessage and can respond appropriately (e.g. "you don't have
    permission" or "token not found").

    StructuredTool is Pydantic — instance _arun overrides are silently dropped.
    Patching ``coroutine`` (which StructuredTool._arun awaits directly) is the
    correct intercept point.
    """
    for tool in tools:
        orig_coroutine = getattr(tool, "coroutine", None)
        if orig_coroutine is None:
            continue

        uses_artifact = getattr(tool, "response_format", "content") == "content_and_artifact"

        async def _guarded(*args, _orig=orig_coroutine, _artifact=uses_artifact, **kwargs):
            try:
                result = await _orig(*args, **kwargs)
            except Exception as e:
                error_msg = str(e)
                logger.warning("Tool error (returned to LLM): %s", error_msg)
                return (error_msg, error_msg) if _artifact else error_msg
            return result

        tool.coroutine = _guarded
    return tools


async def create_agent_with_tools(bearer_token: str | None = None):
    """Create a LangGraph ReAct agent connected to the MCP server.

    Args:
        bearer_token: JWT to forward to the MCP server for RLS scoping.

    Returns:
        A tuple of (compiled_graph, mcp_client) — caller must manage
        the client lifecycle via ``async with``.
    """
    headers: dict[str, str] = {}
    if bearer_token:
        headers["Authorization"] = f"Bearer {bearer_token}"

    client = MultiServerMCPClient(
        {
            "customer_data": {
                "url": MCP_SERVER_URL,
                "transport": "http",
                "headers": headers,
            },
        }
    )

    tools = await client.get_tools()
    tools = _patch_mcp_error_handling(tools)
    if not tools:
        logger.warning("No tools loaded from MCP server at %s", MCP_SERVER_URL)

    model = create_llm()

    graph = create_react_agent(model, tools, prompt=SYSTEM_PROMPT)

    return graph, client
