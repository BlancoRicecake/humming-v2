"""Fixtures for the cloud backup tests (2026-10-30).

- ``PgSupabase``: the small slice of the supabase-py client the cloud routes
  use (table select/eq/order/maybe_single/upsert, rpc), executed against a
  REAL PostgreSQL database that has the production schema files applied
  (``sql/2026-06-04_cloud_sync_schema.sql``, migrations 003 and 004). Every
  call opens its own connection, so concurrent requests really race inside
  Postgres — the RPC's locking is what is tested, not a mock's call order.
- ``FakeR2``: an in-memory bucket with the boto3 calls the routes make.

A database is needed: set CLOUD_TEST_PG_URI to a superuser connection URI
(e.g. from ``pgserver``; see artifacts/cloud-backup-2026-10-30/README.md).
Without it the Postgres-backed tests are skipped.
"""
from __future__ import annotations

import os
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

ROOT = Path(__file__).resolve().parents[1]

PG_URI = os.environ.get("CLOUD_TEST_PG_URI")

_TYPES = {
    "p_user_id": "uuid",
    "p_meta": "jsonb",
    "p_size_bytes": "bigint",
    "p_expected_updated_at": "timestamptz",
    "p_expect_absent": "boolean",
}

_BOOTSTRAP = """
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key);
create or replace function auth.uid() returns uuid language sql stable as
  $f$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $f$;
grant usage on schema auth to anon, authenticated, service_role;
create table if not exists public.iap_notifications (id int);
"""

_GRANTS = """
grant usage on schema public to anon, authenticated, service_role;
grant all on all tables in schema public to anon, authenticated, service_role;
"""


def create_database() -> str:
    """A fresh database with the production cloud schema; returns its URI."""
    import psycopg

    name = f"cloudtest_{uuid.uuid4().hex[:10]}"
    with psycopg.connect(PG_URI, autocommit=True) as c:
        c.execute(f'create database "{name}"')
    uri = PG_URI.rsplit("/", 1)[0] + "/" + name
    with psycopg.connect(uri, autocommit=True) as c:
        c.execute(_BOOTSTRAP)
        for f in [
            ROOT / "sql" / "2026-06-04_cloud_sync_schema.sql",
            ROOT / "migrations" / "003_lock_down_iap_and_cloud_tables.sql",
            ROOT / "migrations" / "004_cloud_backup_commit.sql",
        ]:
            c.execute(f.read_text(encoding="utf-8"))
        c.execute(_GRANTS)
    return uri


def _jsonable(v: Any) -> Any:
    """What PostgREST would send: timestamps as ISO strings."""
    if isinstance(v, datetime):
        return v.isoformat()
    if isinstance(v, dict):
        return {k: _jsonable(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_jsonable(x) for x in v]
    return v


class _Res:
    def __init__(self, data):
        self.data = data


class _Query:
    def __init__(self, db: "PgSupabase", table: str):
        self.db, self.table = db, table
        self.cols = "*"
        self.filters: List[tuple] = []
        self.order_by: Optional[tuple] = None
        self.single = False
        self.lim: Optional[int] = None
        self.upsert_row: Optional[dict] = None
        self.conflict: Optional[str] = None

    def select(self, cols):
        self.cols = cols
        return self

    def eq(self, col, val):
        self.filters.append((col, val))
        return self

    def order(self, col, desc=False):
        self.order_by = (col, desc)
        return self

    def limit(self, n):
        self.lim = n
        return self

    def maybe_single(self):
        self.single = True
        return self

    def upsert(self, row, on_conflict=None):
        self.upsert_row, self.conflict = row, on_conflict
        return self

    def execute(self):
        from psycopg.rows import dict_row
        from psycopg.types.json import Jsonb

        with self.db.connect() as c:
            if self.upsert_row is not None:
                cols = list(self.upsert_row)
                vals = [Jsonb(v) if isinstance(v, dict) else v for v in self.upsert_row.values()]
                sets = ", ".join(f"{k} = excluded.{k}" for k in cols if k != self.conflict)
                c.execute(
                    f"insert into public.{self.table} ({', '.join(cols)}) values "
                    f"({', '.join(['%s'] * len(cols))}) on conflict ({self.conflict}) do update set {sets}",
                    vals,
                )
                return _Res([self.upsert_row])
            sql = f"select {self.cols} from public.{self.table}"
            if self.filters:
                sql += " where " + " and ".join(f"{k} = %s" for k, _ in self.filters)
            if self.order_by:
                sql += f" order by {self.order_by[0]} {'desc' if self.order_by[1] else 'asc'}"
            if self.lim:
                sql += f" limit {int(self.lim)}"
            cur = c.cursor(row_factory=dict_row)
            rows = [_jsonable(r) for r in cur.execute(sql, [v for _, v in self.filters]).fetchall()]
        if self.single:
            return _Res(rows[0] if rows else None)
        return _Res(rows)


class _Rpc:
    def __init__(self, db, name, params):
        self.db, self.name, self.params = db, name, params

    def execute(self):
        from psycopg.types.json import Jsonb

        args = ", ".join(f"{k} => %({k})s::{_TYPES.get(k, 'text')}" for k in self.params)
        vals = {k: Jsonb(v) if isinstance(v, dict) else v for k, v in self.params.items()}
        with self.db.connect() as c:
            row = c.execute(f"select public.{self.name}({args})", vals).fetchone()
        return _Res(_jsonable(row[0]) if row else None)


class PgSupabase:
    """supabase-py look-alike on a real Postgres (service role: bypasses RLS)."""

    def __init__(self, uri: str):
        self.uri = uri

    def connect(self):
        import psycopg

        return psycopg.connect(self.uri, autocommit=True)

    def table(self, name):
        return _Query(self, name)

    def rpc(self, name, params):
        return _Rpc(self, name, params)

    def add_user(self, user_id: str) -> None:
        with self.connect() as c:
            c.execute("insert into auth.users (id) values (%s) on conflict do nothing", [user_id])


class _ClientError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code}}


class FakeR2:
    """In-memory bucket: key -> (bytes, last_modified).

    ``client_put(url, data, headers)`` plays the app's PUT to a presigned URL
    with the storage rules the URL was signed with: the exact
    ``Content-Length`` and, when signed, ``If-None-Match: *`` (create only).
    That second rule is S3 conditional-write behaviour; that the REAL R2
    bucket enforces it is not verified by these tests.
    """

    def __init__(self):
        self.objects: Dict[str, tuple] = {}
        self.issued: Dict[str, dict] = {}

    # test helpers
    def put(self, key: str, data: bytes, *, age: timedelta = timedelta(0)) -> None:
        self.objects[key] = (bytes(data), datetime.now(timezone.utc) - age)

    def data(self, key: str) -> Optional[bytes]:
        o = self.objects.get(key)
        return o[0] if o else None

    def client_put(self, url: str, data: bytes, headers: Optional[dict] = None) -> int:
        """HTTP status the bucket would answer for a PUT to `url`."""
        p = self.issued.get(url)
        if p is None or p["method"] != "put_object":
            return 403
        headers = {k.lower(): v for k, v in (headers or {}).items()}
        if "ContentLength" in p:
            if headers.get("content-length") != str(p["ContentLength"]) or len(data) != p["ContentLength"]:
                return 403  # signature covers the length
        if p.get("IfNoneMatch") == "*":
            if headers.get("if-none-match") != "*":
                return 403  # signed header missing
            if p["Key"] in self.objects:
                return 412  # create-only
        self.put(p["Key"], data)
        return 200

    # boto3 surface
    def generate_presigned_url(self, ClientMethod, Params, ExpiresIn, HttpMethod):
        url = f"https://r2.invalid/{Params['Key']}?n={len(self.issued)}&X-Amz-Signature=SECRET-SIGNATURE"
        self.issued[url] = {"method": ClientMethod, **Params}
        return url

    def head_object(self, Bucket, Key):
        if Key not in self.objects:
            raise _ClientError("404")
        return {"ContentLength": len(self.objects[Key][0])}

    def copy_object(self, Bucket, Key, CopySource):
        src = CopySource["Key"]
        if src not in self.objects:
            raise _ClientError("404")
        self.put(Key, self.objects[src][0])
        return {}

    def get_paginator(self, name):
        fake = self

        class _P:
            def paginate(self, Bucket, Prefix):
                return [
                    {
                        "Contents": [
                            {"Key": k, "Size": len(d), "LastModified": m}
                            for k, (d, m) in sorted(fake.objects.items())
                            if k.startswith(Prefix)
                        ]
                    }
                ]

        return _P()

    def delete_objects(self, Bucket, Delete):
        gone = []
        for o in Delete["Objects"]:
            if self.objects.pop(o["Key"], None) is not None:
                gone.append({"Key": o["Key"]})
        return {"Deleted": gone}
