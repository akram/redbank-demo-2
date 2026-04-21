"""Tests for the knowledge agent tool filtering and LLM setup."""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from src.agent import (
    ALLOWED_TOOLS,
    _filter_allowed_tools,
    create_llm,
)


def _make_mock_tool(name: str) -> MagicMock:
    tool = MagicMock()
    tool.name = name
    return tool


class TestToolAllowList:
    def test_filters_write_tools(self):
        tools = [
            _make_mock_tool("get_customer"),
            _make_mock_tool("get_customer_transactions"),
            _make_mock_tool("get_account_summary"),
            _make_mock_tool("search_knowledge"),
            _make_mock_tool("update_account"),
            _make_mock_tool("create_transaction"),
        ]
        filtered = _filter_allowed_tools(tools)
        names = {t.name for t in filtered}
        assert names == ALLOWED_TOOLS
        assert len(filtered) == 4

    def test_rejects_unknown_tools(self):
        tools = [
            _make_mock_tool("drop_table"),
            _make_mock_tool("exec_sql"),
        ]
        filtered = _filter_allowed_tools(tools)
        assert filtered == []

    def test_keeps_allowed_subset(self):
        tools = [_make_mock_tool("search_knowledge")]
        filtered = _filter_allowed_tools(tools)
        assert len(filtered) == 1
        assert filtered[0].name == "search_knowledge"


class TestCreateLLM:
    @patch("src.agent.LLM_MODEL", "test-model")
    @patch("src.agent.OPENAI_API_KEY", "test-key")
    @patch("src.agent.LLM_BASE_URL", "http://localhost:8080/v1")
    def test_returns_chat_openai(self):
        llm = create_llm()
        assert llm.model_name == "test-model"
        assert str(llm.openai_api_base) == "http://localhost:8080/v1"


class TestBearerTokenForwarding:
    @pytest.mark.asyncio
    @patch("src.agent.MultiServerMCPClient")
    @patch("src.agent.create_llm")
    @patch("src.agent.create_react_agent")
    async def test_bearer_token_in_headers(self, mock_react, mock_llm, mock_client_cls):
        mock_instance = AsyncMock()
        mock_instance.get_tools = AsyncMock(return_value=[])
        mock_client_cls.return_value = mock_instance
        mock_react.return_value = MagicMock()

        from src.agent import create_agent_with_tools
        await create_agent_with_tools(bearer_token="test-jwt-token")

        call_args = mock_client_cls.call_args[0][0]
        headers = call_args["customer_data"]["headers"]
        assert headers["Authorization"] == "Bearer test-jwt-token"

    @pytest.mark.asyncio
    @patch("src.agent.MultiServerMCPClient")
    @patch("src.agent.create_llm")
    @patch("src.agent.create_react_agent")
    async def test_no_token_no_auth_header(self, mock_react, mock_llm, mock_client_cls):
        mock_instance = AsyncMock()
        mock_instance.get_tools = AsyncMock(return_value=[])
        mock_client_cls.return_value = mock_instance
        mock_react.return_value = MagicMock()

        from src.agent import create_agent_with_tools
        await create_agent_with_tools(bearer_token=None)

        call_args = mock_client_cls.call_args[0][0]
        headers = call_args["customer_data"]["headers"]
        assert "Authorization" not in headers
