"""Settings are SIW_* (server-infra-workbench). Before the rename they were VSW_* (vps-server-workbench):
an unset SIW_X falls back to VSW_X, and the CLI prints a one-line notice per VSW_* it sees (ADR 0014)."""

from __future__ import annotations

import os
from collections.abc import Mapping

PREFIX, LEGACY_PREFIX = "SIW_", "VSW_"


def get(name: str, env: Mapping[str, str] | None = None) -> str | None:
    """SIW_X from env (default os.environ), else VSW_X; None when both are unset or empty."""
    env = os.environ if env is None else env
    value = env.get(name) or None
    if value is None and name.startswith(PREFIX):
        value = env.get(LEGACY_PREFIX + name[len(PREFIX) :]) or None
    return value


def with_fallbacks(env: Mapping[str, str]) -> dict[str, str]:
    """A copy of env with every VSW_X also set as SIW_X where SIW_X is unset."""
    out = dict(env)
    for key, value in env.items():
        if key.startswith(LEGACY_PREFIX):
            out.setdefault(PREFIX + key[len(LEGACY_PREFIX) :], value)
    return out


def legacy_in_use(env: Mapping[str, str] | None = None) -> list[str]:
    """The VSW_* names that are set (non-empty), sorted."""
    env = os.environ if env is None else env
    return sorted(k for k, v in env.items() if k.startswith(LEGACY_PREFIX) and v)


def notices(env: Mapping[str, str] | None = None) -> list[str]:
    return [
        f"note: {k} is deprecated, use {PREFIX}{k[len(LEGACY_PREFIX) :]} (the old name is still read for now)"
        for k in legacy_in_use(env)
    ]
