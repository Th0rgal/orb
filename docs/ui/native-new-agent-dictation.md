# Native New Agent dictation

The Wayland client offers a microphone in a connected New Agent draft when the
packaged Python interpreter, worker script and PulseAudio-compatible capture
utility are available. Opening the window, probing availability, focusing the
button and hovering over it must never start capture.

The worker's protocol-v1 `hello` supplies model readiness and supported
language codes. The client intersects those codes with Orb’s voice language
catalog. It prefers the shared `orb.voiceLang` setting, then the first
supported desktop locale, then English. If the model lacks English it uses
the first compatible catalog entry. A fallback never overwrites a saved choice.

The language code beside the microphone opens a GTK radio list when Zenity
is available. Confirming a choice updates only `orb.voiceLang` in the shared
desktop preferences. Closing the list keeps the current preference. Each
recording rechecks the selected language against the current model before
opening audio.

Click the microphone or focus it with Tab and press Enter or Space to record.
The check button finishes capture. The close button and Escape discard a
recording or pending transcription. Leaving the draft or changing connections
invalidates its result, including when a fresh New Agent draft replaces it.

The configured Orb worker receives a local mono 16 kHz PCM WAV through its
existing stdio protocol. Audio is bounded to two minutes. The transcript enters
the active draft at its current Unicode caret as one undoable edit. Sending
requires a separate action.

The macOS desktop uses the existing web composer and locald voice RPC.

### Native New Agent draft viewport

At 1000 × 700, entering 20 short lines grows the editor to 180 logical pixels.
Further rows scroll inside that rectangle. The attachment, configuration, voice,
and send controls stay below it and retain their pointer targets and tab order.
The editor follows the insertion line on edits and keyboard navigation, using
the same shaped word wraps as the displayed text. Moving back through the draft
reveals earlier rows. Up and Down move one displayed row per keypress and retain
the preferred horizontal position across short or empty rows. A wheel gesture
inside the editor scrolls the text independently of the insertion point. It
preserves focus and toolbar position. The next edit or cursor move reveals
the caret again. IME preedit participates in the viewport calculation.
Enter submits the entire committed draft, including text outside the viewport.
