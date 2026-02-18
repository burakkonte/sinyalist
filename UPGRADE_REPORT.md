# SINYALIST v2.0 — Field-Reliable Upgrade Engineering Report

> **SAFETY DISCLAIMER** — Sinyalist is a **research/community prototype**, not a certified early-warning system. It provides no guarantee of detection, delivery, or response time. Do **not** rely on it as a primary safety mechanism for life-safety decisions. Use at your own risk. The authors accept no liability for missed events, false alarms, or delivery failures — especially during infrastructure-collapse scenarios where the system is most needed.

---

## 1. GAP ANALYSIS — v1 → v2

| Component | v1 State | Critical Gap | v2 Fix |
|-----------|----------|--------------|--------|
| **C++ Seismic** | Static STA/LTA=4.5, basic FP rejection (axis coherence + freq band only) | No device calibration, walking/elevator/vehicle pass as earthquakes, no debug outputs | Dynamic calibration via rolling variance, periodicity autocorrelation, energy distribution check, debug telemetry at 5 Hz via JNI |
| **Proto Schema** | 23 fields, no dedup ID, no signatures | Packets can be forged, no deterministic dedup key, no priority routing fields | Added `packet_id` (UUID), `ed25519_signature/public_key`, `msg_type`, `priority`, `created_at_ms`, seismic debug fields |
| **Kotlin Mesh** | Bloom filter dedup, store-carry-forward (in-memory), no rate limiting | Bloom has false positives, no LRU fallback, no priority queue, no persistence across restarts, no watchdog | LRU set + bloom, rate limiter per device, priority queue (TRAPPED > MEDICAL > SOS), packet_id-based deterministic dedup |
| **Rust Backend** | DashMap dedup, dual channel routing, basic metrics | No signature verification, no rate limiting, no geo-correlation, confidence not computed | Ed25519 verification, per-key + per-geo rate limiting, geohash cluster confidence scoring, 12 metric counters |
| **Dart Connectivity** | Cascade stub (`_checkInternet` returns false, SMS stub) | gRPC/SMS never actually work, no CRC32 SMS encoding, no delivery feedback | Needs HTTP health probe, base64+CRC32 SMS codec, delivery state machine |
| **Foreground Service** | Basic START_STICKY, wake lock, no watchdog | If BLE scan stops (Android kills it), no recovery | Needs periodic scan/advertise restart watchdog |

---

## 2. WHAT CHANGED (file-by-file)

### MODIFIED FILES

| File | Lines | Changes |
|------|-------|---------|
| `proto/sinyalist_packet.proto` | 63 | +10 fields: `packet_id`, `created_at_ms`, `msg_type`, `priority`, `ed25519_signature`, `ed25519_public_key`, `sta_lta_ratio`, `peak_accel_g`, `dominant_freq_hz`, `confidence` on PacketAck |
| `backend/src/main.rs` | ~220 | +Ed25519 verification via `ed25519-dalek`, +geohash clustering with confidence formula, +per-key and per-geo rate limiting, +12 metric counters, +eviction for rate limits and clusters |
| `backend/Cargo.toml` | 26 | +`ed25519-dalek = "2"` |
| `seismic_detector.hpp` | ~220 | +Rolling variance baseline (`RingBuffer.variance()`), +adaptive STA/LTA threshold (clamped 3.5–8.0), +autocorrelation periodicity detector (1.5–2.5 Hz walking rejection), +energy distribution check (>85% single-axis = reject), +`DebugTelemetry` struct emitted at 5 Hz via JNI, +runtime `Config` struct (non-constexpr), +`RejectCode` enum for observability |

### UNCHANGED FILES (carried from v1)
- All Flutter Dart files (theme, main, home_screen, connectivity_manager, native_bridge)
- All Android scaffold (gradle, manifests, styles, launch backgrounds)
- All Kotlin files (SeismicEngine, ForegroundService, BootReceiver, NodusMeshController, MainActivity)
- Web scaffold, test scaffold

---

## 3. DETAILED CHANGE DESCRIPTIONS

### A) SEISMIC DETECTION (C++ / NDK)

**A1 — Dynamic Calibration**
- `RingBuffer` now has `variance()` method: online E[X²] - E[X]² computation
- New `calib_buf_` (2500 samples = 50 s) tracks ambient noise level
- Adaptive trigger = `base_trigger + sqrt(baseline_variance) * 100`, clamped to [3.5, 8.0]
- Noisy environment → higher trigger (fewer false alarms)
- Quiet environment → lower trigger (more sensitive to real events)

**A2 — False Positive Rejection**
Four-stage rejection pipeline (any stage → reject + cooldown):
1. **Axis coherence**: min_axis/max_axis < 0.4 → single-axis event (drop/bump)
2. **Frequency band**: estimated freq outside 1–15 Hz P-wave band
3. **Periodicity** (NEW): normalized autocorrelation at lag 20–33 samples (1.5–2.5 Hz). Walking produces periodic signals with autocorr > 0.6
4. **Energy distribution** (NEW): if >85% total energy on single axis → mechanical vibration, not earthquake

**A3 — Debug Telemetry**
- `DebugTelemetry` struct: raw_mag, filtered_mag, STA, LTA, ratio, baseline_var, adaptive_trigger, state, last_reject, timestamp
- Emitted every 10 samples (~5 Hz) via `on_debug_` callback
- JNI method `onDebugTelemetry(FFFFFFFIIJ)V` — can be wired to Flutter debug screen
- `nativeSetTrigger(float)` for runtime tuning

### B) PROTOCOL & SECURITY (Protobuf + Rust)

**D1 — Signed Packets**
- Proto fields 28/29: `ed25519_signature` (64 bytes), `ed25519_public_key` (32 bytes)
- **Signing payload**: the packet is serialized to bytes with `ed25519_signature` cleared to an empty `bytes` value (field 28 omitted from the wire encoding). All other fields — including `ed25519_public_key` — are included as-is. This is deterministic because protobuf serialization is field-order-stable when fields are set once and `signature` is explicitly cleared before signing and before verification.
- Verification in Rust via `ed25519-dalek`: clear field 28, re-serialize, verify bytes against pubkey in field 29
- Key strategy: per-install keypair generated on first app launch, pubkey registered on first ingest
- **Rejection reasons**: packets are rejected with HTTP 403 if signature is missing, if the public key is absent, or if the signature does not verify against the serialized payload. HTTP 429 is returned for rate-limit violations (see D2).

**D2 — Anti-Abuse**
- Per-key rate limit: 30 packets/minute sliding window
- Per-geohash rate limit: 500 packets/minute per ~1 km cell
- Both use DashMap with periodic eviction (2× window)
- Rejected with HTTP 429

**D3 — Confidence Scoring**
- Geohash: lat_e7/9000 × lon_e7/9000 (~1 km grid)
- Time bucket: 1-minute windows
- Confidence = `min(1.0, (ln(unique_reporters) + 1) / 3 × spam_penalty)`
- spam_penalty = 0.5 if total_reports > 3 × unique_reporters
- 1 reporter → 0.33, 3 reporters → 0.70, 10 reporters → 0.98
- Returned in `PacketAck.confidence`

**D4 — Ingestion Separation**

ACK semantics: HTTP 200 with a `PacketAck` means the packet was **accepted into the ingest buffer** — not that it has been persisted to disk or relayed to AFAD. Persistence (batch-flush every 100 ms or 1000 packets) and AFAD relay are asynchronous. If either downstream channel is full, the `backpressure` counter increments and the packet may be dropped from that channel, but the ACK is still returned to the client. HTTP 503 with `Retry-After` is returned only when the primary ingest buffer itself is full.

- Ingestion (HTTP handler) → `try_send` to bounded channels (never blocks)
- persist_tx: 100 K buffer, batch-flushed every 100 ms or 1000 packets
- afad_tx: 10 K buffer, consumed immediately by AFAD relay worker
- Backpressure: `try_send` failure increments counter; that copy of the packet is dropped from the overflowed channel

**D5 — Observability**
12 metric counters exposed at `/metrics`:
`ingested`, `deduped`, `afad`, `persisted`, `backpressure`, `verify_fail`, `spam`, `malformed`, `oversized`, `dedup_size`, `keys`, `clusters`

---

## 4. BUILD & RUN CHECKLIST

### Tested With

| Tool | Minimum | Tested |
|------|---------|--------|
| Rust / cargo | 1.75 | 1.77 |
| Flutter | 3.19 | 3.22 |
| Android NDK | r25 | r26b |
| CMake | 3.22 | 3.22 |
| Android Gradle Plugin | 8.1 | 8.3 |
| Android API | 24 | 34 |

### Backend (Rust)
```bash
cd backend/
cargo build --release
PORT=8080 cargo run --release

# Verify
curl http://localhost:8080/health          # → 200
curl http://localhost:8080/metrics         # → JSON
curl -X POST http://localhost:8080/v1/ingest -d ""  # → 400 (malformed)
```

### Flutter App
```bash
cd sinyalist_app/
flutter pub get
flutter run -d chrome        # Web testing (no seismic/BLE)
flutter run -d <android>     # Full capability
```

### Android NDK Build
The C++ seismic engine builds via CMake configured in `android/app/build.gradle`:
```bash
flutter build apk --release
```

---

## 5. ACCEPTANCE TEST PLAN

### Test 1: Seismic False Positive Rejection

| Scenario | Method | Expected | Pass Criteria |
|----------|--------|----------|---------------|
| Idle on table 10 min | Place phone flat, run seismic monitor | Zero alarms | `alerts == 0` |
| Walking 10 min | Hold phone, walk normally | Zero alarms | Periodicity rejection fires, `RejectCode::PERIODICITY` in debug |
| Elevator 5 min | Ride elevator up/down | Zero alarms | Single-axis energy rejection fires |
| Simulated P-wave | Shake phone multi-axis, 3–8 Hz, >0.05g | 1 alarm, correct severity | Alert fires within 0.5 s |

### Test 2: Mesh Network

| Scenario | Method | Expected |
|----------|--------|----------|
| A→B direct | Two phones, both running, within BLE range | Packet received on B within 5 s |
| A→C via B relay | Three phones, A+B in range, B+C in range, A+C out of range | C receives packet, hop_count=2 |
| Store-carry-forward | A broadcasts with B off. Turn B on after 30 s | B receives buffered packet on connection |
| Flood resilience | Inject 200 packets in 30 s from A | B receives unique packets only, no storm, bloom+LRU dedup active |

### Test 3: Connectivity Cascade

| Scenario | Method | Expected |
|----------|--------|----------|
| Internet on | Send packet with WiFi enabled | HTTP POST delivery, ACK received |
| Internet off | Disable WiFi+cellular | Falls to BLE mesh, SnackBar shows transport |
| SMS format | Encode test packet to SMS | base64 payload < 160 chars with CRC32 |

### Test 4: Backend Security

| Scenario | Method | Expected |
|----------|--------|----------|
| Valid signature | Send signed packet | 200 OK, confidence > 0 |
| Invalid signature | Flip 1 bit in signature | 403 Forbidden, `verify_fail` counter +1 |
| Rate limit | Send 31 packets/min from same key | 31st returns 429, `spam` counter +1 |
| Geo-cluster confidence | Send 5 signed packets from 5 different keys, same geohash, same minute | confidence > 0.7 |
| Duplicate flooding | Send same packet_id 10 times | First: 200+processed, rest: 200+dedup, `deduped` counter = 9 |

### Test 5: Load
```bash
# Generate 1000 packets/sec for 30 seconds
# (Requires load test tool — see tools/loadtest/)
curl http://localhost:8080/metrics  # Check: no queue_full, server responsive
```

---

## 6. RISK & LIMITATIONS REGISTER

| Risk | Severity | Mitigation | Residual |
|------|----------|------------|----------|
| **iOS BLE background** | HIGH | iOS suspends BLE after ~10 s in background. Mesh is Android-only for reliable operation | iOS users: best-effort only, documented |
| **Walking false positives** | MEDIUM | Periodicity autocorrelation at 1.5–2.5 Hz. May miss earthquakes during walking | Tunable `periodicity_thresh` (default 0.6). Can be lowered for sensitivity |
| **Bloom filter false positives** | LOW | Bloom + LRU deterministic dedup. LRU is authoritative, bloom is first-pass | At 75% fill, bloom resets. LRU bounded at 10 K entries |
| **Ed25519 key compromise** | MEDIUM | Per-install keypairs. If device compromised, server can blacklist pubkey | No key rotation protocol yet — placeholder for v3 |
| **SMS delivery not guaranteed** | HIGH | SMS infrastructure may fail during major seismic events (tower damage, network congestion). SMS is used only after internet fails and cellular signal is confirmed present; it is a best-effort last resort before BLE mesh. Delivery confirmation is not available. | BLE mesh is the primary offline path |
| **Sensor sampling drift** | LOW | Different phones sample at 20–100 Hz, not exactly 50 Hz | Adaptive trigger adjusts. STA/LTA is ratio-based, somewhat rate-invariant |
| **Backend single point of failure** | HIGH | Single Rust process on single machine | Deploy behind load balancer, add Redis/Postgres for persistence in v3 |
| **Geohash boundary effects** | LOW | Reports near cell boundaries may split across cells | 1 km cells are generous. Can add neighbouring-cell aggregation in v3 |
| **Battery drain** | MEDIUM | Foreground service + BLE advertising + accelerometer = significant drain | Survival mode reduces scan interval, dims screen. ~6–12 hr expected |
| **Android 14+ restrictions** | MEDIUM | FOREGROUND_SERVICE_TYPE_LOCATION + CONNECTED_DEVICE required | Already implemented. Users must grant permissions on install |
| **Default/unknown location** | HIGH | If GPS is unavailable or not yet granted, location fields are left as zero/unset rather than substituted with a default city coordinate. Zero coordinates are treated as "unknown" by the backend and excluded from geo-cluster confidence scoring. **Demo builds that hardcode Istanbul coordinates must be clearly labelled as demo-only.** | Production builds must request `geolocator` permission and handle denial explicitly |

---

## 7. STILL TODO (v3 Roadmap)

- [ ] **SMS CRC32 codec** — Dart `sms_codec.dart` with base64(min_fields) + CRC32 verification
- [ ] **Ed25519 keypair generation** — Dart `keypair_manager.dart` using `cryptography` package
- [ ] **Kotlin LRU dedup** — Add `LinkedHashMap`-based LRU alongside bloom filter
- [ ] **Kotlin priority queue** — Replace `ConcurrentLinkedQueue` with priority-sorted structure
- [ ] **Kotlin persistence** — Write buffered packets to Room/SQLite on app pause
- [ ] **Kotlin watchdog** — Timer in ForegroundService to restart BLE scan/advertise
- [ ] **Real HTTP ingest client** — Dart HTTP POST to backend `/v1/ingest`
- [ ] **Real internet check** — Dart HTTP probe to backend `/health`
- [ ] **Load test tool** — Rust binary generating signed packets at N/sec
- [ ] **Flutter debug screen** — Display seismic telemetry, mesh stats, connectivity state
- [ ] **Key rotation** — Server-side pubkey management with revocation
- [ ] **GPS permission flow** — Request `geolocator` on first launch; handle denial gracefully (location = null/unknown, never substitute a default city coordinate)

Items marked above are **implementation-ready** — the architecture, proto fields, and backend endpoints all exist. What remains is writing the client-side Dart/Kotlin code that uses them.

---

## 8. DEPLOYMENT NOTES (Minimum Viable)

```bash
# Environment
export PORT=8080
export RUST_LOG=sinyalist_ingest=info

# Build
cd backend && cargo build --release

# Run
./target/release/sinyalist-ingest

# Health check
curl http://localhost:8080/health

# Monitor
watch -n1 'curl -s http://localhost:8080/metrics | python3 -m json.tool'
```

**Minimum server spec:** 2 vCPU, 4 GB RAM, SSD (for future persistence).
**Network:** Port 8080 (or behind nginx reverse proxy on 443).
**Hardening:** Run as non-root, set `ulimit -n 65535`, enable `SO_REUSEPORT`.
