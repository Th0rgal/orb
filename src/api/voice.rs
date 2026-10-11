//! Authenticated, bounded audio relay. Mobile clients never receive Spark credentials.
use axum::{body::Bytes, extract::Query, http::StatusCode, Json};
use serde::{Deserialize, Serialize};
use std::{sync::OnceLock, time::Duration};
use tokio::sync::Semaphore;

pub const MAX_AUDIO_BYTES: usize = 4 * 1024 * 1024;
const LANGUAGES: &[&str] = &[
    "en", "fr", "de", "es", "it", "pt", "nl", "pl", "el", "ar", "ja", "zh", "vi", "ko",
];
static SLOTS: Semaphore = Semaphore::const_new(2);
type Failure = (StatusCode, &'static str);
#[derive(Deserialize)]
pub struct Options {
    pub language: String,
}
#[derive(Serialize, Deserialize)]
pub struct Transcript {
    pub text: String,
}

fn validate_wav(wav: &[u8]) -> Result<(), Failure> {
    let invalid = (
        StatusCode::BAD_REQUEST,
        "Expected a mono 16 kHz, 16-bit PCM WAV (up to 120 seconds).",
    );
    if wav.len() < 44
        || wav.len() > MAX_AUDIO_BYTES
        || &wav[..4] != b"RIFF"
        || &wav[8..12] != b"WAVE"
    {
        return Err(invalid);
    }
    let u16le = |p: usize| u16::from_le_bytes([wav[p], wav[p + 1]]);
    let u32le = |p: usize| u32::from_le_bytes(wav[p..p + 4].try_into().unwrap());
    if u32le(4) as usize + 8 != wav.len() {
        return Err(invalid);
    }
    let mut offset = 12;
    let mut format = false;
    let mut samples = None;
    while offset + 8 <= wav.len() {
        let size = u32le(offset + 4) as usize;
        let start = offset + 8;
        let end = start
            .checked_add(size)
            .filter(|end| *end <= wav.len())
            .ok_or(invalid)?;
        match &wav[offset..offset + 4] {
            b"fmt " => {
                if format
                    || size < 16
                    || u16le(start) != 1
                    || u16le(start + 2) != 1
                    || u32le(start + 4) != 16000
                    || u32le(start + 8) != 32000
                    || u16le(start + 12) != 2
                    || u16le(start + 14) != 16
                {
                    return Err(invalid);
                }
                format = true;
            }
            b"data" => {
                if samples.is_some() || !(3200..=120 * 32000).contains(&size) || size % 2 != 0 {
                    return Err(invalid);
                }
                samples = Some(size);
            }
            _ => {}
        }
        offset = end + size % 2;
    }
    if !format || samples.is_none() || offset != wav.len() {
        return Err(invalid);
    }
    Ok(())
}

pub async fn transcribe(
    Query(options): Query<Options>,
    body: Bytes,
) -> Result<Json<Transcript>, Failure> {
    if !LANGUAGES.contains(&options.language.as_str()) {
        return Err((StatusCode::BAD_REQUEST, "Unsupported dictation language."));
    }
    validate_wav(&body)?;
    let _slot = SLOTS.try_acquire().map_err(|_| {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            "Dictation is busy. Please retry shortly.",
        )
    })?;
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    let client = CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(90))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("voice HTTP client")
    });
    let endpoint = std::env::var("SANDBOXED_VOICE_TRANSCRIPTION_URL")
        .unwrap_or_else(|_| "http://100.77.4.93:8000/v1/audio/transcriptions".into());
    forward(
        client,
        &endpoint,
        std::env::var("SANDBOXED_VOICE_TRANSCRIPTION_TOKEN").ok(),
        options.language,
        body,
    )
    .await
    .map(Json)
}

async fn forward(
    client: &reqwest::Client,
    endpoint: &str,
    token: Option<String>,
    language: String,
    body: Bytes,
) -> Result<Transcript, Failure> {
    let form = reqwest::multipart::Form::new()
        .text("model", "cohere-transcribe")
        .text("language", language)
        .text("response_format", "json")
        .part(
            "file",
            reqwest::multipart::Part::bytes(body.to_vec())
                .file_name("dictation.wav")
                .mime_str("audio/wav")
                .unwrap(),
        );
    let mut request = client.post(endpoint).multipart(form);
    if let Some(token) = token {
        request = request.bearer_auth(token);
    }
    let unavailable = (
        StatusCode::SERVICE_UNAVAILABLE,
        "Transcription is unavailable. Your recording can be retried.",
    );
    let mut response = request.send().await.map_err(|_| unavailable)?;
    if !response.status().is_success() {
        return Err(unavailable);
    }
    let mut data = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| unavailable)? {
        if data.len() + chunk.len() > 64 * 1024 {
            return Err(unavailable);
        }
        data.extend_from_slice(&chunk);
    }
    let mut transcript: Transcript = serde_json::from_slice(&data).map_err(|_| unavailable)?;
    transcript.text = transcript.text.trim().to_owned();
    Ok(transcript)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn wav() -> Vec<u8> {
        let mut w = b"RIFF".to_vec();
        w.extend(3236u32.to_le_bytes());
        w.extend(b"WAVEfmt ");
        w.extend(16u32.to_le_bytes());
        w.extend(1u16.to_le_bytes());
        w.extend(1u16.to_le_bytes());
        w.extend(16000u32.to_le_bytes());
        w.extend(32000u32.to_le_bytes());
        w.extend(2u16.to_le_bytes());
        w.extend(16u16.to_le_bytes());
        w.extend(b"data");
        w.extend(3200u32.to_le_bytes());
        w.resize(3244, 0);
        w
    }
    #[test]
    fn recorder_audio_and_metadata_chunks_are_accepted() {
        assert!(validate_wav(&wav()).is_ok());
        let mut w = wav();
        w.extend(b"JUNK");
        w.extend(1u32.to_le_bytes());
        w.extend([0, 0]);
        let len = (w.len() - 8) as u32;
        w[4..8].copy_from_slice(&len.to_le_bytes());
        assert!(validate_wav(&w).is_ok());
    }
    #[test]
    fn compressed_wrong_rate_truncated_and_oversized_audio_is_rejected() {
        for (offset, bytes) in [
            (20, 3u16.to_le_bytes().to_vec()),
            (24, 48000u32.to_le_bytes().to_vec()),
            (40, u32::MAX.to_le_bytes().to_vec()),
        ] {
            let mut w = wav();
            w[offset..offset + bytes.len()].copy_from_slice(&bytes);
            assert!(validate_wav(&w).is_err());
        }
        assert!(validate_wav(&wav()[..43]).is_err());
        assert!(validate_wav(&vec![0; MAX_AUDIO_BYTES + 1]).is_err());
    }
    fn upstream(status: &str, response: String) -> (String, std::thread::JoinHandle<Vec<u8>>) {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!(
            "http://{}/v1/audio/transcriptions",
            listener.local_addr().unwrap()
        );
        let status = status.to_owned();
        let task = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut request = Vec::new();
            let mut buffer = [0; 4096];
            loop {
                let count = socket.read(&mut buffer).unwrap();
                assert!(count > 0);
                request.extend_from_slice(&buffer[..count]);
                assert!(request.len() < 16384);
                if let Some(end) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&request[..end]).to_ascii_lowercase();
                    let length: usize = headers
                        .lines()
                        .find_map(|l| l.strip_prefix("content-length: "))
                        .unwrap()
                        .parse()
                        .unwrap();
                    if request.len() >= end + 4 + length {
                        break;
                    }
                }
            }
            write!(socket, "HTTP/1.1 {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", status, response.len(), response).unwrap();
            request
        });
        (url, task)
    }
    #[tokio::test]
    async fn relay_uses_cohere_multipart_and_only_configured_upstream_credentials() {
        let (url, task) = upstream("200 OK", r#"{"text":" Bonjour. "}"#.into());
        let client = reqwest::Client::new();
        let result = forward(
            &client,
            &url,
            Some("upstream-test-token".into()),
            "fr".into(),
            Bytes::from(wav()),
        )
        .await
        .unwrap();
        assert_eq!(result.text, "Bonjour.");
        let request = task.join().unwrap();
        let text = String::from_utf8_lossy(&request);
        assert!(text.contains("authorization: Bearer upstream-test-token"));
        assert!(text.contains("cohere-transcribe"));
        assert!(text.contains("name=\"language\"\r\n\r\nfr"));
        assert!(text.contains("filename=\"dictation.wav\""));
        assert!(request.windows(wav().len()).any(|v| v == wav()));
    }
    #[tokio::test]
    async fn relay_bounds_response_and_hides_upstream_errors() {
        let client = reqwest::Client::new();
        for (status, body) in [
            ("503 Unavailable", "private upstream diagnostic".into()),
            ("200 OK", "x".repeat(65537)),
            ("200 OK", "{}".into()),
        ] {
            let (url, task) = upstream(status, body);
            let error = forward(&client, &url, None, "en".into(), Bytes::from(wav()))
                .await
                .err()
                .unwrap();
            assert_eq!(error.0, StatusCode::SERVICE_UNAVAILABLE);
            assert!(!error.1.contains("private"));
            let request = task.join().unwrap();
            assert!(!String::from_utf8_lossy(&request).contains("authorization:"));
        }
    }
}
