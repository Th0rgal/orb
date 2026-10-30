//! AES-256-GCM encryption utilities for server-side secret values at rest.
//!
//! Uses a static 256-bit key loaded from `PRIVATE_KEY` or persisted under
//! `{WORKING_DIR}/.sandboxed-sh/private_key`. Encrypted values are wrapped in
//! `<encrypted v="1">BASE64</encrypted>` format; plaintext values pass through.

use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use rand::RngCore;
use tokio::fs;

/// Key length in bytes (256 bits for AES-256)
const KEY_LENGTH: usize = 32;

/// Nonce length in bytes (96 bits for AES-GCM)
const NONCE_LENGTH: usize = 12;

/// Environment variable name for the encryption key
pub const PRIVATE_KEY_ENV: &str = "PRIVATE_KEY";

/// Current encryption format version
const ENCRYPTION_VERSION: &str = "1";

/// Wrapper prefix and suffix for encrypted values
const ENCRYPTED_PREFIX: &str = "<encrypted v=\"";
const ENCRYPTED_SUFFIX: &str = "</encrypted>";

/// Check if a value is encrypted (has the wrapper format).
pub fn is_encrypted(value: &str) -> bool {
    let trimmed = value.trim();
    trimmed.starts_with(ENCRYPTED_PREFIX) && trimmed.ends_with(ENCRYPTED_SUFFIX)
}

/// Parse an encrypted value, returning `(version, base64_payload)`.
fn parse_encrypted(value: &str) -> Option<(&str, &str)> {
    let trimmed = value.trim();
    if !trimmed.starts_with(ENCRYPTED_PREFIX) || !trimmed.ends_with(ENCRYPTED_SUFFIX) {
        return None;
    }

    let after_prefix = &trimmed[ENCRYPTED_PREFIX.len()..];
    let version_end = after_prefix.find("\">")?;
    let version = &after_prefix[..version_end];

    let payload_start = ENCRYPTED_PREFIX.len() + version_end + 2;
    let payload_end = trimmed.len() - ENCRYPTED_SUFFIX.len();
    let payload = &trimmed[payload_start..payload_end];

    Some((version, payload))
}

/// Encrypt a plaintext value using AES-256-GCM.
/// Returns `<encrypted v="1">BASE64(nonce||ciphertext)</encrypted>`.
pub fn encrypt_value(key: &[u8; KEY_LENGTH], plaintext: &str) -> Result<String> {
    if is_encrypted(plaintext) {
        return Ok(plaintext.to_string());
    }

    let mut nonce_bytes = [0u8; NONCE_LENGTH];
    rand::thread_rng().fill_bytes(&mut nonce_bytes);

    let cipher =
        Aes256Gcm::new_from_slice(key).map_err(|e| anyhow!("Failed to create cipher: {}", e))?;
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, plaintext.as_bytes())
        .map_err(|e| anyhow!("Encryption failed: {}", e))?;

    let mut combined = Vec::with_capacity(NONCE_LENGTH + ciphertext.len());
    combined.extend_from_slice(&nonce_bytes);
    combined.extend_from_slice(&ciphertext);

    let encoded = BASE64.encode(&combined);

    Ok(format!(
        "<encrypted v=\"{}\">{}</encrypted>",
        ENCRYPTION_VERSION, encoded
    ))
}

/// Decrypt an encrypted value. Plaintext values pass through unchanged.
pub fn decrypt_value(key: &[u8; KEY_LENGTH], value: &str) -> Result<String> {
    let (version, payload) = match parse_encrypted(value) {
        Some(parsed) => parsed,
        None => return Ok(value.to_string()),
    };

    if version != ENCRYPTION_VERSION {
        return Err(anyhow!(
            "Unsupported encryption version: {}. Expected: {}",
            version,
            ENCRYPTION_VERSION
        ));
    }

    let combined = BASE64
        .decode(payload)
        .context("Failed to decode encrypted value")?;

    if combined.len() < NONCE_LENGTH {
        return Err(anyhow!("Encrypted value too short"));
    }

    let (nonce_bytes, ciphertext) = combined.split_at(NONCE_LENGTH);

    let cipher =
        Aes256Gcm::new_from_slice(key).map_err(|e| anyhow!("Failed to create cipher: {}", e))?;
    let nonce = Nonce::from_slice(nonce_bytes);

    let plaintext = cipher
        .decrypt(nonce, ciphertext)
        .map_err(|_| anyhow!("Decryption failed: invalid key or corrupted data"))?;

    String::from_utf8(plaintext).context("Decrypted value is not valid UTF-8")
}

/// Load the encryption key from environment. Returns `None` if `PRIVATE_KEY` is unset.
pub fn load_private_key_from_env() -> Result<Option<[u8; KEY_LENGTH]>> {
    let key_str = match std::env::var(PRIVATE_KEY_ENV) {
        Ok(k) if !k.trim().is_empty() => k,
        _ => return Ok(None),
    };

    parse_key(&key_str)
        .map(Some)
        .context("Invalid PRIVATE_KEY format")
}

fn private_key_file_path() -> std::path::PathBuf {
    if let Ok(path) = std::env::var("PRIVATE_KEY_FILE") {
        return std::path::PathBuf::from(path);
    }
    let working_dir = std::env::var("WORKING_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::path::PathBuf::from("/root"));
    working_dir.join(".sandboxed-sh").join("private_key")
}

/// Ensure a private key is available, generating and persisting one lazily if needed.
pub async fn ensure_private_key() -> Result<[u8; KEY_LENGTH]> {
    if let Some(key) = load_private_key_from_env()? {
        tracing::trace!("Using PRIVATE_KEY from environment variable");
        return Ok(key);
    }

    let key_file = private_key_file_path();
    tracing::debug!(
        key_file = %key_file.display(),
        exists = key_file.exists(),
        "Checking for private key file"
    );

    if key_file.exists() {
        match fs::read_to_string(&key_file).await {
            Ok(contents) => {
                let trimmed = contents.trim();
                if !trimmed.is_empty() {
                    let key = parse_key(trimmed).context("Invalid key in private_key file")?;
                    std::env::set_var(PRIVATE_KEY_ENV, trimmed);
                    tracing::info!(
                        key_file = %key_file.display(),
                        "Loaded PRIVATE_KEY from file"
                    );
                    return Ok(key);
                }
                tracing::warn!(
                    key_file = %key_file.display(),
                    "Private key file exists but is empty"
                );
            }
            Err(e) => {
                tracing::warn!(
                    key_file = %key_file.display(),
                    error = %e,
                    "Failed to read private key file"
                );
            }
        }
    }

    tracing::info!(
        key_file = %key_file.display(),
        "Generating new PRIVATE_KEY"
    );

    let key = generate_private_key();
    let key_hex = hex::encode(key);

    if let Some(parent) = key_file.parent() {
        fs::create_dir_all(parent)
            .await
            .context("Failed to create directory for private_key file")?;
    }
    fs::write(&key_file, &key_hex)
        .await
        .context("Failed to write private_key file")?;

    std::env::set_var(PRIVATE_KEY_ENV, &key_hex);

    tracing::info!(
        key_file = %key_file.display(),
        "Generated new PRIVATE_KEY and saved to file"
    );
    Ok(key)
}

fn parse_key(key_str: &str) -> Result<[u8; KEY_LENGTH]> {
    let trimmed = key_str.trim();

    if trimmed.len() == KEY_LENGTH * 2 && trimmed.chars().all(|c| c.is_ascii_hexdigit()) {
        let bytes = hex::decode(trimmed).context("Invalid hex key")?;
        let mut key = [0u8; KEY_LENGTH];
        key.copy_from_slice(&bytes);
        return Ok(key);
    }

    let bytes = BASE64
        .decode(trimmed)
        .context("Key is neither valid hex nor base64")?;

    if bytes.len() != KEY_LENGTH {
        return Err(anyhow!(
            "Key must be {} bytes, got {} bytes",
            KEY_LENGTH,
            bytes.len()
        ));
    }

    let mut key = [0u8; KEY_LENGTH];
    key.copy_from_slice(&bytes);
    Ok(key)
}

/// Generate a new random encryption key.
pub fn generate_private_key() -> [u8; KEY_LENGTH] {
    let mut key = [0u8; KEY_LENGTH];
    rand::thread_rng().fill_bytes(&mut key);
    key
}

/// Get the hex-encoded private key from environment (for backup export).
pub fn get_private_key_hex() -> Option<String> {
    std::env::var(PRIVATE_KEY_ENV)
        .ok()
        .filter(|k| !k.trim().is_empty())
}

/// Set the private key from a hex string (for backup restore / rotation).
pub async fn set_private_key_hex(key_hex: &str) -> Result<()> {
    let _key = parse_key(key_hex).context("Invalid key format")?;

    let key_file = private_key_file_path();
    if let Some(parent) = key_file.parent() {
        fs::create_dir_all(parent).await?;
    }
    fs::write(&key_file, key_hex.trim())
        .await
        .context("Failed to write private_key file")?;

    std::env::set_var(PRIVATE_KEY_ENV, key_hex.trim());

    tracing::info!("Restored PRIVATE_KEY from backup");
    Ok(())
}

/// Parse a key from a hex (or base64) string.
pub fn parse_key_hex(key_hex: &str) -> Result<[u8; KEY_LENGTH]> {
    parse_key(key_hex)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_key() -> [u8; KEY_LENGTH] {
        let mut key = [0u8; KEY_LENGTH];
        for (i, byte) in key.iter_mut().enumerate() {
            *byte = i as u8;
        }
        key
    }

    #[test]
    fn test_is_encrypted() {
        assert!(is_encrypted("<encrypted v=\"1\">abc123</encrypted>"));
        assert!(is_encrypted("  <encrypted v=\"1\">abc123</encrypted>  "));
        assert!(!is_encrypted("plaintext"));
        assert!(!is_encrypted("<encrypted>missing version</encrypted>"));
        assert!(!is_encrypted("<encrypted v=\"1\">no closing tag"));
    }

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let key = test_key();
        let plaintext = "my-secret-api-key-12345";

        let encrypted = encrypt_value(&key, plaintext).unwrap();
        assert!(is_encrypted(&encrypted));
        assert!(encrypted.starts_with("<encrypted v=\"1\">"));
        assert!(encrypted.ends_with("</encrypted>"));

        let decrypted = decrypt_value(&key, &encrypted).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_plaintext_passthrough() {
        let key = test_key();
        let plaintext = "not-encrypted-value";

        let result = decrypt_value(&key, plaintext).unwrap();
        assert_eq!(result, plaintext);
    }

    #[test]
    fn test_no_double_encrypt() {
        let key = test_key();
        let plaintext = "secret";

        let encrypted = encrypt_value(&key, plaintext).unwrap();
        let double_encrypted = encrypt_value(&key, &encrypted).unwrap();

        assert_eq!(encrypted, double_encrypted);
    }

    #[test]
    fn test_different_encryptions_differ() {
        let key = test_key();
        let plaintext = "same-data";

        let encrypted1 = encrypt_value(&key, plaintext).unwrap();
        let encrypted2 = encrypt_value(&key, plaintext).unwrap();

        assert_ne!(encrypted1, encrypted2);
        assert_eq!(decrypt_value(&key, &encrypted1).unwrap(), plaintext);
        assert_eq!(decrypt_value(&key, &encrypted2).unwrap(), plaintext);
    }

    #[test]
    fn test_wrong_key_fails() {
        let key1 = test_key();
        let mut key2 = test_key();
        key2[0] = 255;

        let encrypted = encrypt_value(&key1, "secret").unwrap();
        assert!(decrypt_value(&key2, &encrypted).is_err());
    }

    #[test]
    fn test_parse_key_hex() {
        let hex_key = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
        let key = parse_key(hex_key).unwrap();

        for (i, byte) in key.iter().enumerate() {
            assert_eq!(*byte, i as u8);
        }
    }

    #[test]
    fn test_parse_key_base64() {
        let key_bytes = test_key();
        let base64_key = BASE64.encode(key_bytes);
        let parsed = parse_key(&base64_key).unwrap();

        assert_eq!(parsed, key_bytes);
    }

    #[test]
    fn test_parse_key_invalid() {
        assert!(parse_key("abc").is_err());
        assert!(
            parse_key("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz").is_err()
        );
    }

    #[test]
    fn test_empty_and_unicode() {
        let key = test_key();

        let encrypted_empty = encrypt_value(&key, "").unwrap();
        assert_eq!(decrypt_value(&key, &encrypted_empty).unwrap(), "");

        let unicode = "Hello, 世界! 🎉";
        let encrypted_u = encrypt_value(&key, unicode).unwrap();
        assert_eq!(decrypt_value(&key, &encrypted_u).unwrap(), unicode);
    }
}
