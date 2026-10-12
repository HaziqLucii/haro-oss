"""Agent adapters. ClaudeCodeAdapter (cloud, CLI) + LocalModelAdapter (Ollama /
llama.cpp, no cloud); Codex/Cursor/Gemini later."""

from .base import AgentAdapter, NormalizedEvent
from .claude_code import ClaudeCodeAdapter
from .local_model import LocalModelAdapter

__all__ = ["AgentAdapter", "NormalizedEvent", "ClaudeCodeAdapter", "LocalModelAdapter"]
