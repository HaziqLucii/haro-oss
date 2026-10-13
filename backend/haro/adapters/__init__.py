"""Agent adapters. ClaudeCodeAdapter (cloud, CLI), OpenCodeAdapter (the OpenCode CLI, any of its
providers) and LocalModelAdapter (Ollama / llama.cpp, no cloud); Codex/Cursor/Gemini later."""

from .base import AgentAdapter, NormalizedEvent
from .claude_code import ClaudeCodeAdapter
from .local_model import LocalModelAdapter
from .opencode import OpenCodeAdapter

__all__ = ["AgentAdapter", "NormalizedEvent", "ClaudeCodeAdapter", "LocalModelAdapter", "OpenCodeAdapter"]
