# iOS dictation

Conversation/new-agent composers and inline Inbox replies use the same microphone control. Tap to record; stop or the upward arrow transcribes into the existing draft, without sending a message. Cancel discards audio. Hold the microphone to select one of Cohere's 14 languages (shared setting). The capsule displays measured microphone levels and elapsed time. Maximum recording length is 120 seconds.

The iPhone records mono 16 kHz, 16-bit PCM WAV. No recognition model is installed on the phone. After recording, the app uploads audio over its authenticated Orb connection to `POST /api/voice/transcribe?language=fr`. Core sends multipart `model=cohere-transcribe`, `response_format=json`, `language` and `file` to the Spark GPU router. No Spark credentials or address are shipped to iOS. Audio is not saved by Core; the client deletes its temporary recording after success/cancellation. Failed transcription retains the recording for retry only while the composer remains open.

The microphone permission string explains remote transcription. Leaving the composer, entering background, or an audio interruption cancels and fences late responses. A microphone permission dialog may temporarily make the scene inactive; this must not cancel permission acquisition. The existing draft stays intact.

Audio route-change and interruption notifications are delivered to composer observers on the main queue before accessing SwiftUI or `OrbDictation` state. System audio notifications can originate on a secondary thread; invoking a MainActor callback directly can crash under Swift 6. Regression coverage posts both notifications from a background queue and exercises real microphone permission and recorder startup in the simulator, alongside the deterministic transcription fixtures.

## Server configuration

- `SANDBOXED_VOICE_TRANSCRIPTION_URL`: trusted upstream endpoint; default `http://100.77.4.93:8000/v1/audio/transcriptions`, reachable from Core over Tailscale.
- `SANDBOXED_VOICE_TRANSCRIPTION_TOKEN`: optional upstream bearer token; never forwarded to the client. The client's Orb JWT is never forwarded upstream.

The existing Spark `dgx-router` forwards `/v1/audio/*` to Cohere Transcribe on localhost:8002 under its foreground GPU lock. Do not bypass the router, reload models, or restart chat/ASR inference to test iOS.

The endpoint requires normal Core authentication, accepts only bounded PCM WAV (4 MiB / 120 s recording plus one second of audio-frame timing tolerance), permits two simultaneous requests, times out after 90 seconds, does not follow redirects and bounds the transcript response to 64 KiB. Busy or unavailable upstreams return a retryable error without exposing upstream response bodies/credentials.
