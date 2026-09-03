"""app.apple_jws — chain validation must reject anything not anchored to the
pinned Apple root (the pre-2026-09 code verified against x5c[0] itself)."""
from datetime import datetime, timedelta, timezone

import jwt as pyjwt
import pytest
from cryptography import x509

from app import apple_jws
from app.apple_jws import AppleJWSError, decode_apple_jws

from tests.iap_fixtures import FakeAppleChain, self_signed_attacker_jws


@pytest.fixture(scope="module")
def chain():
    return FakeAppleChain()


def roots(chain):
    return [chain.root]


def test_valid_chain_decodes(chain):
    tok = chain.sign({"productId": "p", "expiresDate": 1})
    assert decode_apple_jws(tok, trusted_roots=roots(chain)) == {"productId": "p", "expiresDate": 1}


def test_chain_without_root_in_x5c_still_anchors(chain):
    tok = chain.sign({"a": 1}, x5c=chain.x5c(include_root=False))
    assert decode_apple_jws(tok, trusted_roots=roots(chain)) == {"a": 1}


def test_self_signed_attacker_rejected(chain):
    tok = self_signed_attacker_jws({"productId": "p", "expiresDate": 4102444800000})
    with pytest.raises(AppleJWSError):
        decode_apple_jws(tok, trusted_roots=roots(chain))


def test_default_root_is_real_apple_and_rejects_test_chain(chain):
    """Without an injected root the embedded Apple Root CA G3 is used."""
    tok = chain.sign({"a": 1})
    with pytest.raises(AppleJWSError, match="anchor"):
        decode_apple_jws(tok)
    root = x509.load_pem_x509_certificate(apple_jws.APPLE_ROOT_CA_G3_PEM.encode())
    assert "Apple Root CA - G3" in root.subject.rfc4514_string()


def test_missing_x5c_rejected(chain):
    tok = pyjwt.encode({"a": 1}, chain.leaf_key, algorithm="ES256")
    with pytest.raises(AppleJWSError, match="x5c"):
        decode_apple_jws(tok, trusted_roots=roots(chain))


def test_signature_by_other_key_rejected(chain):
    other = FakeAppleChain()
    # correct (trusted) chain in the header, but signed with someone else's key
    tok = chain.sign({"a": 1}, key=other.leaf_key)
    with pytest.raises(AppleJWSError, match="signature"):
        decode_apple_jws(tok, trusted_roots=roots(chain))


def test_wrong_alg_rejected(chain):
    tok = pyjwt.encode({"a": 1}, "secret", algorithm="HS256", headers={"x5c": chain.x5c()})
    with pytest.raises(AppleJWSError, match="alg"):
        decode_apple_jws(tok, trusted_roots=roots(chain))


def test_leaf_without_receipt_oid_rejected():
    c = FakeAppleChain(leaf_oids=())
    tok = c.sign({"a": 1})
    with pytest.raises(AppleJWSError, match="receipt-signing OID"):
        decode_apple_jws(tok, trusted_roots=[c.root])


def test_intermediate_without_wwdr_oid_rejected():
    c = FakeAppleChain(inter_oids=())
    tok = c.sign({"a": 1})
    with pytest.raises(AppleJWSError, match="WWDR"):
        decode_apple_jws(tok, trusted_roots=[c.root])


def test_expired_leaf_rejected():
    c = FakeAppleChain(leaf_not_after=datetime.now(timezone.utc) - timedelta(days=1))
    tok = c.sign({"a": 1})
    with pytest.raises(AppleJWSError, match="validity"):
        decode_apple_jws(tok, trusted_roots=[c.root])


def test_untrusted_root_rejected(chain):
    tok = chain.sign({"a": 1})
    with pytest.raises(AppleJWSError, match="anchor"):
        decode_apple_jws(tok, trusted_roots=[FakeAppleChain().root])


def test_garbage_rejected(chain):
    with pytest.raises(AppleJWSError):
        decode_apple_jws("not.a.jws", trusted_roots=roots(chain))
    with pytest.raises(AppleJWSError):
        decode_apple_jws("nodots", trusted_roots=roots(chain))
