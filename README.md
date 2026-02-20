# Sinyalist

**Community earthquake early-warning and survivor-location prototype for Istanbul.**

> **LEGAL & SAFETY DISCLAIMER** — Sinyalist is a **community survivor-location relay prototype**, not a certified earthquake early-warning system. It is designed to help survivors report their location and status after a seismic event — not to predict or warn before one. It provides **no guarantee** of detection accuracy, message delivery, or response time. Do **not** present this system as an "erken uyarı sistemi" (early-warning system) to authorities or the public — use the framing **"vatandaş konum ve durum bildirimi" (citizen location/status relay)**. False alarms can cause panic and legal liability. Use at your own risk. The authors accept no liability for missed events, false alarms, delivery failures, or consequences of any system decision.

---

Sinyalist is a **citizen survivor-location relay** — after a seismic event, it lets survivors send their GPS location and status through a resilient multi-transport cascade: internet first, falling back to SMS, then BLE mesh. The system is designed to remain functional during and after infrastructure collapse. On-device seismic detection (STA/LTA with band-pass filtering and multi-device consensus) is used to auto-trigger the location relay, but is **not** a substitute for certified early-warning infrastructure.

## Architecture

```
 Android Device                          Cloud
 ┌─────────────────────────────┐      ┌──────────────────┐
 │  C++ Seismic Engine (NDK)   │      │  Rust Ingest API │
 │  ↓ 50 Hz accelerometer      │      │  - Ed25519 verify│
 │  ↓ STA/LTA + 4-stage reject │      │  - Dedup (LRU)   │
 │  Kotlin BLE Mesh Controller │  →→  │  - Rate limiting │
 │  - Priority queue           │ HTTP │  - Geo-cluster   │
 │  - SQLite persistence       │      │    confidence    │
 │  - Store-carry-forward      │      │  - Honest ACK    │
 │  Flutter UI + Delivery FSM  │      └──────────────────┘
 │  - Ed25519 signing          │
 │  - Internet → SMS → BLE     │
 └─────────────────────────────┘
```

## Components

| Directory | Language | Purpose |
|-----------|----------|---------|
| `sinyalist_app/lib/` | Dart/Flutter | UI, delivery state machine, SMS codec, Ed25519 keypair, connectivity cascade |
| `sinyalist_app/android/.../kotlin/` | Kotlin | BLE mesh controller, seismic engine bridge, foreground service, boot receiver |
| `sinyalist_app/android/.../cpp/` | C++17 | Seismic detector: adaptive STA/LTA with walk/elevator/drop rejection |
| `backend/` | Rust | Axum HTTP ingest server: signature verification, dedup, rate limiting, confidence scoring |
| `proto/` | Protobuf | `SinyalistPacket` (32 fields), `PacketAck`, `MeshRelay` message definitions |
| `tools/loadtest/` | Rust | Load test tool: generates signed packets at configurable rate |

## Tested With

| Tool | Minimum | Tested |
|------|---------|--------|
| Rust / cargo | 1.75 | 1.77 |
| Flutter | 3.19 | 3.22 |
| Android NDK | r25 | r26b |
| CMake | 3.22 | 3.22 |
| Android Gradle Plugin | 8.1 | 8.3 |
| Android API | 24 | 34 |

## Prerequisites

- **Flutter** >= 3.19 (stable channel)
- **Rust** >= 1.75 (with cargo)
- **Android SDK** (API 24+) with NDK r25+ and CMake 3.22+
- **PowerShell** or any terminal

## Quick Start

> **All commands below must be run from the repository root** (`D:\Sinyalist_v2_Field_Reliable\` or wherever you cloned the repo), not from inside `sinyalist_app\` or `backend\`.

### Backend

```powershell
# From repo root:
cd D:\Sinyalist_v2_Field_Reliable\backend   # adjust path as needed
$env:RUST_LOG = "info"
cargo run --release
# Server listens on http://localhost:8080
# Endpoints: POST /v1/ingest, GET /health, GET /ready, GET /metrics
```

### Flutter App (Android)

```powershell
# From repo root:
cd D:\Sinyalist_v2_Field_Reliable\sinyalist_app
flutter pub get
flutter run --dart-define=BACKEND_URL=http://192.168.1.50:8080   # Physical Android cihaz için
flutter run             # Emulator için (localhost köprüleme)
flutter build apk       # Release APK (android/key.properties gerekli)
```

### Flutter App (Web — limited)

```powershell
# From repo root:
cd D:\Sinyalist_v2_Field_Reliable\sinyalist_app
flutter run -d chrome   # Seismic engine and BLE mesh are Android-only on web
```

### Load Test Tool

```powershell
# From repo root:
cd D:\Sinyalist_v2_Field_Reliable\tools\loadtest
cargo run --release -- --url http://localhost:8080 --rate 100 --duration 30
```

### Run Tests

```powershell
# Backend (Rust) — from repo root:
cd D:\Sinyalist_v2_Field_Reliable\backend
cargo test -- --nocapture

# Flutter (Dart — SMS codec, CRC32, widget) — from repo root:
cd D:\Sinyalist_v2_Field_Reliable\sinyalist_app
flutter test
```

## Connectivity Cascade

The delivery state machine follows a deterministic fallback order:

1. **Internet** — HTTP POST to `/v1/ingest` with protobuf body. Exponential backoff (500 ms, 1 s, 2 s, 4 s, 8 s cap). Server returns `PacketAck` with confidence score.
2. **SMS** — Used only after internet fails **and** cellular signal is confirmed present. Compact binary payload: `SY1|<base64(38 bytes)>|<CRC32_hex>`. Fits in a single 160-char SMS. **SMS delivery is not guaranteed** — carrier infrastructure may fail during major seismic events (tower damage, congestion). No delivery confirmation is available. SMS is a best-effort last resort before BLE mesh.
3. **BLE Mesh** — Packets are broadcast via Bluetooth LE advertising and received by peers scanning in the background (connectionless flooding). For store-carry-forward relay, devices that come into contact exchange buffered packets over a GATT connection. Priority queue (TRAPPED > MEDICAL > SOS > STATUS > CHAT). SQLite persistence survives app restarts.

Every packet is Ed25519-signed before leaving the device. Unsigned packets never enter the outbox.

## Multi-Device Consensus

The backend will **not** forward packets to AFAD relay until at least **3 unique devices** (identified by distinct Ed25519 public keys) report from the same ~1 km geohash cell within the same 1-minute time bucket. This prevents a single malfunctioning phone from triggering a false alert. Individual packets are still accepted, stored, and ACKed — they simply don't trigger AFAD relay until consensus is reached.

The confidence score in `PacketAck` reflects the current cluster state (0.0–1.0). Clients can display this to users.

## Replay Protection

Packets with `created_at_ms` older than 5 minutes or more than 60 seconds in the future are rejected (HTTP 400). This prevents replaying captured SMS packets or delayed BLE-relayed packets from inflating the confidence score of a past event. The 5-minute window accommodates SMS carrier delay and multi-hop BLE latency.

## ACK Semantics

HTTP 200 with a `PacketAck` means the packet was **accepted into the ingest buffer**. It does **not** mean the packet has been persisted to disk or relayed to AFAD — those are asynchronous. If the persistence or relay channel overflows, the `backpressure` metric increments and that copy may be dropped. HTTP 503 with `Retry-After` is returned only when the primary ingest buffer itself is full.

Rejection codes:
- **HTTP 400** — malformed or oversized packet
- **HTTP 403** — Ed25519 signature missing, public key absent, or signature verification failed
- **HTTP 429** — rate limit exceeded (30/min per public key, or 500/min per ~1 km geohash cell)
- **HTTP 503** — primary ingest buffer full; retry after the indicated delay

## Security Model

- **Ed25519 signatures**: Per-install keypair generated on first launch. Every packet signed before transmission. Signing payload is the packet serialized to bytes with `ed25519_signature` (field 28) cleared/omitted; all other fields including the public key are included. Server verifies strictly; rejects unsigned or tampered packets (HTTP 403).
- **Rate limiting**: Client-side (5 sends / 30 seconds) and server-side (30/min per public key, 500/min per geohash bucket).
- **Dedup**: Server maintains LRU dedup map (5-minute TTL) keyed by `packet_id`. Duplicates return 200 but do not inflate confidence scores.
- **Confidence scoring**: Geo-cluster correlation within time windows. Confidence increases only with unique independently signed reports from distinct public keys.

## Limitations

| Limitation | Severity | Notes |
|------------|----------|-------|
| iOS background BLE | Critical | iOS cannot reliably advertise/scan BLE when backgrounded. Android ForegroundService is the only supported always-on mode. **Do not promise always-on BLE on iOS.** |
| GPS fallback to Istanbul | High | If GPS permission is denied or unavailable, `LocationManager` falls back to Istanbul city-centre coordinates with accuracy=999999 cm. Callers check `LocationSnapshot.isReal`; the UI should warn users when real GPS is unavailable. |
| SMS relay configuration required | Medium | Native `SmsManager` bridge is wired on Android. SMS fallback works only when `SMS_RELAY_NUMBER` is configured, `SEND_SMS` is granted, and cellular service is available. Delivery remains best-effort and unconfirmed. |
| Single backend instance | Medium | In-memory queue and dedup. Production needs PostgreSQL + Redis + load balancer. |
| Ed25519 key storage | Medium | Private key secure storage (Android encrypted storage/keystore-backed). Legacy SharedPreferences values otomatik migrate edilir. |

## Project Structure

```
sinyalist/
├── README.md
├── .gitignore
├── proto/
│   └── sinyalist_packet.proto
├── backend/
│   ├── Cargo.toml
│   ├── Cargo.lock
│   ├── build.rs
│   └── src/main.rs
├── sinyalist_app/
│   ├── pubspec.yaml
│   ├── lib/
│   │   ├── main.dart
│   │   ├── core/
│   │   │   ├── bridge/native_bridge.dart
│   │   │   ├── codec/sms_codec.dart
│   │   │   ├── connectivity/connectivity_manager.dart
│   │   │   ├── crypto/keypair_manager.dart
│   │   │   ├── delivery/
│   │   │   │   ├── delivery_state_machine.dart
│   │   │   │   └── ingest_client.dart
│   │   │   └── theme/sinyalist_theme.dart
│   │   └── screens/home_screen.dart
│   ├── test/
│   │   ├── sms_codec_test.dart
│   │   └── widget_test.dart
│   └── android/
│       └── app/src/main/
│           ├── kotlin/com/sinyalist/
│           │   ├── MainActivity.kt
│           │   ├── SinyalistApplication.kt
│           │   ├── core/SeismicEngine.kt
│           │   ├── mesh/
│           │   │   ├── NodusMeshController.kt
│           │   │   └── MeshPacketStore.kt
│           │   └── service/
│           │       ├── SinyalistForegroundService.kt
│           │       └── BootReceiver.kt
│           └── cpp/
│               ├── CMakeLists.txt
│               ├── seismic_detector.hpp
│               └── seismic_jni_bridge.cpp
├── tools/
│   └── loadtest/
│       ├── Cargo.toml
│       └── src/main.rs
└── docs/
    ├── ARCHITECTURE.md
    ├── TESTING.md
    └── archive/
        └── UPGRADE_REPORT_v2.md
```

## License

This project is not yet under a formal open-source license. All rights reserved by the author. Contact the maintainer before distributing or modifying.
