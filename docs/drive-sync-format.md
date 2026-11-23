# Encrypted Google Drive Bundle Sync Format (`FNB1`)

This document defines the wire format, key pairing string, and Google Drive storage convention shared between the PC exporter (Python) and the iPhone app (Swift / CryptoKit).

## 1. Key Generation and Pairing

- **Symmetric key**: 32 cryptographically random bytes (`os.urandom(32)` / CSPRNG).
- **Key ID**: First 8 bytes of `SHA-256(key)`.
  - Display format for visual verification between PC and phone: 16 lowercase hexadecimal characters (optionally grouped in fours, e.g. `630d cd29 66c4 3366`).
- **Pairing string** (encoded in the QR code or copied for manual paste):

  ```text
  finance-key:v1:<base64url(key, no padding)>
  ```

  - Uses RFC 4648 section 5 URL-safe alphabet (`A-Z`, `a-z`, `0-9`, `-`, `_`) with **no `=` padding**.
  - For a 32-byte key, the base64url payload is always 43 characters.
  - The phone stores the raw 32-byte key in the iOS Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.

### Key Test Vector

- Raw 32-byte key (hex):
  `000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f`
- Pairing string:
  `finance-key:v1:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8`
- `SHA-256(key)[:8]` (key ID hex):
  `630dcd2966c43366`

## 2. Binary Envelope Format (`FNB1`)

The encrypted file uploaded to Google Drive is a single binary blob:

| Offset | Length | Field | Notes |
| --- | --- | --- | --- |
| `0` | `4` | Magic | ASCII `"FNB1"` (`0x46 0x4E 0x42 0x31`) |
| `4` | `8` | `key_id` | First 8 bytes of `SHA-256(key)` |
| `12` | `12` | `nonce` | 12 random bytes, freshly generated on every upload |
| `24` | `N` | `ciphertext` | AES-256-GCM ciphertext of the UTF-8 `finance-bundle` JSON |
| `24 + N` | `16` | `tag` | 16-byte AES-256-GCM authentication tag |

- **Minimum valid length**: `40` bytes (`4 + 8 + 12 + 16`).
- **Algorithm**: AES-256-GCM.
- **AAD (Additional Authenticated Data)**: bytes `0..<12` (`b"FNB1" + key_id`).
- **Plaintext**: UTF-8 bytes of `finance-bundle.json` (`format: "finance-bundle/1"`), unchanged (no compression wrapper).

### Python Reference Producer (`cryptography`)

```python
import base64
import hashlib
import os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"FNB1"

def pairing_string(key: bytes) -> str:
    assert len(key) == 32
    b64 = base64.urlsafe_b64encode(key).rstrip(b"=").decode("ascii")
    return f"finance-key:v1:{b64}"

def key_id(key: bytes) -> bytes:
    assert len(key) == 32
    return hashlib.sha256(key).digest()[:8]

def seal_bundle(plaintext_json_utf8: bytes, key: bytes) -> bytes:
    kid = key_id(key)
    header = MAGIC + kid            # 12 bytes, used as AAD
    nonce = os.urandom(12)          # 12 random bytes
    ct_and_tag = AESGCM(key).encrypt(nonce, plaintext_json_utf8, header)
    return header + nonce + ct_and_tag
```

Note that `cryptography.hazmat.primitives.ciphers.aead.AESGCM.encrypt(...)` returns `ciphertext || tag` (with the 16-byte tag appended at the end), matching `DriveEnvelope` in `FinanceSync`.

## 3. Google Drive Storage Convention

- **Scope**: `https://www.googleapis.com/auth/drive.appdata` (incremental authorization with `include_granted_scopes=true`).
- **Space**: `appDataFolder` (hidden from the user's normal Google Drive view).
- **Filename**: `finance-bundle.fnb`
- **Phone sync protocol**:
  1. `GET https://www.googleapis.com/drive/v3/files?spaces=appDataFolder&q=name%20%3D%20'finance-bundle.fnb'%20and%20trashed%20%3D%20false&fields=files(id,name,modifiedTime,md5Checksum,size)&orderBy=modifiedTime%20desc&pageSize=10`
  2. Pick the newest file (`files[0]`). If `md5Checksum` matches the last imported checksum, skip downloading.
  3. Otherwise `GET https://www.googleapis.com/drive/v3/files/{id}?alt=media`.
  4. Parse `FNB1`, verify `key_id` matches the paired Keychain key, decrypt with AES-256-GCM (`AAD = bytes 0..<12`).
  5. Decode and validate with `DataBundle.decode(from:)`.
  6. Store atomically in the app container with `.completeFileProtectionUntilFirstUserAuthentication` only if `generatedAt` is strictly newer than the currently stored bundle.
