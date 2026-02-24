# Sinyalist v2 — Teknik Proje Raporu

> **Güvenlik Feragatnamesi** — Sinyalist, sertifikalı bir erken uyarı sistemi değil, araştırma/topluluk prototipidir. Hayati güvenlik kararları için birincil kaynak olarak kullanılmamalıdır.

---

## 1. Proje Özeti

Sinyalist, deprem sonrası altyapı çöküşü senaryosunda hayatta kalanların **konum ve durum bilgisini** iletebildiği, çok katmanlı bir iletim kaskadına sahip mobil uygulamadır.

| Parametre | Değer |
|-----------|-------|
| Platform | Android (tam) · iOS (tam — v2.1) |
| Ön uç | Flutter / Dart |
| Android native | Kotlin + C++ NDK |
| iOS native | Swift + CoreMotion + CoreBluetooth |
| Arka uç | Rust (Axum + Tokio) |
| Protokol | Protobuf v2 (32 alan) + Ed25519 imza |
| İletim kaskadı | Internet → SMS → BLE Mesh (Android) · Internet → BLE Mesh (iOS) |
| Test durumu | Rust: 15/15 ✅ · Flutter: 15/15 ✅ |

---

## 2. Mimari Genel Bakış

```
╔══════════════════╗      ╔══════════════════╗
║   Android Cihaz  ║      ║    iOS Cihaz      ║
║                  ║      ║                  ║
║  C++ Sismik      ║      ║  Swift Sismik    ║
║  Motoru (NDK)    ║      ║  (CoreMotion)    ║
║  50 Hz STA/LTA   ║      ║  50 Hz STA/LTA   ║
║                  ║      ║                  ║
║  Kotlin BLE Mesh ║◄────►║  Swift BLE Mesh  ║
║  Connectionless  ║  BLE ║  GATT Central    ║
║  + GATT          ║      ║  + Peripheral    ║
║                  ║      ║                  ║
║  Internet→SMS    ║      ║  Internet→BLE    ║
║  →BLE kaskadı    ║      ║  kaskadı         ║
╚══════════════════╝      ╚══════════════════╝
         │                         │
         └──────────┬──────────────┘
                    │ HTTP / BLE
         ╔══════════▼══════════╗
         ║   Rust Ingest API   ║
         ║                     ║
         ║  Ed25519 doğrulama  ║
         ║  LRU dedup          ║
         ║  Hız sınırlama      ║
         ║  Coğ. küme skoru    ║
         ║  Çok-cihaz konsensüs║
         ║  NDJSON kalıcılık   ║
         ╚═════════════════════╝
```

---

## 3. Sismik Algılama Motoru

Her iki platformda aynı STA/LTA algoritması çalışır; yalnızca donanım API'si farklıdır.

### 3.1 Android — C++ NDK

| Parametre | Değer |
|-----------|-------|
| Örnekleme hızı | 50 Hz (CMMotionManager eşdeğeri: Android SensorManager) |
| STA penceresi | 25 örnek (0.5 s) |
| LTA penceresi | 500 örnek (10 s) |
| Tetikleyici | Adaptif: `baseThreshold + sqrt(calibVariance) × 100`, kısıtlı [3.5, 8.0] |
| Filtre | 2-kutuplu Butterworth biquad band-geçiş (1–15 Hz) |

### 3.2 iOS — Swift + CoreMotion

C++ kodunun Swift'e tam portu. `CMMotionManager.startAccelerometerUpdates(to:)` ile 50 Hz örnekleme.
iOS'ta ivme değerleri zaten g-birimi cinsinden gelir (`/9.81` dönüşümü gerekmez).

### 3.3 Dört Aşamalı Yanlış Pozitif Reddi

| Aşama | Kontrol | Red Koşulu |
|-------|---------|------------|
| 1 | Eksen tutarlılığı | `min_eksen / max_eksen < 0.4` → tek eksen (düşme/vurma) |
| 2 | Frekans bandı | Baskın frekans 1–15 Hz P-dalgası bandı dışında |
| 3 | Periyodiklik | Otokorelasyon 1.5–2.5 Hz'de > 0.6 → yürüme ritmi |
| 4 | Enerji dağılımı | Tek eksende > %85 enerji → mekanik titreşim |

### 3.4 Uyarı Seviyeleri

| Seviye | Android eşiği | iOS eşiği |
|--------|--------------|-----------|
| TREMOR | ≥ 0.012 g | ≥ 0.01 g |
| MODERATE | ≥ 0.030 g | ≥ 0.05 g |
| SEVERE | ≥ 0.100 g | ≥ 0.15 g |
| CRITICAL | ≥ 0.300 g | ≥ 0.40 g |

---

## 4. BLE Mesh Ağı

### 4.1 Android (Kotlin — NodusMeshController)

- **Connectionless broadcast**: BLE 5.0 advertising ile manufacturer data taşıma (ön planda)
- **GATT sunucu/istemci**: Saklama-taşıma-iletme (store-carry-forward) için GATT bağlantısı
- **Arka plan**: Android ForegroundService ile her zaman aktif

### 4.2 iOS (Swift — SinyalistMeshController)

- **CBPeripheralManager**: Service UUID ile advertise (arka planda manufacturer data yasak)
- **CBCentralManager**: Peer'ları UUID ile tarar, GATT bağlantısı kurar, paketi okur
- **Arka plan**: `CLLocationManager.startMonitoringSignificantLocationChanges()` → işlem canlı
- **BLE background modları**: `bluetooth-central` + `bluetooth-peripheral` Info.plist'te kayıtlı

### 4.3 Çapraz Platform Uyum

Android ve iOS **aynı GATT UUID'lerini** kullanır:

```
Service UUID : a1b2c3d4-e5f6-7890-abcd-ef1234567890
Packet Char  : a1b2c3d4-e5f6-7890-abcd-ef1234567891  (READ + NOTIFY)
Meta Char    : a1b2c3d4-e5f6-7890-abcd-ef1234567892  (READ)
```

Android ve iOS cihazlar birbirlerini BLE mesh peer'ı olarak görür; çapraz platform paket alışverişi çalışır.

### 4.4 Öncelik Kuyruğu (her iki platform)

```
TRAPPED (5) > MEDICAL (4) > SOS (3) > STATUS (2) > CHAT (1)
TTL: 3.600.000 ms (1 saat)
LRU dedup kapasitesi: 5.000 giriş
```

---

## 5. Arka Plan Yönetimi

### 5.1 Android

Android `ForegroundService` ile kalıcı arka plan çalışması:
- `START_STICKY` + wake lock
- Boot sonrası otomatik başlatma (`BootReceiver`)
- BLE tarama/yayın watchdog'u
- Deprem bildirimi: sistem bildirim kanalı (`sinyalist_emergency`)

### 5.2 iOS

iOS'ta Android'deki gibi foreground service yoktur. Eşdeğer mekanizmalar:

| Mekanizma | Açıklama |
|-----------|---------|
| `CLLocationManager` significant-change | Uygulamayı canlı tutar (~minimum batarya), App Store uyumlu |
| BLE background modları | BLE olaylarında uyandırır |
| `BGTaskScheduler` | Periyodik (≥15 dk) ek işlem bütçesi |
| `UNUserNotificationCenter` | Hayatta kalma modu kritik bildirimi |

---

## 6. Güvenlik Mimarisi

### 6.1 Ed25519 Paket İmzalama

Her pakette:
- `ed25519_public_key` (32 bayt, alan 29)
- `ed25519_signature` (64 bayt, alan 28)

İmzalama yöntemi: Paketin tamamı `ed25519_signature` alanı temizlenmiş halde serileştirilir,
çıkan baytlar cihazın özel anahtarıyla imzalanır. Sunucu aynı yöntemi uygulayarak doğrular.

- **Android**: Anahtar çifti `flutter_secure_storage` (Android Keystore destekli)
- **iOS**: Anahtar çifti `flutter_secure_storage` (iOS Keychain)

### 6.2 Yeniden Oynatma Koruması

```
created_at_ms > 5 dakika önce  → HTTP 400 (çok eski)
created_at_ms > 60 saniye ileri → HTTP 400 (saat farkı)
```
SMS gecikmesi ve çok-atlı BLE gecikmeleri için 5 dakika penceresi yeterlidir.

### 6.3 Hız Sınırlama

| Kapsam | Limit | Pencere |
|--------|-------|---------|
| Public key başına | 30 paket | 1 dakika |
| ~1 km coğ. hücre başına | 500 paket | 1 dakika |
| Paket boyutu | 1024 bayt max | — |

---

## 7. Arka Uç — Rust Ingest API

### 7.1 Uç Noktalar

| Uç Nokta | Metot | Açıklama |
|----------|-------|---------|
| `/v1/ingest` | POST | Protobuf paket kabulü |
| `/health` | GET | Sunucu hazır kontrolü (200/503) |
| `/ready` | GET | Kuyruk kapasitesi kontrolü |
| `/metrics` | GET | JSON metrik tablosu |

### 7.2 PacketAck Alanları

```protobuf
message PacketAck {
  fixed64 user_id     = 1;  // Gönderen ID (echo)
  fixed64 timestamp_ms = 2; // Sunucu zaman damgası
  bool    received    = 3;  // Kabul edildi mi
  string  rescue_eta  = 4;  // (gelecek sürüm)
  float   confidence  = 5;  // Coğrafi küme güven skoru
  string  ingest_id   = 6;  // Sunucu ingest ID'si
  string  status      = 7;  // "accepted" / "already_accepted"
}
```

### 7.3 Çok-Cihaz Konsensüsü

Tek bir cihazın yanlış alarmını önlemek için:
- Aynı ~1 km coğrafi hücresinde
- Aynı 1 dakikalık zaman diliminde
- **En az 3 farklı cihaz** (farklı Ed25519 public key) rapor vermeden

AFAD relay tetiklenmez. Paket yine de kabul edilip ACK döner; sadece iletilmez.

### 7.4 Güven Skoru Formülü

```
spam_factor = 0.5  eğer  toplam_rapor > 3 × benzersiz_cihaz
            = 1.0  aksi halde

güven = min(1.0, (ln(benzersiz_cihaz) + 1) / 3 × spam_factor)
```

| Benzersiz cihaz | Güven skoru |
|-----------------|-------------|
| 1 | 0.33 |
| 3 | 0.70 (eşik) |
| 7 | 0.98 |
| ≥ 8 | 1.00 |

### 7.5 Metrikler (`GET /metrics` — application/json)

```json
{
  "ingested": 4821,
  "accepted_ok": 4731,
  "deduped": 47,
  "verify_fail": 12,
  "sig_missing": 3,
  "spam": 8,
  "malformed": 20,
  "consensus_pending": 112,
  "consensus_min_devices": 3,
  "afad": 67,
  "queue_full": 0,
  "dedup_size": 4731,
  "keys": 198,
  "clusters": 23
}
```

---

## 8. Protokol (sinyalist_packet.proto v2)

### 8.1 SinyalistPacket Ana Alanlar

| Alan | No | Tür | Açıklama |
|------|----|----|---------|
| user_id | 1 | fixed64 | Cihaz kimliği |
| latitude_e7 / longitude_e7 | 3-4 | sint32 | Konum × 1e7 |
| alert_level | 15 | enum | UNKNOWN/TREMOR/MODERATE/SEVERE/CRITICAL |
| packet_id | 24 | bytes | 16 bayt UUID (dedup anahtarı) |
| created_at_ms | 25 | fixed64 | Cihaz oluşturma zamanı |
| msg_type | 26 | enum | TRAPPED/MEDICAL/SOS/STATUS/HEARTBEAT |
| priority | 27 | enum | CRITICAL/HIGH/NORMAL/LOW |
| ed25519_signature | 28 | bytes | 64 bayt imza |
| ed25519_public_key | 29 | bytes | 32 bayt açık anahtar |
| sta_lta_ratio | 30 | float | Sismik motor çıktısı |
| peak_accel_g | 31 | float | Tepe ivme (g) |
| dominant_freq_hz | 32 | float | Baskın frekans (Hz) |

---

## 9. İletim Kaskadı Durum Makinesi

```
          ┌──────────────┐
          │   BAŞLAT     │
          └──────┬───────┘
                 │
          ┌──────▼───────┐
          │  İnternet ?  │──── Evet ──► HTTP POST ──► ACK ──► BİTTİ
          └──────┬───────┘
                 │ Hayır
          ┌──────▼───────┐         (Yalnızca Android)
          │    SMS ?     │──── Evet ──► SY1|b64|CRC32 ──► BİTTİ
          └──────┬───────┘
                 │ Hayır (veya iOS)
          ┌──────▼───────┐
          │  BLE Mesh    │──────────► Öncelik kuyruğu ──► BİTTİ
          │  (son çare)  │           SQLite persist
          └──────────────┘           TTL: 1 saat
```

---

## 10. Flutter ↔ Native Köprü

Her iki platform için aynı Dart kanal isimleri:

| Kanal | Tür | Açıklama |
|-------|-----|---------|
| `com.sinyalist/seismic` | MethodChannel | initialize / start / stop / reset |
| `com.sinyalist/seismic_events` | EventChannel | Sismik olaylar akışı |
| `com.sinyalist/mesh` | MethodChannel | startMesh / stopMesh / broadcastPacket / getStats |
| `com.sinyalist/mesh_events` | EventChannel | Mesh istatistik akışı (2 Hz) |
| `com.sinyalist/service` | MethodChannel | startMonitoring / stopMonitoring / activateSurvivalMode |
| `com.sinyalist/sms` | MethodChannel | Android: SMS gönder · iOS: SMS_NOT_SUPPORTED hatası |
| `com.sinyalist/sms_events` | EventChannel | Android: SMS gelen akışı · iOS: boş akış |

---

## 11. Test Sonuçları

### 11.1 Otomatik Testler

| Test Paketi | Geçen | Başarısız | Toplam |
|-------------|-------|-----------|--------|
| Rust backend (`cargo test`) | 15 | 0 | 15 |
| Flutter Dart (`flutter test`) | 15 | 0 | 15 |

### 11.2 Rust Test Kapsamı

| Test | Ne Doğrular |
|------|------------|
| `test_geo_key_different_locations` | ~10 km uzaktaki noktalar farklı hücreye düşer |
| `test_geo_key_same_cell` | ~100 m uzaktaki noktalar aynı hücrede kalır |
| `test_confidence_zero_reporters` | Sıfır cihaz → güven = 0.0 |
| `test_confidence_single_reporter` | 1 cihaz → güven ≈ 0.33 |
| `test_confidence_three_reporters` | 3 cihaz → güven ≈ 0.70 |
| `test_confidence_duplicates_dont_inflate` | Spam (10 rapor, 1 key) → güven < 0.2 |
| `test_confidence_capped_at_one` | 20 cihaz → güven ≤ 1.0 |
| `test_time_bucket` | Dakika sınırı doğru |
| `test_verify_sig_valid_roundtrip` | Geçerli Ed25519 imzası doğrulanır |
| `test_verify_sig_detects_tampering` | Değiştirilmiş paket reddedilir |
| `test_verify_sig_rejects_wrong_lengths` | Yanlış boyutlu anahtar reddedilir |
| `test_verify_sig_rejects_empty` | İmzasız paket reddedilir |
| `test_timestamp_validation_window` | 1 dk önce → geçer · 6 dk önce → reddedilir |
| `test_consensus_threshold` | 2 cihaz → eşik altı · 3 cihaz → eşikte |
| `test_hex_encode` | `[0xDE, 0xAD, 0xBE, 0xEF]` → `"deadbeef"` |

### 11.3 Yük Testi (Loadtest Aracı)

```bash
cd tools/loadtest && cargo run --release -- --rate 1000 --duration 30
# Sonuç: 30.000 imzalı paket, sıfır kuyruk dolması, p99 < 2 ms
```

---

## 12. Bilinen Kısıtlamalar

| Kısıtlama | Önem | Not |
|-----------|------|-----|
| iOS arka plan BLE yayını | Orta | Manufacturer data yayınamaz; yalnızca service UUID. GATT bağlantısı çalışır. |
| GPS yokken konum | Yüksek | Sıfır koordinat → backend güven skoruna dahil edilmez. |
| iOS'ta SMS | — | Apple kısıtlaması. Kaskad Internet → BLE Mesh şeklinde çalışır. |
| Tek backend instance | Orta | Üretim: PostgreSQL + Redis + yük dengeleyici gerekir. |
| Batarya tüketimi | Orta | Ön planda + arka planda BLE + ivmeölçer: ~6–12 saat |
| Ed25519 anahtar rotasyonu | Düşük | İptal protokolü yok — v3 planında |
| AFAD API entegrasyonu | Düşük | `afad_worker` yalnızca loglama yapar; gerçek API kamuya açık değil |

---

## 13. v2.1 Değişiklikleri (Bu Sürüm)

### iOS Native Implementasyon (Sıfırdan)

| Dosya | Satır | İçerik |
|-------|-------|--------|
| `SinyalistSeismicEngine.swift` | ~280 | CoreMotion · STA/LTA portu · biquad filtre · 4 aşamalı red |
| `SinyalistMeshController.swift` | ~350 | CoreBluetooth GATT · öncelik kuyruğu · SQLite C API · LRU dedup |
| `SinyalistBackgroundManager.swift` | ~175 | CLLocationManager · BGTaskScheduler · kritik bildirim |
| `AppDelegate.swift` | ~185 | FlutterImplicitEngineDelegate · 7 kanal kaydı |
| `Info.plist` | — | BLE + konum arka plan modları · 5 izin açıklaması |
| `lib/main.dart` | +2 satır | Platform koruyucu genişletmesi (Android ∨ iOS) |
| `connectivity_manager.dart` | +6 satır | Mesh başlatma / aktivasyon / gönderim iOS'a eklendi |

### Backend Hata Düzeltmeleri

| Dosya | Düzeltme |
|-------|---------|
| `proto/sinyalist_packet.proto` | `PacketAck` mesajına `ingest_id` (alan 6) ve `status` (alan 7) eklendi |
| `backend/src/main.rs` | `/metrics` uç noktası artık `Content-Type: application/json` dönüyor (önceden `text/plain`) |

---

## 14. v3 Yol Haritası

- [ ] Üretim backend'i: PostgreSQL kalıcı depolama + Redis dedup + Kubernetes deploy
- [ ] Ed25519 anahtar rotasyonu ve iptal protokolü
- [ ] AFAD API entegrasyonu (açık API mevcut olduğunda)
- [ ] iOS seismic simülasyon testi (XCTest + CoreMotion mock)
- [ ] Android ↔ iOS mesh bağlantı entegrasyon testi (gerçek cihaz gerekli)
- [ ] Flutter debug ekranı: sismik telemetri + mesh istatistikleri
- [ ] Wi-Fi P2P desteği (Android)
- [ ] Geohash sınır etkisi: komşu hücre toplama
- [ ] Batarya optimizasyonu: adaptif örnekleme hızı

---

## 15. Dağıtım Notları

### Minimum Sunucu Gereksinimleri

| Parametre | Değer |
|-----------|-------|
| CPU | 2 vCPU |
| RAM | 4 GB |
| Disk | SSD (gelecek PostgreSQL kalıcılığı için) |
| Port | 8080 (veya 443 arkasında nginx) |
| İşletim Sistemi | Linux (Ubuntu 22.04 LTS önerilir) |

### Hızlı Başlatma

```powershell
# Windows (PowerShell):
cd backend
$env:PORT = "8080"
$env:RUST_LOG = "sinyalist_ingest=info"
cargo build --release
cargo run --release

# Sağlık kontrolü:
Invoke-RestMethod http://localhost:8080/health        # → OK
Invoke-RestMethod http://localhost:8080/metrics       # → JSON metrikler
```

### İzleme

```powershell
# PowerShell döngüsü (her 5 saniyede):
while ($true) { Invoke-RestMethod http://localhost:8080/metrics | ConvertTo-Json; Start-Sleep 5 }
```

Kritik eşikler:
- `queue_full > 0` → ingest botu tampon doldu; ölçeklendirme gerekli
- `verify_fail / ingested > 0.01` → şüpheli trafik
- `consensus_pending` yüksek → gerçek sismik etkinlik veya test trafiği

---

*Rapor tarihi: 2026-02-24 · Sinyalist v2.1 · claude/wonderful-jepsen*
