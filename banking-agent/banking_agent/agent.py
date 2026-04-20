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

WRITE_TOOLS = {"update_account", "create_transaction", "get_customer"}

SYSTEM_PROMPT = """You are the RedBank Banking Operations Agent — an admin-only assistant that \
performs write operations on the RedBank customer database. You are restricted to account \
updates and transaction creation. For read-only queries (account summaries, transaction \
history, document search), direct the user to the Knowledge Agent.

Tools available:
- get_customer(email=..., phone=...): look up a customer by email OR phone to resolve their \
  customer_id before performing a write operation. Exactly one argument must be provided.
- update_account(customer_id, phone?, address?, account_type?): update customer account details.
- create_transaction(customer_id, amount, description, transaction_type, merchant?, transaction_date?): \
  create a new transaction. transaction_type must be exactly "CREDIT" or "DEBIT".

Behaviour:
- If a tool returns an empty result (empty dict {{}}, empty list [], or null), respond with \
  a clear statement like "No data was found for …" and stop. Do NOT retry with guessed values \
  and do NOT repeat the tool call as text.
- If a tool returns an error message such as "admin privileges", "not authorized", or \
  "Authentication error", tell the user they do not have permission. Do NOT retry the tool, \
  do NOT claim you have admin access, and do NOT invent a successful result.
- NEVER fabricate or guess data. Only include data that a tool actually returned.
- You must NEVER write out function/tool calls as text in your response. Phrases like \
  "[get_customer(...)]" or "update_account(customer_id=1)" must never appear \
  in your response. If you have nothing to report, just say so in a normal sentence.
- If the user asks to read transactions, view account summaries, or search documents, \
  tell them to use the Knowledge Agent instead. Do NOT attempt to fulfil read-only requests.
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

    all_tools = await client.get_tools()
    tools = [t for t in all_tools if t.name in WRITE_TOOLS]
    tools = _patch_mcp_error_handling(tools)
    if not tools:
        logger.warning("No tools loaded from MCP server at %s", MCP_SERVER_URL)
    logger.info(
        "Loaded %d/%d tools (write-scoped): %s",
        len(tools), len(all_tools), [t.name for t in tools],
    )

    model = create_llm()

    graph = create_react_agent(model, tools, prompt=SYSTEM_PROMPT)

    return graph, client
