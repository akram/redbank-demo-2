"""A2A AgentExecutor that bridges incoming A2A requests to the LangGraph agent."""

from __future__ import annotations

import logging

from openai import RateLimitError
from typing_extensions import override

from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.utils import new_agent_text_message

from .agent import create_agent_with_tools

logger = logging.getLogger(__name__)


def _extract_bearer_token(context: RequestContext) -> str | None:
    """Extract the Bearer token that the CallContextBuilder stashed in state."""
    try:
        call_ctx = context.call_context
        if call_ctx and call_ctx.state:
            return call_ctx.state.get("bearer_token")
    except Exception:
        pass
    return None


class BankingAgentExecutor(AgentExecutor):
    """Bridges A2A protocol to the LangGraph banking agent."""

    @override
    async def execute(
        self,
        context: RequestContext,
        event_queue: EventQueue,
    ) -> None:
        user_text = context.get_user_input()
        if not user_text or not user_text.strip():
            await event_queue.enqueue_event(
                new_agent_text_message("I didn't receive a message. Please try again.")
            )
            return

        bearer_token = _extract_bearer_token(context)
        logger.info(
            "Processing request (token=%s): %.80s",
            "present" if bearer_token else "absent",
            user_text,
        )

        try:
            graph, client = await create_agent_with_tools(bearer_token)
            result = await graph.ainvoke(
                {"messages": [{"role": "user", "content": user_text}]}
            )
            response_text = result["messages"][-1].content
            await event_queue.enqueue_event(new_agent_text_message(response_text))

        except RateLimitError as e:
            logger.warning("LLM rate limit hit: %s", e)
            await event_queue.enqueue_event(
                new_agent_text_message(
                    "The service is temporarily overloaded. "
                    "Please wait a moment and try again."
                )
            )

        except Exception:
            logger.exception("Agent execution failed")
            await event_queue.enqueue_event(
                new_agent_text_message(
                    "An error occurred while processing your request. "
                    "Please try again or contact support."
                )
            )

    @override
    async def cancel(
        self,
        context: RequestContext,
        event_queue: EventQueue,
    ) -> None:
        raise NotImplementedError("Task cancellation is not supported")
