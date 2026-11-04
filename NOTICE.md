# Notices

Yaptype is licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE): free to use, modify and share
for personal, non-commercial purposes.

It builds on the following, each under its own license (not redistributed in this package; downloaded by you):

- FluidAudio (Swift, CoreML speech models) — Apache License 2.0 — https://github.com/FluidInference/FluidAudio
- NVIDIA Parakeet TDT 0.6B v2/v3 and Parakeet CTC 110M (CoreML conversions by FluidInference) — CC-BY-4.0 (NVIDIA)
- NemoTextProcessing (FluidInference/text-processing-rs) — Apache License 2.0 — https://github.com/FluidInference/text-processing-rs

Text polishing uses the OpenRouter API with your own key. Transcripts are sent to OpenRouter only when a key is
configured, and their handling is governed by OpenRouter's terms and the selected model provider's policies.
No audio is sent.
