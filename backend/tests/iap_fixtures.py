"""Shared helpers for IAP / auth tests.

* A throwaway Apple-style certificate chain (root → intermediate → leaf) with
  Apple's policy OIDs, plus a JWS signer — lets us exercise the real chain
  validation without Apple's private keys.
* A tiny in-memory stand-in for the Supabase client covering exactly the
  query shapes ``app.routes.iap`` uses.
"""
from __future__ import annotations

import base64
import json
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional

import jwt as pyjwt
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from app.apple_jws import OID_APPLE_RECEIPT_SIGNING, OID_APPLE_WWDR_INTERMEDIATE


# --- certificate chain -------------------------------------------------------
def _name(cn: str) -> x509.Name:
    return x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, cn),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Test Apple Inc."),
    ])


def _cert(subject_cn, issuer_cn, subject_key, issuer_key, *, ca: bool, oids=(),
          not_before=None, not_after=None):
    now = datetime.now(timezone.utc)
    not_after = not_after or (now + timedelta(days=365))
    not_before = not_before or min(now - timedelta(days=1), not_after - timedelta(days=1))
    b = (
        x509.CertificateBuilder()
        .subject_name(_name(subject_cn))
        .issuer_name(_name(issuer_cn))
        .public_key(subject_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(not_before)
        .not_valid_after(not_after)
        .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
    )
    for dotted in oids:
        b = b.add_extension(
            x509.UnrecognizedExtension(x509.ObjectIdentifier(dotted), b"\x05\x00"),
            critical=False,
        )
    return b.sign(issuer_key, hashes.SHA256())


class FakeAppleChain:
    """root → intermediate (WWDR OID) → leaf (receipt-signing OID)."""

    def __init__(self, *, leaf_oids=(OID_APPLE_RECEIPT_SIGNING,),
                 inter_oids=(OID_APPLE_WWDR_INTERMEDIATE,),
                 leaf_not_after=None):
        self.root_key = ec.generate_private_key(ec.SECP384R1())
        self.inter_key = ec.generate_private_key(ec.SECP256R1())
        self.leaf_key = ec.generate_private_key(ec.SECP256R1())
        self.root = _cert("Test Root", "Test Root", self.root_key, self.root_key, ca=True)
        self.inter = _cert("Test WWDR", "Test Root", self.inter_key, self.root_key,
                           ca=True, oids=inter_oids)
        self.leaf = _cert("Test Receipt Signer", "Test WWDR", self.leaf_key, self.inter_key,
                          ca=False, oids=leaf_oids, not_after=leaf_not_after)

    @property
    def root_pem(self) -> str:
        return self.root.public_bytes(serialization.Encoding.PEM).decode()

    def x5c(self, include_root: bool = True) -> List[str]:
        certs = [self.leaf, self.inter] + ([self.root] if include_root else [])
        return [base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode() for c in certs]

    def sign(self, payload: dict, *, x5c: Optional[List[str]] = None, key=None, alg="ES256") -> str:
        headers = {"alg": alg, "x5c": self.x5c() if x5c is None else x5c}
        return pyjwt.encode(payload, key or self.leaf_key, algorithm=alg, headers=headers)


def self_signed_attacker_jws(payload: dict) -> str:
    """What an attacker can build: a leaf signed by itself, no Apple root."""
    key = ec.generate_private_key(ec.SECP256R1())
    leaf = _cert("Evil", "Evil", key, key, ca=False, oids=(OID_APPLE_RECEIPT_SIGNING,))
    inter = _cert("Evil CA", "Evil CA", key, key, ca=True, oids=(OID_APPLE_WWDR_INTERMEDIATE,))
    x5c = [base64.b64encode(c.public_bytes(serialization.Encoding.DER)).decode() for c in (leaf, inter)]
    return pyjwt.encode(payload, key, algorithm="ES256", headers={"alg": "ES256", "x5c": x5c})


def ms(dt: datetime) -> int:
    return int(dt.timestamp() * 1000)


def apple_tx(*, user_uuid=None, product="humtrack_pro_monthly_v2", expires_in_days=30,
             orig="1000000000000001", txid="1000000000000002", **extra) -> dict:
    now = datetime.now(timezone.utc)
    tx = {
        "transactionId": txid,
        "originalTransactionId": orig,
        "bundleId": "com.example.humtrack",
        "productId": product,
        "purchaseDate": ms(now - timedelta(days=1)),
        "originalPurchaseDate": ms(now - timedelta(days=1)),
        "expiresDate": ms(now + timedelta(days=expires_in_days)),
        "signedDate": ms(now),
        "type": "Auto-Renewable Subscription",
        "environment": "Production",
        "inAppOwnershipType": "PURCHASED",
    }
    if user_uuid:
        tx["appAccountToken"] = user_uuid
    tx.update(extra)
    return tx


# --- fake supabase ------------------------------------------------------------
class _Res:
    def __init__(self, data):
        self.data = data


class _Query:
    def __init__(self, db: "FakeSupabase", table: str):
        self.db, self.table = db, table
        self._filters: List[tuple] = []
        self._limit: Optional[int] = None
        self._op = ("select", None)

    # builders
    def select(self, *_a, **_k):
        self._op = ("select", None); return self

    def insert(self, row):
        self._op = ("insert", row); return self

    def upsert(self, row, on_conflict="user_id"):
        self._op = ("upsert", (row, on_conflict)); return self

    def update(self, patch):
        self._op = ("update", patch); return self

    def delete(self):
        self._op = ("delete", None); return self

    def eq(self, col, val):
        self._filters.append((col, val)); return self

    def limit(self, n):
        self._limit = n; return self

    def maybe_single(self):
        self._limit = 1; return self

    # execution
    def _match(self, row):
        return all(row.get(c) == v for c, v in self._filters)

    def execute(self):
        rows = self.db.tables.setdefault(self.table, [])
        op, arg = self._op
        if op == "select":
            out = [dict(r) for r in rows if self._match(r)]
            return _Res(out[: self._limit] if self._limit else out)
        if op == "insert":
            pk = self.db.pks[self.table]
            if any(r.get(pk) == arg.get(pk) for r in rows):
                raise Exception('duplicate key value violates unique constraint (23505)')
            rows.append(dict(arg)); return _Res([dict(arg)])
        if op == "upsert":
            row, on_conflict = arg
            # emulate the partial unique indexes from migration 002
            for col in ("original_transaction_id", "purchase_token"):
                v = row.get(col)
                if v and any(r.get(col) == v and r.get("store") == row.get("store")
                             and r.get(on_conflict) != row.get(on_conflict) for r in rows):
                    raise Exception(f"duplicate key value violates unique constraint {col} (23505)")
            for r in rows:
                if r.get(on_conflict) == row.get(on_conflict):
                    r.update(row); return _Res([dict(r)])
            rows.append(dict(row)); return _Res([dict(row)])
        if op == "update":
            n = 0
            for r in rows:
                if self._match(r):
                    r.update(arg); n += 1
            return _Res([{"updated": n}])
        if op == "delete":
            keep = [r for r in rows if not self._match(r)]
            self.db.tables[self.table] = keep
            return _Res([])
        raise AssertionError(op)


class FakeSupabase:
    pks = {"subscriptions": "user_id", "iap_notifications": "notification_id"}

    def __init__(self):
        self.tables: Dict[str, List[dict]] = {"subscriptions": [], "iap_notifications": []}

    def table(self, name):
        return _Query(self, name)

    # convenience
    def sub(self, user_id) -> Optional[dict]:
        return next((r for r in self.tables["subscriptions"] if r["user_id"] == user_id), None)


def hs256_token(secret: str, sub: str, *, role="authenticated", aud="authenticated",
                exp_in=3600, **extra) -> str:
    now = datetime.now(timezone.utc)
    claims = {"sub": sub, "role": role, "aud": aud,
              "iat": int(now.timestamp()), "exp": int((now + timedelta(seconds=exp_in)).timestamp())}
    claims.update(extra)
    return pyjwt.encode(claims, secret, algorithm="HS256")


def b64json(obj) -> str:
    return base64.b64encode(json.dumps(obj).encode()).decode()
