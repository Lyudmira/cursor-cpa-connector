#!/usr/bin/env python3
"""Upsert Bifrost config.db providers/keys/routing for kit init-config.ps1."""

from __future__ import annotations

import argparse
import json
import sqlite3
import uuid
from datetime import datetime, timezone
from pathlib import Path

ALLOWED_REQUESTS = {
    "list_models": True,
    "text_completion": False,
    "text_completion_stream": False,
    "chat_completion": True,
    "chat_completion_stream": True,
    "responses": True,
    "responses_stream": True,
    "responses_retrieve": False,
    "responses_delete": False,
    "responses_cancel": False,
    "responses_input_items": False,
    "count_tokens": False,
    "compaction": False,
    "embedding": False,
    "rerank": False,
    "ocr": False,
    "speech": False,
    "speech_stream": False,
    "transcription": False,
    "transcription_stream": False,
    "image_generation": False,
    "image_generation_stream": False,
    "image_edit": False,
    "image_edit_stream": False,
    "image_variation": False,
    "video_generation": False,
    "video_retrieve": False,
    "video_download": False,
    "video_delete": False,
    "video_list": False,
    "video_remix": False,
    "batch_create": False,
    "batch_list": False,
    "batch_retrieve": False,
    "batch_cancel": False,
    "batch_delete": False,
    "batch_results": False,
    "file_upload": False,
    "file_list": False,
    "file_retrieve": False,
    "file_delete": False,
    "file_content": False,
    "container_create": False,
    "container_list": False,
    "container_retrieve": False,
    "container_delete": False,
    "container_file_create": False,
    "container_file_list": False,
    "container_file_retrieve": False,
    "container_file_content": False,
    "container_file_delete": False,
    "passthrough": False,
    "passthrough_stream": False,
    "websocket_responses": False,
    "realtime": False,
    "cached_content_create": False,
    "cached_content_list": False,
    "cached_content_retrieve": False,
    "cached_content_update": False,
    "cached_content_delete": False,
}

PATH_OVERRIDES = {
    "chat_completion": "/chat/completions",
    "chat_completion_stream": "/chat/completions",
    "list_models": "/models",
    "responses": "/responses",
    "responses_stream": "/responses",
}

PRIMARY_MODELS = [
    "claude-sonnet-5",
    "claude-fable-5",
    "claude-opus-4-8",
    "claude-opus-4-6",
    "gpt-5.4-mini",
    "gpt-5.4",
    "gpt-5.5",
    "gpt-5.6-luna",
    "gpt-5.6-sol",
    "gpt-5.6-terra",
]

BACKUP_MODELS = [
    "gpt-5.3-codex-spark",
    "gpt-5.3-codex-spark-preview",
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.4-openai-compact",
    "gpt-5.5",
    "gpt-5.5-openai-compact",
]

CPA_MODELS = [
    "gpt-5.4",
    "gpt-5.4-mini",
    "gpt-5.5",
    "gpt-5.6-luna",
    "gpt-5.6-sol",
    "gpt-5.6-terra",
    "codex-auto-review",
]

SPARK_PREVIEW = "gpt-5.3-codex-spark-preview"
SPARK_UPSTREAM = "gpt-5.3-codex-spark"


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S.%f") + "+00:00"


def custom_provider_json() -> str:
    return json.dumps(
        {
            "is_key_less": False,
            "base_provider_type": "openai",
            "allowed_requests": ALLOWED_REQUESTS,
            "request_path_overrides": PATH_OVERRIDES,
        },
        separators=(",", ":"),
    )


def network_json(base_url: str, timeout: int = 120, max_retries: int = 1, allow_private: bool = False) -> str:
    cfg = {
        "base_url": base_url.rstrip("/"),
        "default_request_timeout_in_seconds": timeout,
        "max_retries": max_retries,
        "retry_backoff_initial": 0,
        "retry_backoff_max": 0,
    }
    if allow_private:
        cfg["allow_private_network"] = True
    return json.dumps(cfg, separators=(",", ":"))


def upsert_provider(conn: sqlite3.Connection, name: str, base_url: str, allow_private: bool = False) -> int:
    row = conn.execute("SELECT id FROM config_providers WHERE name = ?", (name,)).fetchone()
    net = network_json(base_url, allow_private=allow_private)
    custom = custom_provider_json()
    now = utc_now()
    if row:
        conn.execute(
            """
            UPDATE config_providers
            SET network_config_json = ?, custom_provider_config_json = ?, updated_at = ?, status = COALESCE(status, 'active')
            WHERE id = ?
            """,
            (net, custom, now, row[0]),
        )
        return int(row[0])
    cur = conn.execute(
        """
        INSERT INTO config_providers (
            name, network_config_json, custom_provider_config_json, created_at, updated_at, status
        ) VALUES (?, ?, ?, ?, ?, 'active')
        """,
        (name, net, custom, now, now),
    )
    return int(cur.lastrowid)


def upsert_key(
    conn: sqlite3.Connection,
    provider: str,
    provider_id: int,
    key_name: str,
    api_key: str,
    models: list[str],
) -> None:
    models_json = json.dumps(models, separators=(",", ":"))
    now = utc_now()
    row = conn.execute(
        "SELECT id FROM config_keys WHERE provider = ? AND name = ?",
        (provider, key_name),
    ).fetchone()
    if row:
        conn.execute(
            """
            UPDATE config_keys
            SET value = ?, models_json = ?, enabled = 1, provider_id = ?, updated_at = ?
            WHERE id = ?
            """,
            (api_key, models_json, provider_id, now, row[0]),
        )
        return
    conn.execute(
        """
        INSERT INTO config_keys (
            name, provider_id, provider, key_id, value, models_json, weight, enabled, created_at, updated_at, status
        ) VALUES (?, ?, ?, ?, ?, ?, 1.0, 1, ?, ?, 'active')
        """,
        (key_name, provider_id, provider, str(uuid.uuid4()), api_key, models_json, now, now),
    )


def upsert_route(
    conn: sqlite3.Connection,
    name: str,
    cel: str,
    description: str,
    provider: str,
    model: str,
    fallbacks: list[str],
    priority: int = 2,
) -> None:
    now = utc_now()
    fallbacks_json = json.dumps(fallbacks, separators=(",", ":"))
    row = conn.execute(
        "SELECT id FROM routing_rules WHERE cel_expression = ?",
        (cel,),
    ).fetchone()
    if row:
        rule_id = row[0]
        conn.execute(
            """
            UPDATE routing_rules
            SET name = ?, description = ?, enabled = 1, fallbacks = ?, priority = ?, updated_at = ?, scope = 'global'
            WHERE id = ?
            """,
            (name, description, fallbacks_json, priority, now, rule_id),
        )
        conn.execute("DELETE FROM routing_targets WHERE rule_id = ?", (rule_id,))
    else:
        rule_id = str(uuid.uuid4())
        conn.execute(
            """
            INSERT INTO routing_rules (
                id, name, description, enabled, cel_expression, fallbacks, scope, chain_rule, priority, created_at, updated_at
            ) VALUES (?, ?, ?, 1, ?, ?, 'global', 0, ?, ?, ?)
            """,
            (rule_id, name, description, cel, fallbacks_json, priority, now, now),
        )
    conn.execute(
        """
        INSERT INTO routing_targets (rule_id, provider, model, key_id, weight)
        VALUES (?, ?, ?, '', 1.0)
        """,
        (rule_id, provider, model),
    )


def apply(db_path: Path, primary_url: str, primary_key: str, backup_url: str | None, backup_key: str | None, cpa_url: str, cpa_key: str, dry_run: bool) -> None:
    enable_backup = bool(backup_url and backup_key)
    actions = [
        f"provider cpa -> {cpa_url}",
        f"provider muskapi (primary) -> {primary_url}",
    ]
    if enable_backup:
        actions.append(f"provider newapi (backup) -> {backup_url}")
        actions.append("routing: primary models -> muskapi with newapi fallback")
        actions.append(f"routing: {SPARK_PREVIEW} -> newapi/{SPARK_UPSTREAM}")
        actions.append("routing: cpa codex models -> cpa with newapi fallback")
    else:
        actions.append("backup skipped")
        actions.append("routing: primary models -> muskapi (no fallback)")
        actions.append("routing: cpa codex models -> cpa (no fallback)")

    print("Planned Bifrost DB changes:")
    for a in actions:
        print(f"  - {a}")
    if dry_run:
        print("DryRun: no DB writes")
        return

    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    try:
        # Ensure core tables exist (fresh Bifrost volume may create schema on first boot;
        # if DB is empty/missing tables, fail clearly).
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        needed = {"config_providers", "config_keys", "routing_rules", "routing_targets"}
        missing = needed - tables
        if missing:
            raise SystemExit(
                f"Bifrost DB missing tables {sorted(missing)}. "
                "Start Bifrost once so it initializes schema, then re-run init-config."
            )

        cpa_id = upsert_provider(conn, "cpa", cpa_url, allow_private=True)
        upsert_key(conn, "cpa", cpa_id, "cpa-key-1", cpa_key, CPA_MODELS)

        cpa_set = set(CPA_MODELS)
        primary_id = upsert_provider(conn, "muskapi", primary_url)
        primary_key_models = [model for model in PRIMARY_MODELS if model not in cpa_set]
        upsert_key(conn, "muskapi", primary_id, "muskapi-key-1", primary_key, primary_key_models)

        if enable_backup:
            backup_id = upsert_provider(conn, "newapi", backup_url)  # type: ignore[arg-type]
            upsert_key(conn, "newapi", backup_id, "newapi-key-1", backup_key, BACKUP_MODELS)  # type: ignore[arg-type]

        # Models served by logged-in CPA win the CEL route; remaining primary
        # models (Anthropic / extra GPT) go to muskapi.
        for model in PRIMARY_MODELS:
            if model in cpa_set:
                continue
            fb = [f"newapi/{model}"] if enable_backup else []
            upsert_route(
                conn,
                name=f"{model} primary",
                cel=f"model == '{model}'",
                description="primary muskapi; optional newapi fallback",
                provider="muskapi",
                model=model,
                fallbacks=fb,
                priority=10,
            )

        for model in CPA_MODELS:
            fb = [f"newapi/{model}"] if enable_backup else []
            upsert_route(
                conn,
                name=f"{model} CPA first",
                cel=f"model == '{model}'",
                description="logged-in CPA first; optional newapi fallback",
                provider="cpa",
                model=model,
                fallbacks=fb,
                priority=5,
            )

        if enable_backup:
            upsert_route(
                conn,
                name="gpt-5.3-codex-spark-preview rewrite",
                cel=f"model == '{SPARK_PREVIEW}'",
                description="spark-preview via backup newapi",
                provider="newapi",
                model=SPARK_UPSTREAM,
                fallbacks=[],
                priority=2,
            )
            upsert_route(
                conn,
                name="gpt-5.3-codex-spark newapi",
                cel=f"model == '{SPARK_UPSTREAM}'",
                description="spark via backup newapi",
                provider="newapi",
                model=SPARK_UPSTREAM,
                fallbacks=[],
                priority=2,
            )

        conn.commit()
        print(f"Updated {db_path}")
    finally:
        conn.close()


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--db", required=True)
    p.add_argument("--primary-url", required=True)
    p.add_argument("--primary-key", required=True)
    p.add_argument("--backup-url", default="")
    p.add_argument("--backup-key", default="")
    p.add_argument("--cpa-url", required=True)
    p.add_argument("--cpa-key", required=True)
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()
    backup_url = args.backup_url.strip() or None
    backup_key = args.backup_key.strip() or None
    apply(
        Path(args.db),
        args.primary_url.strip(),
        args.primary_key.strip(),
        backup_url,
        backup_key,
        args.cpa_url.strip(),
        args.cpa_key.strip(),
        args.dry_run,
    )


if __name__ == "__main__":
    main()
