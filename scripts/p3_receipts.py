#!/usr/bin/env python3
"""Ed25519 receipts for P3 execution records. A signature is not a kernel proof."""
import base64
import hashlib
import json
import os
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    NoEncryption,
    PrivateFormat,
    PublicFormat,
    load_pem_private_key,
    load_pem_public_key,
)


SCHEMA = "orb.p3.receipt.v1"
BACKENDS = ("stock-c", "leannative")


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def payload_hash(payload):
    return hashlib.sha256(canonical(payload)).hexdigest()


def load_private(path):
    key = load_pem_private_key(Path(path).read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise ValueError("receipt key must be Ed25519")
    return key


def load_public(path):
    key = load_pem_public_key(Path(path).read_bytes())
    if not isinstance(key, Ed25519PublicKey):
        raise ValueError("receipt key must be Ed25519")
    return key


def public_pem(private):
    return private.public_key().public_bytes(Encoding.PEM, PublicFormat.SubjectPublicKeyInfo)


def _is_sha256_hex(value):
    return isinstance(value, str) and len(value) == 64 and all(ch in "0123456789abcdef" for ch in value)


def validate_payload_honesty(payload):
    if not isinstance(payload, dict) or payload.get("schema") != SCHEMA:
        raise ValueError("receipt payload schema rejected")
    if payload.get("backend") not in BACKENDS:
        raise ValueError("receipt payload backend rejected")
    compared_backend = payload.get("compared_backend")
    if compared_backend not in BACKENDS:
        raise ValueError("receipt payload compared_backend rejected")
    if not _is_sha256_hex(payload.get("artifact_sha256")):
        raise ValueError("receipt payload artifact_sha256 rejected")
    if not _is_sha256_hex(payload.get("stock_artifact_sha256")):
        raise ValueError("receipt payload stock_artifact_sha256 rejected")
    compared_sha = payload.get("compared_artifact_sha256")
    if not _is_sha256_hex(compared_sha):
        raise ValueError("receipt payload compared_artifact_sha256 rejected")
    leannative_sha = payload.get("leannative_artifact_sha256")
    if compared_backend == "leannative":
        if not _is_sha256_hex(leannative_sha) or compared_sha != leannative_sha:
            raise ValueError("receipt payload leannative_artifact_sha256 mismatch")
    elif leannative_sha is not None or compared_sha != payload.get("stock_artifact_sha256"):
        raise ValueError("receipt payload stock comparison artifact mismatch")
    expected_selected_sha = (
        leannative_sha if payload.get("backend") == "leannative" else payload.get("stock_artifact_sha256")
    )
    if payload.get("artifact_sha256") != expected_selected_sha:
        raise ValueError("receipt payload selected artifact_sha256 mismatch")
    if payload.get("phase_acceptance") is not False:
        raise ValueError("receipt payload cannot claim phase acceptance")
    if payload.get("coverage") != "INCOMPLETE":
        raise ValueError("receipt payload must preserve incomplete coverage status")


def sign_receipt(payload, private):
    validate_payload_honesty(payload)
    digest = payload_hash(payload)
    signature = private.sign(canonical(payload))
    return {
        "schema": SCHEMA,
        "payload_sha256": digest,
        "payload": payload,
        "signature": base64.b64encode(signature).decode(),
        "public_key": public_pem(private).decode(),
        "assurance": "Tested",
        "kernel_proof": False,
    }


def verify_receipt(receipt, public):
    if not isinstance(receipt, dict) or receipt.get("schema") != SCHEMA:
        raise ValueError("receipt schema rejected")
    if receipt.get("kernel_proof") is not False or receipt.get("assurance") != "Tested":
        raise ValueError("receipt overclaims assurance")
    payload = receipt.get("payload")
    validate_payload_honesty(payload)
    if receipt.get("payload_sha256") != payload_hash(payload):
        raise ValueError("receipt payload hash mismatch")
    try:
        raw = base64.b64decode(receipt["signature"], validate=True)
        public.verify(raw, canonical(payload))
    except (KeyError, InvalidSignature, ValueError) as error:
        raise ValueError("receipt signature rejected") from error
    return payload


def write_keypair(directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    private = Ed25519PrivateKey.generate()
    key_path = directory / "p3-receipt.key"
    raw_private = private.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption())
    fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, raw_private)
    finally:
        os.close(fd)
    (directory / "p3-receipt.pub").write_bytes(public_pem(private))
    return private
