import hashlib
import json
import struct

import pytest

from verify_soundfonts import verify


def test_missing_required_pack_fails_even_when_catalog_exists(tmp_path):
    (tmp_path / 'catalog.json').write_text(json.dumps([{'id':'required','file':'required.sf2'}]))
    result = verify(tmp_path, {'required'})
    assert result['passed'] is False and result['missing_required'] == ['required']


def test_present_pack_checks_container_and_declared_digest(tmp_path):
    data = b'RIFF' + struct.pack('<I', 8) + b'sfbkJUNK'
    row = {'id':'required', 'file':'required.sf2','sha256':hashlib.sha256(data).hexdigest()}
    (tmp_path / 'catalog.json').write_text(json.dumps([row, {'id':'optional','file':'optional.sf2'}]))
    font = tmp_path / 'required.sf2'; font.write_bytes(data)
    result = verify(tmp_path, {'required'})
    assert result['passed'] and result['missing_optional'] == ['optional']
    font.write_bytes(data[:-1]+b'X')
    assert verify(tmp_path, {'required'})['invalid'] == ['required']


def test_catalog_cannot_point_outside_pack(tmp_path):
    (tmp_path / 'catalog.json').write_text(json.dumps([{'id':'bad','file':'../private.sf2'}]))
    with pytest.raises(ValueError): verify(tmp_path, {'bad'})
