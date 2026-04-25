---
"hex-app": minor
---

Add experimental Live Transcription mode. Toggle it on under Settings > General to stream text into whatever text field has focus while you hold the hotkey, instead of waiting for the full transcript to paste at the end. Built on FluidAudio's Parakeet EOU streaming ASR with per-chunk partial hypotheses, a pure reconciliation engine in HexCore, and an Accessibility-first text injection adapter that falls back to CGEvent character injection. Requires a one-time ~250 MB EOU model download (separate from the Parakeet TDT v3 used in batch mode) on first hotkey press, and the standard Accessibility permission Hex already requests.
