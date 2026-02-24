# Sinyalist v2

> **LEGAL & SAFETY DISCLAIMER** — Sinyalist is a **community survivor-location relay prototype**, not a certified earthquake early-warning system. It is designed to help survivors report their location and status *after* a seismic event — not to predict or warn before one. It provides **no guarantee** of detection accuracy, message delivery, or response time. The authors accept no liability for missed events, false alarms, delivery failures, or consequences of any system decision.

**Citizen location/status relay for earthquake survivors.**
Multi-transport cascade: **Internet → SMS → BLE Mesh** (Android) · **Internet → BLE Mesh** (iOS).
Fully functional on both **Android** (Kotlin + C++ NDK) and **iOS** (Swift + CoreMotion + CoreBluetooth).

---

## Platform Support

| Feature | Android | iOS |
|---------|:-------:|:---:|
| Seismic Detection | ✅ C++ NDK · STA/LTA · 50 Hz | ✅ Swift · CoreMotion · 50 Hz |
| BLE Mesh (foreground) | ✅ Connectionless BLE 5.0 + GATT | ✅ CoreBluetooth GATT |
| BLE Mesh (background) | ✅ ForegroundService | ✅ GATT + CLLocationManager keep-alive |
| SMS Relay | ✅ Native SmsManager | ❌ Apple restriction — graceful fallback to BLE |
| Foreground Service | ✅ Android ForegroundService | ✅ CLLocationManager significant-change |
| Cross-platform Mesh | ✅ | ✅ Same GATT UUIDs |
| Ed25519 Signing | ✅ Android Keystore-backed | ✅ iOS Keychain |
| Store-carry-forward | ✅ SQLite (Kotlin) | ✅ SQLite C API (Swift) |

---

## Architecture

```
 Android Device                    iOS Device                    Cloud
 ┌────────────────────┐           ┌────────────────────┐       ┌────────────────────┐
 │ C++ Seismic Engine │           │ Swift SeismicEngine │       │  Rust Ingest API   │
 │ 50 Hz · STA/LTA   │           │ CoreMotion · STA/LTA│       │                    │
 │ 4-stage rejection  │           │ 4-stage rejection   │       │  Ed25519 verify    │
 ├────────────────────┤           ├─────────────────────┤  ──►  │  Dedup (LRU+TTL)   │
 │  Kotlin BLE Mesh   │ ◄──BLE──► │  Swift BLE Mesh     │  HTTP │  Rate limiting     │
 │  Priority queue    │           │  GATT Central+Periph│       │  Geo-cluster score │
 │  SQLite persist    │           │  SQLite persist      │       │  Honest ACK        │
 ├────────────────────┤           ├─────────────────────┤       └────────────────────┘
 │  Flutter UI (TR)   │           │  Flutter UI (TR)     │
 │  Internet→SMS→BLE  │           │  Internet→BLE        │
 │  Ed25519 sign      │           │  Ed25519 sign        │
 └────────────────────┘           └─────────────────────┘
```

**Cascade order:**
- **Android**: Internet → SMS → BLE Mesh (3 layers)
- **iOS**: Internet → BLE Mesh (2 layers — Apple prohibits programmatic SMS)
- **Cross-platform**: Android ↔ iOS devices see each other as BLE mesh peers via the shared GATT Service UUID

---

## Components

| Directory / File | Language | Purpose |
|-----------------|----------|---------|
| `sinyalist_app/lib/` | Dart/Flutter | UI (Turkish), delivery FSM, SMS codec, Ed25519 keypair, connectivity cascade |
| `sinyalist_app/android/.../kotlin/` | Kotlin | BLE mesh (connectionless + GATT), seismic bridge, foreground service, boot receiver |
| `sinyalist_app/android/.../cpp/` | C++17 | Seismic detector: adaptive STA/LTA, biquad filter, 4-stage FP rejection |
| `sinyalist_app/ios/Runner/SinyalistSeismicEngine.swift` | Swift | CoreMotion 50 Hz, STA/LTA port, 4-stage rejection, FlutterStreamHandler |
| `sinyalist_app/ios/Runner/SinyalistMeshController.swift` | Swift | CoreBluetooth GATT Central+Peripheral, priority queue, SQLite, seenIds TTL+LRU |
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
2. **SMS** — Only after internet fails AND cellular signal confirmed. Binary payload: `SY1|<base64(38 bytes)>|<CRC32_hex>` — fits in one 160-char SMS.
3. **BLE Mesh** — Store-carry-forward via priority queue. TRAPPED > MEDICAL > SOS > STATUS > CHAT. SQLite persistence survives app restarts. TTL = 1 hour.

**iOS (2 layers):**
1. **Internet** — Same as Android.
2. **BLE Mesh** — GATT-based (Central + Peripheral). Background advertising via CLLocationManager keep-alive. Cross-platform: Android and iOS mesh peers discover each other via the same GATT Service UUID.

Every packet is **Ed25519-signed** before transmission. Unsigned packets are never added to the outbox.

---

## Multi-Device Consensus

The backend does **not** relay to AFAD until at least **3 unique devices** (distinct Ed25519 public keys) report from the same ~1 km geohash cell within the same 1-minute time bucket. This prevents a single malfunctioning device from triggering a false relay.

```
Confidence formula:
  unique      = distinct public keys in cell × time bucket
  spam_factor = 0.5 if total_reports > 3 × unique, else 1.0
  confidence  = min(1.0, (ln(unique) + 1) / 3 × spam_factor)

  1 device  → 0.33   (below consensus threshold)
  3 devices → 0.70   (AFAD relay unlocked)
  7 devices → 0.98
```

---

## Security Model

| Mechanism | Detail |
|-----------|--------|
| Ed25519 signatures | Per-install keypair. Every packet signed. Server verifies strictly (HTTP 403 on failure). |
| Replay protection | `created_at_ms` checked: reject if >5 min old or >60 s in future. |
| Rate limiting | 30 packets/min per public key · 500 packets/min per ~1 km geohash. |
| Dedup | LRU map keyed by `packet_id` (5-min TTL). Duplicates return 200 but don't inflate confidence. |
| BLE seenIds | iOS: TTL eviction (1 hour) + LRU cap (5000 entries) to prevent stale IDs blocking slots. |
| Consensus | Min 3 unique devices before AFAD relay. |

---

## ACK Semantics

`PacketAck` fields returned with every HTTP 200:

| Field | Type | Meaning |
|-------|------|---------|
| `user_id` | u64 | Echo of sender's ID |
| `received` | bool | True = accepted into ingest buffer |
| `confidence` | float | Current geo-cluster confidence (0.0–1.0) |
| `ingest_id` | string | Server-assigned ingestion ID |
| `status` | string | `"accepted"` or `"already_accepted"` |

HTTP 200 means accepted into the ingest buffer — **not** that the packet has been persisted or relayed to AFAD (those are async).

| Code | Meaning |
|------|---------|
| 400 | Malformed / oversized packet |
| 403 | Missing or invalid Ed25519 signature |
| 422 | Missing required fields (user_id or timestamp) |
| 429 | Rate limit exceeded |
| 503 | Ingest buffer full — retry after delay |

---

## Quick Start

> All commands are run from the **repository root**. PowerShell syntax is used throughout.

### Backend (Rust)

```powershell
cd backend
$env:RUST_LOG = "info"
cargo run --release
# Listens on http://localhost:8080
# POST /v1/ingest  GET /health  GET /ready  GET /metrics
```

Custom port:
```powershell
$env:PORT = "8081"; $env:RUST_LOG = "info"; cargo run --release
```

### Flutter App — Android

```powershell
cd sinyalist_app
flutter pub get

# Physical device (replace with your backend IP):
flutter run --dart-define=BACKEND_URL=http://192.168.1.x:8080

# Emulator (backend on localhost):
flutter run

# Release APK:
flutter build apk --release
```

### Flutter App — iOS

```powershell
cd sinyalist_app
flutter pub get
flutter run -d <iphone-device-id> --dart-define=BACKEND_URL=http://192.168.1.x:8080
flutter build ios --release
```

> **Note:** BLE mesh and seismic detection cannot be tested on the iOS Simulator — a real iPhone is required.

> **Health check note:** If the backend is not running, the app emits `[IngestClient] Health check failed: TimeoutException` and automatically falls back to the BLE mesh cascade. This is expected behaviour by design, not an error. Once the backend starts, health checks pass automatically.

### Load Test

```powershell
cd tools/loadtest
cargo run --release -- --url http://localhost:8080 --rate 100 --duration 30
```

### Tests

```powershell
# Backend (15 tests):
cd backend; cargo test

# Flutter (46 tests):
cd sinyalist_app; flutter test
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
| iOS Deployment Target | 13.0 | 16.x |
| Xcode | 16 | 16+ |

---

## Limitations

| Limitation | Severity | Notes |
|------------|----------|-------|
| iOS BLE advertising in background | Medium | iOS cannot broadcast manufacturer data in background. GATT service UUID advertising still works — peers can connect and exchange packets. Cross-platform mesh is functional. |
| GPS fallback | High | If GPS is unavailable, the app falls back to static Istanbul coordinates (41.01°N, 28.97°E). Backend excludes zero-coordinate packets from geo-cluster scoring. |
| SMS on iOS | — | Apple prohibits programmatic SMS. iOS cascade is Internet → BLE Mesh (2 layers). Handled gracefully in Dart. |
| Single backend instance | Medium | In-memory queue and dedup. Production needs PostgreSQL + Redis + load balancer. |
| Battery drain | Medium | Foreground/background BLE + accelerometer = significant drain. Survival mode reduces intervals. ~6–12 hr expected. |
| Ed25519 key rotation | Low | No revocation protocol yet. Planned for v3. |
| AFAD API | Placeholder | `afad_worker` logs packets but does not call a real API (no public AFAD ingestion endpoint available). |

---

## Project Structure

```
sinyalist/
├── README.md
├── rapor.md
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
    │   ├── main.dart                  # App init, all UI strings in Turkish
    │   └── core/
    │       ├── bridge/native_bridge.dart
    │       ├── codec/sms_codec.dart
    │       ├── connectivity/connectivity_manager.dart
    │       ├── crypto/keypair_manager.dart
    │       ├── delivery/
    │       │   ├── delivery_state_machine.dart
    │       │   └── ingest_client.dart
    │       ├── location/location_manager.dart
    │       ├── sms/sms_bridge.dart
    │       └── theme/sinyalist_theme.dart
    ├── screens/
    │   └── home_screen.dart
    ├── test/
    │   ├── sms_codec_test.dart
    │   ├── widget_test.dart
    │   ├── keypair_manager_test.dart
    │   └── delivery_state_machine_test.dart
    ├── android/app/src/main/
    │   ├── kotlin/com/sinyalist/
    │   │   ├── MainActivity.kt
    │   │   ├── SinyalistApplication.kt
    │   │   ├── core/SeismicEngine.kt
    │   │   ├── mesh/NodusMeshController.kt
    │   │   └── service/SinyalistForegroundService.kt
    │   └── cpp/
    │       ├── CMakeLists.txt
    │       ├── seismic_detector.hpp
    │       └── seismic_jni_bridge.cpp
    └── ios/Runner/
        ├── AppDelegate.swift           # FlutterImplicitEngineDelegate, 7 channels
        ├── SinyalistSeismicEngine.swift
        ├── SinyalistMeshController.swift
        ├── SinyalistBackgroundManager.swift
        └── Info.plist
```

---

## License

Not yet under a formal open-source license. All rights reserved by the author. Contact the maintainer before distributing or modifying.

---
---

# Sinyalist v2 — Türkçe Belge

> **HUKUKİ VE GÜVENLİK FERAGATNAME** — Sinyalist, sertifikalı bir deprem erken uyarı sistemi **değildir**; bir topluluk/araştırma prototipidir. Bir deprem olayından *sonra* hayatta kalanların konum ve durumunu iletmesine yardımcı olmak amacıyla tasarlanmıştır — öncesinde uyarmak için değil. Algılama doğruluğu, mesaj iletimi veya yanıt süresi konusunda **hiçbir garanti** verilmemektedir. Yazarlar; kaçırılan olaylar, yanlış alarmlar, iletim hataları veya herhangi bir sistem kararının sonuçlarından sorumlu tutulamaz.

**Deprem hayatta kalanları için vatandaş konum ve durum bildirimi.**
Çok katmanlı iletim kaskadı: **İnternet → SMS → BLE Mesh** (Android) · **İnternet → BLE Mesh** (iOS).
Hem **Android** (Kotlin + C++ NDK) hem de **iOS** (Swift + CoreMotion + CoreBluetooth) üzerinde tam işlevsel.

---

## Platform Desteği

| Özellik | Android | iOS |
|---------|:-------:|:---:|
| Sismik Algılama | ✅ C++ NDK · STA/LTA · 50 Hz | ✅ Swift · CoreMotion · 50 Hz |
| BLE Mesh (ön plan) | ✅ Bağlantısız BLE 5.0 + GATT | ✅ CoreBluetooth GATT |
| BLE Mesh (arka plan) | ✅ ForegroundService | ✅ GATT + CLLocationManager canlı tutma |
| SMS Röle | ✅ Native SmsManager | ❌ Apple kısıtı — BLE'ye zarif geçiş |
| Ön Plan Servisi | ✅ Android ForegroundService | ✅ CLLocationManager significant-change |
| Çapraz Platform Mesh | ✅ | ✅ Aynı GATT UUID'leri |
| Ed25519 İmzalama | ✅ Android Keystore destekli | ✅ iOS Keychain |
| Sakla-taşı-ilet | ✅ SQLite (Kotlin) | ✅ SQLite C API (Swift) |

---

## Mimari

```
 Android Cihaz                     iOS Cihaz                     Bulut
 ┌────────────────────┐           ┌────────────────────┐       ┌────────────────────┐
 │ C++ Sismik Motor   │           │ Swift SismikMotor   │       │  Rust Ingest API   │
 │ 50 Hz · STA/LTA   │           │ CoreMotion · STA/LTA│       │                    │
 │ 4 aşamalı ret     │           │ 4 aşamalı ret       │       │  Ed25519 doğrulama │
 ├────────────────────┤           ├─────────────────────┤  ──►  │  LRU+TTL dedup     │
 │  Kotlin BLE Mesh   │ ◄──BLE──► │  Swift BLE Mesh     │  HTTP │  Hız sınırlama     │
 │  Öncelik kuyruğu  │           │  GATT Central+Periph│       │  Coğ. küme skoru   │
 │  SQLite persist   │           │  SQLite persist      │       │  Dürüst ACK        │
 ├────────────────────┤           ├─────────────────────┤       └────────────────────┘
 │  Flutter UI (TR)   │           │  Flutter UI (TR)     │
 │  İnternet→SMS→BLE  │           │  İnternet→BLE        │
 │  Ed25519 imzala   │           │  Ed25519 imzala      │
 └────────────────────┘           └─────────────────────┘
```

**Kaskad sırası:**
- **Android**: İnternet → SMS → BLE Mesh (3 katman)
- **iOS**: İnternet → BLE Mesh (2 katman — Apple programatik SMS'i yasaklar)
- **Çapraz platform**: Android ve iOS cihazlar, aynı GATT Servis UUID'si üzerinden birbirlerini BLE mesh peer'ı olarak görür

---

## Bileşenler

| Dizin / Dosya | Dil | Amaç |
|--------------|-----|------|
| `sinyalist_app/lib/` | Dart/Flutter | Arayüz (Türkçe), iletim FSM, SMS kodek, Ed25519, bağlantı kaskadı |
| `sinyalist_app/android/.../kotlin/` | Kotlin | BLE mesh, sismik köprü, ön plan servisi, önyükleme alıcısı |
| `sinyalist_app/android/.../cpp/` | C++17 | Sismik dedektör: adaptif STA/LTA, biquad filtre, 4 aşamalı ret |
| `ios/Runner/SinyalistSeismicEngine.swift` | Swift | CoreMotion 50 Hz, STA/LTA portu, 4 aşamalı ret |
| `ios/Runner/SinyalistMeshController.swift` | Swift | CoreBluetooth GATT, öncelik kuyruğu, SQLite, TTL+LRU dedup |
| `ios/Runner/SinyalistBackgroundManager.swift` | Swift | CLLocationManager, BGTaskScheduler, hayatta kalma bildirimi |
| `ios/Runner/AppDelegate.swift` | Swift | FlutterImplicitEngineDelegate, 7 Flutter kanalı |
| `backend/` | Rust | Axum HTTP ingest sunucusu: imza doğrulama, dedup, güven skoru |
| `proto/` | Protobuf | `SinyalistPacket` (32 alan), `PacketAck` (7 alan), `MeshRelay` |
| `tools/loadtest/` | Rust | İmzalı paket yük testi üreticisi |

---

## İletim Kaskadı

İletim durum makinesi belirleyici bir yedekleme sırası izler:

**Android (3 katman):**
1. **İnternet** — `/v1/ingest` endpoint'ine HTTP POST. Üstel geri çekilme (500 ms → 8 s tavan). Güven skoru + `ingest_id` + `status` içeren `PacketAck` döner.
2. **SMS** — Yalnızca internet başarısız olduğunda VE hücresel sinyal teyit edildiğinde. İkili yük: `SY1|<base64(38 bayt)>|<CRC32_onluk>` — tek 160 karakterlik SMS'e sığar.
3. **BLE Mesh** — Öncelik kuyruğu ile sakla-taşı-ilet. MAHSUR > TIBBİ > SOS > DURUM > SOHBET. SQLite kalıcılığı uygulama yeniden başlatmalarını atlatır. TTL = 1 saat.

**iOS (2 katman):**
1. **İnternet** — Android ile aynı.
2. **BLE Mesh** — GATT tabanlı (Central + Peripheral). CLLocationManager canlı tutma ile arka plan yayını. Çapraz platform: Android ve iOS cihazlar birbirlerini mesh peer'ı olarak bulur.

Her paket iletilmeden önce **Ed25519 ile imzalanır**. İmzasız paketler hiçbir zaman gönderme kuyruğuna eklenmez.

---

## Çok Cihaz Konsensüsü

Backend, aynı ~1 km coğrafi hücresinde ve aynı 1 dakikalık zaman diliminde en az **3 farklı cihazdan** (farklı Ed25519 public key) rapor gelmeden AFAD'a iletim yapmaz. Bu, tek bir arızalı cihazın yanlış alarm tetiklemesini önler.

```
Güven formülü:
  benzersiz    = hücre × zaman dilimindeki farklı public key sayısı
  spam_faktörü = 0.5  eğer  toplam_rapor > 3 × benzersiz  (yoksa 1.0)
  güven        = min(1.0, (ln(benzersiz) + 1) / 3 × spam_faktörü)

  1 cihaz  → 0.33  (konsensüs eşiği altı)
  3 cihaz  → 0.70  (AFAD iletimi açılır)
  7 cihaz  → 0.98
```

---

## Güvenlik Modeli

| Mekanizma | Detay |
|-----------|-------|
| Ed25519 imzaları | Kurulum başına anahtar çifti. Her paket imzalanır. Sunucu sıkı doğrular (başarısız → HTTP 403). |
| Yeniden oynatma koruması | `created_at_ms` kontrol edilir: >5 dk eski veya >60 sn gelecekte ise reddedilir. |
| Hız sınırlama | Dakikada 30 paket/public key · 500 paket/~1 km coğ. hücre. |
| Tekrarlanan paket kontrolü | `packet_id` anahtarlı LRU harita (5 dk TTL). Kopyalar 200 döner ancak güveni şişirmez. |
| BLE seenIds | iOS: TTL tahliyesi (1 saat) + LRU kapasitesi (5.000 giriş). |
| Konsensüs | AFAD iletimi için minimum 3 farklı cihaz. |

---

## ACK Anlamları

Her HTTP 200 ile dönen `PacketAck` alanları:

| Alan | Tür | Anlam |
|------|-----|-------|
| `user_id` | u64 | Gönderen ID (yankı) |
| `received` | bool | Doğru = ingest tamponuna kabul edildi |
| `confidence` | float | Güncel coğ. küme güven skoru (0.0–1.0) |
| `ingest_id` | string | Sunucu tarafından atanan ingest ID'si |
| `status` | string | `"accepted"` veya `"already_accepted"` |

HTTP 200, ingest tamponuna kabul edildi anlamına gelir — paketin diske yazıldığı veya AFAD'a iletildiği anlamına **gelmez** (bunlar eş zamansız işlemdir).

| Kod | Anlam |
|-----|-------|
| 400 | Bozuk / aşırı büyük paket |
| 403 | Eksik veya geçersiz Ed25519 imzası |
| 422 | Zorunlu alanlar eksik (user_id veya zaman damgası) |
| 429 | Hız sınırı aşıldı |
| 503 | İngest tamponu dolu — gecikmeli yeniden dene |

---

## Hızlı Başlangıç

> Tüm komutlar **depo kökünden** çalıştırılır. PowerShell sözdizimi kullanılmıştır.

### Arka Uç (Rust)

```powershell
cd backend
$env:RUST_LOG = "info"
cargo run --release
# http://localhost:8080 adresinde dinler
# POST /v1/ingest  GET /health  GET /ready  GET /metrics
```

Farklı port için:
```powershell
$env:PORT = "8081"; $env:RUST_LOG = "info"; cargo run --release
```

### Flutter Uygulaması — Android

```powershell
cd sinyalist_app
flutter pub get

# Fiziksel cihaz (kendi backend IP'nizi girin):
flutter run --dart-define=BACKEND_URL=http://192.168.1.x:8080

# Emülatör (backend localhost'ta çalışıyor):
flutter run

# Yayın APK:
flutter build apk --release
```

### Flutter Uygulaması — iOS

```powershell
cd sinyalist_app
flutter pub get
flutter run -d <iphone-cihaz-id> --dart-define=BACKEND_URL=http://192.168.1.x:8080
flutter build ios --release
```

> **Not:** iOS Simulator'da BLE mesh ve sismik algılama test edilemez — gerçek bir iPhone gereklidir.

> **Health check notu:** Backend çalışmıyorsa uygulama `[IngestClient] Health check failed: TimeoutException` logu üretir ve otomatik olarak BLE mesh kaskadına geçer. Bu bir hata değil, tasarım gereği beklenen davranıştır. Backend başlatılınca health check'ler otomatik geçmeye başlar.

### Yük Testi

```powershell
cd tools/loadtest
cargo run --release -- --url http://localhost:8080 --rate 100 --duration 30
```

### Testler

```powershell
# Arka uç (15 test):
cd backend; cargo test

# Flutter (46 test):
cd sinyalist_app; flutter test
```

---

## Test Edilen Ortamlar

| Araç | Minimum | Test Edilen |
|------|---------|------------|
| Rust / cargo | 1.75 | 1.77 |
| Flutter | 3.19 | 3.22 |
| Android NDK | r25 | r26b |
| CMake | 3.22 | 3.22 |
| Android Gradle Eklentisi | 8.1 | 8.3 |
| Android API | 24 | 34 |
| iOS Dağıtım Hedefi | 13.0 | 16.x |
| Xcode | 16 | 16+ |

---

## Bilinen Kısıtlamalar

| Kısıtlama | Önem | Not |
|-----------|------|-----|
| iOS arka plan BLE yayını | Orta | Manufacturer data yayınamaz arka planda; yalnızca service UUID. GATT bağlantısı ve çapraz platform mesh çalışır. |
| GPS yedek konumu | Yüksek | GPS yoksa İstanbul sabit koordinatına (41.01°K, 28.97°D) geri döner. Backend sıfır koordinatlı paketleri güven skoruna dahil etmez. |
| iOS'ta SMS | — | Apple programatik SMS'i yasaklar. iOS kaskadı: İnternet → BLE Mesh. Dart tarafında zarif şekilde ele alınır. |
| Tek backend örneği | Orta | Bellek içi kuyruk ve dedup. Üretim için PostgreSQL + Redis + yük dengeleyici gerekir. |
| Batarya tüketimi | Orta | Ön plan + arka plan BLE + ivmeölçer: ~6–12 saat beklenen ömür. Hayatta kalma modu aralıkları düşürür. |
| Ed25519 anahtar rotasyonu | Düşük | Henüz iptal protokolü yok — v3 planında. |
| AFAD API entegrasyonu | Düşük | `afad_worker` yalnızca loglama yapar; kamuya açık bir AFAD ingest endpoint'i mevcut değil. |

---

## Proje Yapısı

```
sinyalist/
├── README.md
├── rapor.md
├── proto/
│   └── sinyalist_packet.proto
├── backend/
│   ├── Cargo.toml
│   ├── build.rs
│   └── src/main.rs
├── tools/
│   └── loadtest/src/main.rs
└── sinyalist_app/
    ├── pubspec.yaml
    ├── lib/
    │   ├── main.dart
    │   └── core/
    │       ├── bridge/native_bridge.dart
    │       ├── codec/sms_codec.dart
    │       ├── connectivity/connectivity_manager.dart
    │       ├── crypto/keypair_manager.dart
    │       ├── delivery/delivery_state_machine.dart
    │       ├── delivery/ingest_client.dart
    │       ├── location/location_manager.dart
    │       ├── sms/sms_bridge.dart
    │       └── theme/sinyalist_theme.dart
    ├── screens/home_screen.dart
    ├── test/
    │   ├── sms_codec_test.dart
    │   ├── widget_test.dart
    │   ├── keypair_manager_test.dart
    │   └── delivery_state_machine_test.dart
    └── android/ + ios/  (bkz. yukarıdaki İngilizce bölüm)
```

---

## Lisans

Henüz resmi bir açık kaynak lisansı altında değil. Tüm haklar yazara aittir. Dağıtım veya değişiklik öncesinde bakıcıyla iletişime geçin.
