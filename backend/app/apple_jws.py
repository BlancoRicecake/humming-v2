"""Apple signed-JWS verification (StoreKit 2 transactions, App Store Server
Notifications V2, renewal info).

Apple signs these payloads with ES256 and ships the certificate chain in the
JWS ``x5c`` header: ``[leaf, intermediate, root]``. A JWS is only trustworthy
when that chain validates up to a *pinned* Apple root — verifying the
signature against whatever certificate the sender put in ``x5c[0]`` proves
nothing (anyone can mint a self-signed cert and sign a fake receipt with it).

Checks performed by :func:`decode_apple_jws` (mirrors Apple's own
``app-store-server-library`` ``SignedDataVerifier``):

1. ``alg`` is ES256 and ``x5c`` is present with >= 2 certificates.
2. Every certificate is within its validity window.
3. Each certificate is directly issued (name + signature) by the next one,
   and the last one either *is* a trusted root or is issued by one.
4. The leaf carries Apple's receipt-signing marker OID
   (``1.2.840.113635.100.6.11.1``) and the intermediate the WWDR marker
   (``1.2.840.113635.100.6.2.1``). Both are required so a certificate Apple
   issued for some other purpose (e.g. a developer signing cert) cannot be
   used to sign a "receipt".
5. The JWS signature verifies with the leaf public key.

The trusted root defaults to *Apple Root CA - G3* (embedded below; SHA-256
fingerprint ``6334 3abf b89a 6a03 ebb5 7e9b 3f5f a7be 7c4f 5c75 6f30 17b3
a8c4 88c3 653e 9179``, as published at
https://www.apple.com/certificateauthority/). Tests inject their own root via
the ``trusted_roots`` parameter.
"""
from __future__ import annotations

import base64
import logging
from datetime import datetime, timezone
from typing import Iterable, List, Optional

logger = logging.getLogger("humming.apple_jws")

# https://www.apple.com/certificateauthority/AppleRootCA-G3.cer (DER → PEM).
APPLE_ROOT_CA_G3_PEM = """-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----
"""

# Apple-specific certificate policy markers.
OID_APPLE_RECEIPT_SIGNING = "1.2.840.113635.100.6.11.1"  # on the leaf
OID_APPLE_WWDR_INTERMEDIATE = "1.2.840.113635.100.6.2.1"  # on the intermediate


class AppleJWSError(ValueError):
    """Raised when a JWS cannot be authenticated as Apple-signed."""


def _load_trusted_roots(pems: Optional[Iterable[str]]):
    from cryptography import x509

    out = []
    for pem in (pems or [APPLE_ROOT_CA_G3_PEM]):
        out.append(x509.load_pem_x509_certificate(pem.encode("ascii")))
    return out


def _has_oid(cert, dotted: str) -> bool:
    from cryptography import x509

    try:
        cert.extensions.get_extension_for_oid(x509.ObjectIdentifier(dotted))
        return True
    except x509.ExtensionNotFound:
        return False


def _is_ca(cert) -> bool:
    from cryptography import x509

    try:
        bc = cert.extensions.get_extension_for_class(x509.BasicConstraints).value
        return bool(bc.ca)
    except x509.ExtensionNotFound:
        return False


def _check_validity(cert, now: datetime, what: str) -> None:
    nb = getattr(cert, "not_valid_before_utc", None) or cert.not_valid_before.replace(tzinfo=timezone.utc)
    na = getattr(cert, "not_valid_after_utc", None) or cert.not_valid_after.replace(tzinfo=timezone.utc)
    if now < nb or now > na:
        raise AppleJWSError(f"{what} certificate outside validity window")


def _issued_by(cert, issuer) -> bool:
    """True when ``cert`` was directly issued by ``issuer`` (name + signature)."""
    try:
        cert.verify_directly_issued_by(issuer)
        return True
    except Exception:
        return False


def verify_x5c_chain(x5c: List[str], *, trusted_roots=None, now: Optional[datetime] = None,
                     require_apple_oids: bool = True):
    """Validate an ``x5c`` chain and return the leaf certificate.

    Raises :class:`AppleJWSError` on any failure.
    """
    from cryptography import x509
    from cryptography.hazmat.primitives.serialization import Encoding

    if not x5c or len(x5c) < 2:
        raise AppleJWSError("x5c chain missing or too short")
    now = now or datetime.now(timezone.utc)
    try:
        certs = [x509.load_der_x509_certificate(base64.b64decode(c)) for c in x5c]
    except Exception as e:
        raise AppleJWSError(f"x5c contains an unparsable certificate: {e}")

    roots = trusted_roots if trusted_roots is not None else _load_trusted_roots(None)
    root_ders = {r.public_bytes(Encoding.DER) for r in roots}

    leaf, intermediates = certs[0], certs[1:]
    _check_validity(leaf, now, "leaf")
    for i, c in enumerate(intermediates):
        _check_validity(c, now, f"chain[{i + 1}]")
        if not _is_ca(c):
            raise AppleJWSError(f"chain[{i + 1}] is not a CA certificate")

    # Walk: each cert must be issued by the next one.
    for i in range(len(certs) - 1):
        if not _issued_by(certs[i], certs[i + 1]):
            raise AppleJWSError(f"chain[{i}] is not issued by chain[{i + 1}]")

    # Anchor: the last cert is a pinned root, or is issued by one.
    last = certs[-1]
    anchored = last.public_bytes(Encoding.DER) in root_ders
    if not anchored:
        anchored = any(_issued_by(last, r) for r in roots)
    if not anchored:
        raise AppleJWSError("chain does not anchor to a trusted Apple root")

    if require_apple_oids:
        if not _has_oid(leaf, OID_APPLE_RECEIPT_SIGNING):
            raise AppleJWSError("leaf lacks Apple receipt-signing OID")
        if not _has_oid(certs[1], OID_APPLE_WWDR_INTERMEDIATE):
            raise AppleJWSError("intermediate lacks Apple WWDR OID")
    return leaf


def decode_apple_jws(jws_str: str, *, trusted_roots=None, now: Optional[datetime] = None,
                     require_apple_oids: bool = True) -> dict:
    """Verify an Apple signed JWS and return its payload.

    Never falls back to an unverified decode — a JWS that cannot be chained
    to Apple's root is rejected with :class:`AppleJWSError`.
    """
    import jwt as pyjwt
    from cryptography.hazmat.primitives import serialization

    if not isinstance(jws_str, str) or jws_str.count(".") != 2:
        raise AppleJWSError("not a compact JWS")
    try:
        header = pyjwt.get_unverified_header(jws_str)
    except Exception as e:
        raise AppleJWSError(f"bad JWS header: {e}")
    if (header.get("alg") or "").upper() != "ES256":
        raise AppleJWSError(f"unexpected alg {header.get('alg')!r}")
    leaf = verify_x5c_chain(header.get("x5c") or [], trusted_roots=trusted_roots, now=now,
                            require_apple_oids=require_apple_oids)
    public_pem = leaf.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    try:
        # Apple payloads carry no exp/aud; only the signature matters here.
        return pyjwt.decode(jws_str, key=public_pem, algorithms=["ES256"],
                            options={"verify_aud": False, "verify_exp": False})
    except Exception as e:
        raise AppleJWSError(f"signature invalid: {e}")
