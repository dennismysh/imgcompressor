# Sigil tANS Entropy Coder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Rice-Golomb entropy coding with rANS (range-based Asymmetric Numeral Systems) in the Sigil codec to dramatically improve compression on high-entropy photographic content. Format version bumps from v0.2 to v0.3.

**Architecture:** New `Sigil.Codec.ANS` module in `sigil-hs` implements both encode and decode using rANS with cumulative-frequency symbol lookup. The pipeline bypasses tokenization entirely — tANS encodes zigzag-encoded Word16 residuals directly. A corresponding decode-only `ans.rs` module is added to `sigil-rs`. The SDAT payload format changes to carry a frequency table + ANS bitstream instead of Rice-coded token blocks.

**Tech Stack:** Haskell (Stack, lts-22.43, GHC 9.6.6), Rust (stable), wasm-pack

**Spec:** `docs/superpowers/specs/2026-03-30-sigil-tans-entropy-coder-design.md`

---

See the full spec and agent output for complete task details. 11 tasks:

### Task 1: ANS Module — Frequency Table + Normalization (TDD)
### Task 2: ANS Module — Encode (TDD)
### Task 3: ANS Module — Decode (TDD)
### Task 4: ANS Full Round-Trip Validation
### Task 5: Pipeline Integration — Replace Rice with ANS
### Task 6: Version Bump — Writer/Reader to v0.3
### Task 7: Regenerate Golden Files + Full Test Pass
### Task 8: Criterion Benchmarks Update
### Task 9: Rust Decoder — ANS Decode + Pipeline Update
### Task 10: WASM Rebuild + Static Files
### Task 11: Smoke Test — Full Stack Validation
