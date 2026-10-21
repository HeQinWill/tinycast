# Dictation

Dictation is off by default. A user-selected global shortcut records from the chosen microphone,
transcribes speech via an online multimodal audio LLM (such as AskDianDian dots3 or OpenAI-compatible
audio models), and delivers the recognized text through `TextInjector`.

Users can configure multiple profiles in Settings with custom names, base URLs, model identifiers,
system prompts, user prompts, audio formats (M4A or WAV), and optional thinking suppression (`chat_template_kwargs: { "enable_thinking": false }`).
API keys are stored securely in the system Keychain under the `dictation-api-keys` scope.
While dictating, the floating panel displays the active profile, which can be cycled with Up/Down arrow
keys or by clicking the profile pill.

## Invariants

- `AppCore` owns the profile store, online service, and coordinator. The microphone session, panel, and
  focused target belong only to `DictationCoordinator`; no recording starts merely by launching Tinycast
  or opening Settings.
- The enable switch is consent. It explains microphone and Accessibility access before enabling,
  and is excluded from backups so importing settings cannot arm a global recording shortcut.
- Microphone status appears in Permissions and the Dictation pane. Neither pane prompts on display;
  only a user action requests access, while revoked access is refreshed from macOS.
- `HotKeyAction.dictation` uses the shared recorder and conflict handling. Toggle mode accepts any
  binding; hold-to-talk accepts a Carbon chord or a single physical modifier, including Globe.
  Modifier holds begin after 250 ms alone and reserve their key across single and double taps.
  Another modifier, key or click cancels the hold without inserting text. Double taps require toggle.
- Carbon or the shared modifier monitor reports release to stop a held recording. Return finishes,
  Escape cancels. Opening a shortcut recorder cancels a held recording before pausing its shortcuts.
  A session token prevents a cancelled or superseded transcription from inserting text later.
- AI Chat's composer mic is always click-to-toggle into that field: `toggle(into:)` targets its
  `ComposerTextView` in process whatever has focus, `field` tells only that button it is running, and
  its transcript is inserted whatever the destination setting, never copied.
  Switching chats or closing the composer cancels only the session targeting that editor, including
  one started by a shortcut. The session token is checked again when queued insertion runs.
- The nonactivating panel preserves the target app. Text insertion reuses `TextInjector`, including
  its temporary clipboard ownership, focus, secure-input and protected-target checks. Copy-only
  writes the plain transcript without reading the caret; paste-and-copy writes the persistent copy
  after delivery or a failed insertion.
- The Liquid Glass capsule displays 21 fixed frequency bands driven by the microphone, sampled at
  most 20 times per second through a reused 512-point Accelerate transform on the capture queue.
  Logarithmic bands span 32–5000 Hz so speech sits nearer the middle. Smoothed levels taper and
  fade only toward the edges, without a center peak or mirroring.
  Transcription replaces them with a smaller wave whose white center fades to gray, moving left to
  right at up to 30 frames per second.
  Reduce Motion pauses the processing timeline; closing the panel releases its hosting view so no
  animation continues while hidden.
- Dictation fades the default output's software volume down by about 90% from shortcut press, then restores
  it on completion, cancellation and normal quit. An unsupported output is left untouched, as is a
  volume the user changes during capture. Before each fade step, a bundle-ID Application Support
  file records the device UID, original volume and the values before and after that step.
  Relaunch restores the original device only if its volume still matches that record, including
  when Dictation is disabled. An unavailable device keeps its record for a later attempt; new ducking
  waits for that recovery. File writes run off-main and finish before the hardware changes.
- Audio stays in memory, bounded to five minutes of mono 16 kHz Float32 samples. Recordings are encoded
  on finish by `DictationAudioEncoder` into M4A (AAC) or WAV (PCM) and packaged as base64 data URIs
  for transmission over HTTPS.
- Network requests use a private ephemeral session (`urlCache = nil`) with explicit timeouts and cancellation.
  No audio is persisted to disk.
- LLM reasoning/thinking tags (`<think>...</think>`) in completions are stripped automatically
  by `DictationOnlineService` prior to contextual text formatting.
- The `Model/` folder imports Foundation only. Context-sensitive spaces and capitalization are a
  pure decision driven by text around the caret. Capitalization adapts by default and can be disabled
  without disabling contextual spaces; if an app does not expose that context through
  Accessibility, the plain transcript is inserted without guessing.

## Validation

- `dictation-online-test` checks endpoint normalization, WAV and M4A audio encoding, think-tag stripping,
  profile management, profile cycling, and Keychain API key lifecycle.
- `dictation-field-test` checks composer switching and teardown, scoped cancellation, and delayed insertion
  with synthetic capture and real AppKit editors, without touching the shared clipboard.
- `dictation-test` checks text formatting, contextual spacing, capitalization adaptation, and echo stripping.
- `dictation-volume-test` uses private files and injected audio controls to verify crash recovery
  before and after fade steps, user volume changes, output switching, failed writes and rapid cancellation.
