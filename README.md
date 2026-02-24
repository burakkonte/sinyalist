# Sinyalist v2

> **LEGAL & SAFETY DISCLAIMER** — Sinyalist is a **community survivor-location relay prototype**, not a certified earthquake early-warning system. It is designed to help survivors report their location and status after a seismic event — not to predict or warn before one. It provides **no guarantee** of detection accuracy, message delivery, or response time. The authors accept no liability for missed events, false alarms, delivery failures, or consequences of any system decision.

**Vatandaş konum ve durum bildirimi** — Citizen location/status relay for earthquake survivors.
Multi-transport cascade: **Internet → SMS → BLE Mesh** (Android) · **Internet → BLE Mesh** (iOS).
Fully functional on both **Android** (Kotlin + C++ NDK) and **iOS** (Swift + CoreMotion + CoreBluetooth).

---

## App Preview

```
╔═══════════════════════════════════════╗
║         Sinyalist  v2.0               ║
║    Vatandaş Konum & Durum Bildirimi   ║
╠═══════════════════════════════════════╣
║                                       ║
║  Sismik Motor          ● Aktif        ║
║  STA/LTA Oran:          1.47          ║
║  Tepe İvme:             0.018 g       ║
║  Durum:            [ TEMKİN ]         ║
║                                       ║
╠═══════════════════════════════════════╣
║                                       ║
║  Bağlantı Kaskadı                     ║
║  ✅  İnternet (WiFi)   → 87 ms        ║
║  ──  SMS               (bekleme)      ║
║  ✅  BLE Mesh          4 düğüm        ║
║                                       ║
╠═══════════════════════════════════════╣
║                                       ║
║  Konum: 41.0082°N  28.9784°E          ║
║  Doğruluk: ±12 m · Kat: 3            ║
║  Güven Skoru:  ████████░░  0.72       ║
║                                       ║
║  ┌─────────────────────────────────┐  ║
║  │     HAYATTA KALMA MODUNU AÇ    │  ║
║  └─────────────────────────────────┘  ║
╚═══════════════════════════════════════╝
```

---

## Platform Support

| Feature | Android | iOS |
|---------|:-------:|:---:|
| Seismic Detection | ✅ C++ NDK · STA/LTA · 50 Hz | ✅ Swift · CoreMotion · 50 Hz |
| BLE Mesh (foreground) | ✅ Connectionless BLE 5.0 + GATT | ✅ CoreBluetooth GATT |
| BLE Mesh (background) | ✅ ForegroundService | ✅ GATT · CLLocationManager keep-alive |
| SMS Relay | ✅ Native SmsManager | ❌ Apple restriction — graceful fallback |
| Foreground Service | ✅ Android ForegroundService | ✅ CLLocationManager significant-change |
| Cross-platform Mesh | ✅ | ✅ Same GATT UUIDs |
| Ed25519 Signing | ✅ Keystore-backed | ✅ iOS Keychain |
| Store-carry-forward | ✅ SQLite (Kotlin) | ✅ SQLite C API (Swift) |

---

## Architecture

```
 Android Device                    iOS Device                    Cloud
 ┌────────────────────┐           ┌────────────────────┐       ┌────────────────────┐
 │ C++ Seismic Engine │           │ Swift SeismicEngine │       │  Rust Ingest API   │
 │ 50 Hz · STA/LTA   │           │ CoreMotion · STA/LTA│       │                    │
 │ 4-stage rejection  │           │ 4-stage rejection   │       │  Ed25519 verify    │
 ├────────────────────┤           ├─────────────────────┤  ──►  │  Dedup (LRU)       │
 │  Kotlin BLE Mesh   │ ◄──BLE──► │  Swift BLE Mesh     │  HTTP │  Rate limiting     │
 │  Priority queue    │           │  GATT Central+Periph│       │  Geo-cluster score │
 │  SQLite persist    │           │  SQLite persist      │       │  Honest ACK        │
 ├────────────────────┤           ├─────────────────────┤       └────────────────────┘
 │  Flutter UI        │           │  Flutter UI          │
 │  Internet→SMS→BLE  │           │  Internet→BLE        │
 │  Ed25519 sign      │           │  Ed25519 sign        │
 └────────────────────┘           └─────────────────────┘
```

**Cascade order:**
- **Android**: Internet → SMS → BLE Mesh (3 layers)
- **iOS**: Internet → BLE Mesh (2 layers — Apple prohibits programmatic SMS)
- **Cross-platform**: Android ↔ iOS devices see each other as BLE mesh peers via shared GATT Service UUID

---

## Components

| Directory / File | Language | Purpose |
|-----------------|----------|---------|
| `sinyalist_app/lib/` | Dart/Flutter | UI, delivery FSM, SMS codec, Ed25519 keypair, connectivity cascade |
| `sinyalist_app/android/.../kotlin/` | Kotlin | BLE mesh (connectionless + GATT), seismic bridge, foreground service, boot receiver |
| `sinyalist_app/android/.../cpp/` | C++17 | Seismic detector: adaptive STA/LTA, biquad filter, 4-stage FP rejection |
| `sinyalist_app/ios/Runner/SinyalistSeismicEngine.swift` | Swift | CoreMotion 50 Hz, STA/LTA port, 4-stage rejection, FlutterStreamHandler |
| `sinyalist_app/ios/Runner/SinyalistMeshController.swift` | Swift | CoreBluetooth GATT Central+Peripheral, priority queue, SQLite, FlutterStreamHandler |
| `sinyalist_app/ios/Runner/SinyalistBackgroundManager.swift` | Swift | CLLocationManager keep-alive, BGTaskScheduler, survival notification |
| `sinyalist_app/ios/Runner/AppDelegate.swift` | Swift | FlutterImplicitEngineDelegate, all 7 Flutter channels |
| `backend/` | Rust | Axum HTTP ingest server: signature verify, dedup, rate limit, confidence scoring |
| `proto/` | Protobuf | `SinyalistPacket` (32 fields), `PacketAck` (7 fields), `MeshRelay` |
| `tools/loadtest/` | Rust | Signed packet load test generator |

---

## Connectivity Cascade

The delivery state machine follows a deterministic fallback order:

**Android (3 layers):**
1. **Internet** — HTTP POST to `/v1/ingest`. Exponential backoff (500 ms → 8 s cap). Returns `PacketAck` with confidence score + `ingest_id` + `status`.
2. **SMS** — Only after internet fails AND cellular signal confirmed. Binary payload: `SY1|<base64(38 bytes)>|<CRC32_hex>` — fits in one 160-char SMS. Best-effort, no delivery confirmation.
3. **BLE Mesh** — Store-carry-forward via priority queue. TRAPPED > MEDICAL > SOS > STATUS > CHAT. SQLite persistence survives app restarts. TTL = 1 hour.

**iOS (2 layers):**
1. **Internet** — Same as Android.
2. **BLE Mesh** — GATT-based (Central + Peripheral). Background advertising via CLLocationManager keep-alive. Cross-platform: Android and iOS mesh peers discover each other via the same GATT Service UUID.

Every packet is **Ed25519-signed** before transmission. Unsigned packets are never added to the outbox.

---

## Multi-Device Consensus

The backend does **not** forward to AFAD relay until at least **3 unique devices** (distinct Ed25519 public keys) report from the same ~1 km geohash cell within the same 1-minute time bucket. This prevents a single malfunctioning device from triggering a false relay.

```
Confidence formula:
  unique = distinct public keys in cell × time bucket
  spam_factor = 0.5 if total_reports > 3 × unique, else 1.0
  confidence = min(1.0, (ln(unique) + 1) / 3 × spam_factor)

  1 device  → 0.33   (below consensus threshold)
  3 devices → 0.70   (AFAD relay unlocked)
  7 devices → 0.98
```

---

## Security Model

| Mechanism | Detail |
|-----------|--------|
| Ed25519 signatures | Per-install keypair. Every packet signed. Server verifies strictly (HTTP 403 on failure). |
| Replay protection | `created_at_ms` checked: reject if >5 min old or >60 s in future |
| Rate limiting | 30 packets/min per public key · 500 packets/min per ~1 km geohash |
| Dedup | LRU map keyed by `packet_id` (5-min TTL). Duplicates return 200 but don't inflate confidence. |
| Consensus | Min 3 unique devices before AFAD relay |

---

## ACK Semantics

`PacketAck` fields returned with every HTTP 200:

| Field | Type | Meaning |
|-------|------|---------|
| `user_id` | u64 | Echo of sender's ID |
| `received` | bool | True = accepted into ingest buffer |
| `confidence` | float | Current geo-cluster confidence (0.0–1.0) |
| `ingest_id` | string | Server-assigned ingestion ID (e.g. `ing_0001952...`) |
| `status` | string | `"accepted"`, `"already_accepted"` |

HTTP 200 means accepted into the ingest buffer — **not** that the packet has been persisted to disk or relayed to AFAD (those are async). Rejection codes:

| Code | Meaning |
|------|---------|
| 400 | Malformed/oversized packet |
| 403 | Missing or invalid Ed25519 signature |
| 422 | Missing required fields (user_id or timestamp) |
| 429 | Rate limit exceeded |
| 503 | Ingest buffer full — retry after indicated delay |

---

## Quick Start

> All commands run from repo root.

### Backend (Rust)

```bash
cd backend/
RUST_LOG=info cargo run --release
# Listens on http://localhost:8080
# POST /v1/ingest  GET /health  GET /ready  GET /metrics
```

### Flutter App — Android

```bash
cd sinyalist_app/
flutter pub get
flutter run --dart-define=BACKEND_URL=http://192.168.1.x:8080   # Physical device
flutter run                                                        # Emulator
flutter build apk --release
```

### Flutter App — iOS

```bash
cd sinyalist_app/
flutter pub get
flutter run -d <iphone-device-id> --dart-define=BACKEND_URL=http://192.168.1.x:8080
flutter build ios --release

# Permissions required on first launch:
#   Motion & Fitness (seismic), Bluetooth (mesh), Location Always (background keep-alive)
```

> **Note:** BLE mesh and seismic detection cannot be tested on the iOS simulator — a physical iPhone is required.

### Load Test

```bash
cd tools/loadtest/
cargo run --release -- --url http://localhost:8080 --rate 100 --duration 30
```

### Tests

```bash
# Backend (15 tests)
cd backend/ && cargo test

# Flutter (15 tests)
cd sinyalist_app/ && flutter test
```

---

## Tested With

| Tool | Minimum | Tested |
|------|---------|--------|
| Rust / cargo | 1.75 | 1.77 |
| Flutter | 3.19 | 3.22 |
| Android NDK | r25 | r26b |
| CMake | 3.22 | 3.22 |
| Android Gradle Plugin | 8.1 | 8.3 |
| Android API | 24 | 34 |
| iOS Deployment Target | 14.0 | 16.x |
| Xcode | 15 | 15+ |

---

## Limitations

| Limitation | Severity | Notes |
|------------|----------|-------|
| iOS BLE advertising in background | Medium | iOS cannot broadcast manufacturer data in background. GATT service UUID advertising still works — peers can connect and exchange packets. Cross-platform mesh is functional. |
| GPS fallback | High | If GPS unavailable, location fields are left as zero/unset. Backend excludes zero-coordinate packets from geo-cluster scoring. |
| SMS on iOS | — | Apple prohibits programmatic SMS. iOS cascade is Internet → BLE Mesh (2 layers). Dart code handles this gracefully. |
| Single backend instance | Medium | In-memory queue and dedup. Production needs PostgreSQL + Redis + load balancer. |
| Battery drain | Medium | Foreground/background BLE + accelerometer = significant drain. Survival mode reduces intervals. ~6–12 hr expected. |
| Ed25519 key rotation | Low | No revocation protocol yet. Planned for v3. |
| AFAD API | Placeholder | `afad_worker` logs packets but does not call a real API (no public AFAD ingestion endpoint available). |

---

## Project Structure

```
sinyalist/
├── README.md
├── UPGRADE_REPORT.md
├── rapor.md
├── .gitignore
├── proto/
│   └── sinyalist_packet.proto         # SinyalistPacket (32 fields), PacketAck (7 fields)
├── backend/
│   ├── Cargo.toml
│   ├── build.rs
│   └── src/main.rs                    # Axum ingest server, Ed25519, geo-cluster, metrics
├── tools/
│   └── loadtest/src/main.rs           # Signed packet load test generator
└── sinyalist_app/
    ├── pubspec.yaml
    ├── lib/
    │   ├── main.dart                  # App init, platform guards (Android + iOS)
    │   └── core/
    │       ├── bridge/native_bridge.dart
    │       ├── codec/sms_codec.dart
    │       ├── connectivity/connectivity_manager.dart
    │       ├── crypto/keypair_manager.dart
    │       ├── delivery/
    │       │   ├── delivery_state_machine.dart
    │       │   └── ingest_client.dart
    │       └── theme/sinyalist_theme.dart
    ├── test/
    │   ├── sms_codec_test.dart
    │   └── widget_test.dart
    ├── android/app/src/main/
    │   ├── kotlin/com/sinyalist/
    │   │   ├── MainActivity.kt
    │   │   ├── SinyalistApplication.kt
    │   │   ├── core/SeismicEngine.kt
    │   │   ├── mesh/
    │   │   │   ├── NodusMeshController.kt
    │   │   │   └── MeshPacketStore.kt
    │   │   └── service/
    │   │       ├── SinyalistForegroundService.kt
    │   │       └── BootReceiver.kt
    │   └── cpp/
    │       ├── CMakeLists.txt
    │       ├── seismic_detector.hpp   # STA/LTA, biquad filter, 4-stage rejection
    │       └── seismic_jni_bridge.cpp
    └── ios/Runner/
        ├── AppDelegate.swift           # FlutterImplicitEngineDelegate, 7 channels
        ├── SceneDelegate.swift
        ├── SinyalistSeismicEngine.swift  # CoreMotion, STA/LTA, FlutterStreamHandler
        ├── SinyalistMeshController.swift # CoreBluetooth GATT, SQLite, priority queue
        ├── SinyalistBackgroundManager.swift # CLLocationManager, BGTaskScheduler
        ├── Runner-Bridging-Header.h
        └── Info.plist                  # BLE+location background modes, permissions
```

---

## License

Not yet under a formal open-source license. All rights reserved by the author. Contact the maintainer before distributing or modifying.
