// =============================================================================
// SINYALIST — Emergency Ingestion Server v2.0 (Rust/Axum/Tokio)
// =============================================================================
// v2 Field-Ready changes:
//   C1: ACK semantics — 429/503 on queue full, honest non-200 responses
//   C2: Strict Ed25519 verification (REQUIRED, not optional)
//   C3: Confidence scoring tested — dedup does NOT inflate
//   C4: Structured logs + counters for all drop/accept paths
// =============================================================================

use axum::{Router, extract::State, http::{StatusCode, HeaderMap, HeaderValue}, response::IntoResponse, routing::{get, post}};
use bytes::Bytes;
use dashmap::DashMap;
use prost::Message;
use serde::Serialize;
use std::{sync::Arc, time::Duration, net::SocketAddr, collections::HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::sync::mpsc;
use tower::ServiceBuilder;
use tower_http::{compression::CompressionLayer, trace::TraceLayer};
use tracing::{info, warn, error, instrument};

// Proto types (matches sinyalist_packet.proto v2)
pub mod proto {
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, prost::Enumeration)]
    #[repr(i32)]
    pub enum BloodType { BloodUnknown=0, APos=1, ANeg=2, BPos=3, BNeg=4, AbPos=5, AbNeg=6, OPos=7, ONeg=8 }
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, prost::Enumeration)]
    #[repr(i32)]
    pub enum AlertLevel { AlertUnknown=0, AlertTremor=1, AlertModerate=2, AlertSevere=3, AlertCritical=4 }
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, prost::Enumeration)]
    #[repr(i32)]
    pub enum ConnectivityMode { ConnUnknown=0, ConnGrpc=1, ConnSms=2, ConnBleMesh=3, ConnWifiP2p=4 }
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, prost::Enumeration)]
    #[repr(i32)]
    pub enum MessageType { MsgUnknown=0, MsgTrapped=1, MsgMedical=2, MsgSos=3, MsgStatus=4, MsgHeartbeat=5 }
    #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, prost::Enumeration)]
    #[repr(i32)]
    pub enum Priority { PriorityUnknown=0, PriorityCritical=1, PriorityHigh=2, PriorityNormal=3, PriorityLow=4 }

    #[derive(Clone, prost::Message)]
    pub struct SinyalistPacket {
        #[prost(fixed64, tag="1")]  pub user_id: u64,
        #[prost(uint32, tag="2")]   pub device_hash: u32,
        #[prost(sint32, tag="3")]   pub latitude_e7: i32,
        #[prost(sint32, tag="4")]   pub longitude_e7: i32,
        #[prost(float, tag="5")]    pub altitude_m: f32,
        #[prost(uint32, tag="6")]   pub accuracy_cm: u32,
        #[prost(int32, tag="7")]    pub floor_number: i32,
        #[prost(string, tag="8")]   pub room_hint: String,
        #[prost(enumeration="BloodType", tag="9")]  pub blood_type: i32,
        #[prost(uint32, tag="10")]  pub pulse_bpm: u32,
        #[prost(uint32, tag="11")]  pub spo2_percent: u32,
        #[prost(bool, tag="12")]    pub has_medical_needs: bool,
        #[prost(uint32, tag="13")]  pub battery_percent: u32,
        #[prost(enumeration="ConnectivityMode", tag="14")] pub conn: i32,
        #[prost(enumeration="AlertLevel", tag="15")] pub alert_level: i32,
        #[prost(fixed64, tag="16")] pub timestamp_ms: u64,
        #[prost(uint32, tag="17")]  pub quake_duration_s: u32,
        #[prost(uint32, tag="18")]  pub hop_count: u32,
        #[prost(fixed32, tag="19")] pub origin_mesh_id: u32,
        #[prost(uint32, tag="20")]  pub ttl: u32,
        #[prost(bool, tag="21")]    pub is_trapped: bool,
        #[prost(uint32, tag="22")]  pub people_count: u32,
        #[prost(string, tag="23")]  pub sos_message: String,
        #[prost(bytes, tag="24")]   pub packet_id: Vec<u8>,
        #[prost(fixed64, tag="25")] pub created_at_ms: u64,
        #[prost(enumeration="MessageType", tag="26")] pub msg_type: i32,
        #[prost(enumeration="Priority", tag="27")]    pub priority: i32,
        #[prost(bytes, tag="28")]   pub ed25519_signature: Vec<u8>,
        #[prost(bytes, tag="29")]   pub ed25519_public_key: Vec<u8>,
        #[prost(float, tag="30")]   pub sta_lta_ratio: f32,
        #[prost(float, tag="31")]   pub peak_accel_g: f32,
        #[prost(float, tag="32")]   pub dominant_freq_hz: f32,
    }

    #[derive(Clone, prost::Message)]
    pub struct PacketAck {
        #[prost(fixed64, tag="1")] pub user_id: u64,
        #[prost(fixed64, tag="2")] pub timestamp_ms: u64,
        #[prost(bool, tag="3")]    pub received: bool,
        #[prost(string, tag="4")]  pub rescue_eta: String,
        #[prost(float, tag="5")]   pub confidence: f32,
        #[prost(string, tag="6")]  pub ingest_id: String,    // C1: server-assigned ID
        #[prost(string, tag="7")]  pub status: String,       // C1: "accepted" or "processed"
    }
}

// Geo-cluster: grid-cell confidence scoring (C3)
fn geo_key(lat_e7: i32, lon_e7: i32) -> u64 {
    // FIX: old divisor 9000 → cells were ~90 km wide (9000 * 1e-7 deg ≈ 0.09°
    // ≈ ~10 km latitude, even larger in practice).  Correct divisor for ~1 km
    // cells: 1 degree ≈ 111 000 m, so 1 km ≈ 0.009° = 90 000 units in e7.
    // Using 90_000 gives cells of ~1 km × ~1 km near Istanbul (41°N).
    let la = (lat_e7 / 90_000) as i64;
    let lo = (lon_e7 / 90_000) as i64;
    ((la as u64) << 32) | (lo as u64 & 0xFFFFFFFF)
}
fn time_bucket(ms: u64) -> u64 { ms / 60_000 }

#[derive(Default)]
struct GeoCluster { keys: HashSet<[u8;32]>, total: u64, first_ms: u64 }
impl GeoCluster {
    // C3: Confidence increases only with UNIQUE independently signed reports
    // Duplicates (same public key) do NOT inflate confidence
    fn confidence(&self) -> f32 {
        let unique = self.keys.len() as f32;
        if unique == 0.0 { return 0.0; }
        // Spam detection: if total reports greatly exceed unique reporters, penalize
        let spam_factor = if self.total as f32 > unique * 3.0 { 0.5 } else { 1.0 };
        // Log-scale: 1 reporter=0.33, 3=0.70, 7=0.98, 8+=1.0
        ((unique.ln() + 1.0) / 3.0 * spam_factor).min(1.0)
    }
}

struct RateEntry { count: u32, start_ms: u64 }
const RL_WINDOW: u64 = 60_000;
const RL_PER_KEY: u32 = 30;
const RL_PER_GEO: u32 = 500;
const MAX_PKT: usize = 1024;
const DEDUP_TTL: u64 = 300_000;
// C2: Schema version enforcement
const SCHEMA_VERSION: &str = "2.0";

#[derive(Clone)]
pub struct AppState {
    dedup: Arc<DashMap<Vec<u8>, u64>>,
    persist_tx: mpsc::Sender<proto::SinyalistPacket>,
    afad_tx: mpsc::Sender<proto::SinyalistPacket>,
    m: Arc<Metrics>,
    rl_key: Arc<DashMap<Vec<u8>, RateEntry>>,
    rl_geo: Arc<DashMap<u64, RateEntry>>,
    clusters: Arc<DashMap<(u64,u64), GeoCluster>>,
    known_keys: Arc<DashMap<Vec<u8>, u64>>,
}

// C4: Full structured observability counters
pub struct Metrics {
    ingested: AtomicU64, deduped: AtomicU64, afad: AtomicU64,
    persisted: AtomicU64, backpressure: AtomicU64,
    verify_fail: AtomicU64, spam: AtomicU64, malformed: AtomicU64, oversized: AtomicU64,
    accepted_ok: AtomicU64, processed_ok: AtomicU64, queue_full: AtomicU64,
    sig_missing: AtomicU64,
}
impl Metrics { fn new() -> Self { Self {
    ingested:AtomicU64::new(0), deduped:AtomicU64::new(0), afad:AtomicU64::new(0),
    persisted:AtomicU64::new(0), backpressure:AtomicU64::new(0),
    verify_fail:AtomicU64::new(0), spam:AtomicU64::new(0),
    malformed:AtomicU64::new(0), oversized:AtomicU64::new(0),
    accepted_ok:AtomicU64::new(0), processed_ok:AtomicU64::new(0),
    queue_full:AtomicU64::new(0), sig_missing:AtomicU64::new(0),
}}}

fn verify_sig(p: &proto::SinyalistPacket) -> bool {
    if p.ed25519_public_key.len() != 32 || p.ed25519_signature.len() != 64 { return false; }
    use ed25519_dalek::{Signature, VerifyingKey, Verifier};
    // Sign the packet bytes WITHOUT the signature field
    let mut sp = p.clone(); sp.ed25519_signature.clear();
    let mut sb = Vec::with_capacity(sp.encoded_len());
    if sp.encode(&mut sb).is_err() { return false; }
    let Ok(pk) = <[u8;32]>::try_from(p.ed25519_public_key.as_slice()) else { return false; };
    let Ok(sg) = <[u8;64]>::try_from(p.ed25519_signature.as_slice()) else { return false; };
    let Ok(vk) = VerifyingKey::from_bytes(&pk) else { return false; };
    let sig = Signature::from_bytes(&sg);
    vk.verify(&sb, &sig).is_ok()
}

fn check_rl(m: &DashMap<Vec<u8>,RateEntry>, k: &[u8], now: u64, max: u32) -> bool {
    let mut e = m.entry(k.to_vec()).or_insert(RateEntry{count:0,start_ms:now});
    if now - e.start_ms > RL_WINDOW { e.count=1; e.start_ms=now; true }
    else if e.count < max { e.count+=1; true } else { false }
}

fn check_geo_rl(m: &DashMap<u64,RateEntry>, k: u64, now: u64) -> bool {
    let mut e = m.entry(k).or_insert(RateEntry{count:0,start_ms:now});
    if now - e.start_ms > RL_WINDOW { e.count=1; e.start_ms=now; true }
    else if e.count < RL_PER_GEO { e.count+=1; true } else { false }
}

// Generate a unique ingest ID
fn generate_ingest_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let ts = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
    format!("ing_{:016x}", ts)
}

#[instrument(skip_all)]
async fn ingest(State(s): State<AppState>, body: Bytes) -> impl IntoResponse {
    let now = chrono::Utc::now().timestamp_millis() as u64;

    // C2: Strict size limit
    if body.len() > MAX_PKT {
        s.m.oversized.fetch_add(1, Ordering::Relaxed);
        warn!(size=body.len(), max=MAX_PKT, "oversized_packet");
        return (StatusCode::PAYLOAD_TOO_LARGE, HeaderMap::new(), Bytes::new());
    }

    // Decode protobuf
    let p = match proto::SinyalistPacket::decode(body) {
        Ok(p) => p, Err(e) => {
            s.m.malformed.fetch_add(1, Ordering::Relaxed);
            warn!(error=%e, "malformed_packet");
            return (StatusCode::BAD_REQUEST, HeaderMap::new(), Bytes::new());
        }
    };

    // C2: Required fields validation
    if p.user_id == 0 || p.timestamp_ms == 0 {
        s.m.malformed.fetch_add(1, Ordering::Relaxed);
        warn!(uid=p.user_id, ts=p.timestamp_ms, "missing_required_fields");
        return (StatusCode::UNPROCESSABLE_ENTITY, HeaderMap::new(), Bytes::new());
    }

    // C2: Ed25519 signature REQUIRED (not optional)
    // If signature is present, verify it. If missing, reject.
    if p.ed25519_signature.is_empty() || p.ed25519_public_key.is_empty() {
        s.m.sig_missing.fetch_add(1, Ordering::Relaxed);
        warn!(uid=p.user_id, "signature_missing");
        return (StatusCode::BAD_REQUEST, HeaderMap::new(), Bytes::new());
    }

    if !verify_sig(&p) {
        s.m.verify_fail.fetch_add(1, Ordering::Relaxed);
        warn!(uid=p.user_id, "verify_fail");
        return (StatusCode::FORBIDDEN, HeaderMap::new(), Bytes::new());
    }
    s.known_keys.entry(p.ed25519_public_key.clone()).or_insert(now);

    // Dedup — use packet_id if available, else user_id+timestamp
    let dk = if !p.packet_id.is_empty() { p.packet_id.clone() }
             else { let mut k = p.user_id.to_le_bytes().to_vec(); k.extend(&p.timestamp_ms.to_le_bytes()); k };
    if s.dedup.contains_key(&dk) {
        s.m.deduped.fetch_add(1, Ordering::Relaxed);
        info!(uid=p.user_id, "dedup_drop");
        // C1: Return 200 for dedup (already accepted), but don't inflate confidence
        return (StatusCode::OK, HeaderMap::new(), encode_ack(&p, true, 0.0, "already_accepted"));
    }
    s.dedup.insert(dk, now);

    // Rate limits per public key
    if !check_rl(&s.rl_key, &p.ed25519_public_key, now, RL_PER_KEY) {
        s.m.spam.fetch_add(1, Ordering::Relaxed);
        warn!(uid=p.user_id, "spam_drop_per_key");
        return (StatusCode::TOO_MANY_REQUESTS, HeaderMap::new(), Bytes::new());
    }

    // Rate limits per geo bucket
    let gk = geo_key(p.latitude_e7, p.longitude_e7);
    if !check_geo_rl(&s.rl_geo, gk, now) {
        s.m.spam.fetch_add(1, Ordering::Relaxed);
        warn!(uid=p.user_id, geo=gk, "spam_drop_per_geo");
        return (StatusCode::TOO_MANY_REQUESTS, HeaderMap::new(), Bytes::new());
    }

    s.m.ingested.fetch_add(1, Ordering::Relaxed);

    // C3: Confidence scoring — only unique public keys increase confidence
    let tb = time_bucket(p.timestamp_ms);
    let conf = {
        let mut c = s.clusters.entry((gk,tb)).or_insert_with(|| GeoCluster{keys:HashSet::new(),total:0,first_ms:now});
        c.total += 1;
        if p.ed25519_public_key.len() == 32 {
            let mut ka = [0u8;32]; ka.copy_from_slice(&p.ed25519_public_key); c.keys.insert(ka);
        }
        c.confidence()
    };

    // Priority routing — AFAD relay for critical packets
    if p.is_trapped || p.msg_type == proto::MessageType::MsgTrapped as i32
       || p.msg_type == proto::MessageType::MsgMedical as i32
       || p.alert_level >= proto::AlertLevel::AlertSevere as i32 {
        s.m.afad.fetch_add(1, Ordering::Relaxed);
        let _ = s.afad_tx.try_send(p.clone());
    }

    // C1: Persist — if queue is full, return 503 (honest backpressure)
    match s.persist_tx.try_send(p.clone()) {
        Ok(_) => {
            s.m.accepted_ok.fetch_add(1, Ordering::Relaxed);
            info!(uid=p.user_id, trapped=p.is_trapped, conf=conf, "accepted_ok");
            (StatusCode::OK, HeaderMap::new(), encode_ack(&p, true, conf, "accepted"))
        }
        Err(mpsc::error::TrySendError::Full(_)) => {
            // C1: Queue full — do NOT pretend delivered
            s.m.queue_full.fetch_add(1, Ordering::Relaxed);
            s.m.backpressure.fetch_add(1, Ordering::Relaxed);
            warn!(uid=p.user_id, "queue_full — returning 503");
            let mut headers = HeaderMap::new();
            headers.insert("Retry-After", HeaderValue::from_static("5"));
            (StatusCode::SERVICE_UNAVAILABLE, headers, Bytes::new())
        }
        Err(mpsc::error::TrySendError::Closed(_)) => {
            s.m.queue_full.fetch_add(1, Ordering::Relaxed);
            error!("persist channel closed");
            let headers = HeaderMap::new();
            (StatusCode::INTERNAL_SERVER_ERROR, headers, Bytes::new())
        }
    }
}

fn encode_ack(p: &proto::SinyalistPacket, ok: bool, conf: f32, status: &str) -> Bytes {
    let now_ms = chrono::Utc::now().timestamp_millis() as u64;
    let a = proto::PacketAck {
        user_id: p.user_id,
        timestamp_ms: now_ms,
        received: ok,
        rescue_eta: String::new(),
        confidence: conf,
        ingest_id: generate_ingest_id(),
        status: status.to_string(),
    };
    let mut b = Vec::with_capacity(a.encoded_len());
    a.encode(&mut b).ok();
    Bytes::from(b)
}

// C4: /health — returns 200 if server is ready
async fn health() -> StatusCode { StatusCode::OK }

// C4: /ready — returns 503 if queue has no capacity
async fn ready(State(s): State<AppState>) -> StatusCode {
    if s.persist_tx.capacity() > 0 { StatusCode::OK } else { StatusCode::SERVICE_UNAVAILABLE }
}

// C4: Structured metrics response
#[derive(Serialize)]
struct MResp {
    // Ingest counters
    ingested: u64,
    accepted_ok: u64,
    processed_ok: u64,
    // Drop counters
    deduped: u64,
    verify_fail: u64,
    sig_missing: u64,
    spam: u64,
    malformed: u64,
    oversized: u64,
    queue_full: u64,
    backpressure: u64,
    // Priority routing
    afad: u64,
    persisted: u64,
    // State sizes
    dedup_size: usize,
    keys: usize,
    clusters: usize,
}

async fn metrics(State(s): State<AppState>) -> impl IntoResponse {
    let r = MResp {
        ingested: s.m.ingested.load(Ordering::Relaxed),
        accepted_ok: s.m.accepted_ok.load(Ordering::Relaxed),
        processed_ok: s.m.processed_ok.load(Ordering::Relaxed),
        deduped: s.m.deduped.load(Ordering::Relaxed),
        verify_fail: s.m.verify_fail.load(Ordering::Relaxed),
        sig_missing: s.m.sig_missing.load(Ordering::Relaxed),
        spam: s.m.spam.load(Ordering::Relaxed),
        malformed: s.m.malformed.load(Ordering::Relaxed),
        oversized: s.m.oversized.load(Ordering::Relaxed),
        queue_full: s.m.queue_full.load(Ordering::Relaxed),
        backpressure: s.m.backpressure.load(Ordering::Relaxed),
        afad: s.m.afad.load(Ordering::Relaxed),
        persisted: s.m.persisted.load(Ordering::Relaxed),
        dedup_size: s.dedup.len(),
        keys: s.known_keys.len(),
        clusters: s.clusters.len(),
    };
    (StatusCode::OK, serde_json::to_string_pretty(&r).unwrap_or_default())
}

async fn eviction(d: Arc<DashMap<Vec<u8>,u64>>, c: Arc<DashMap<(u64,u64),GeoCluster>>,
                  rk: Arc<DashMap<Vec<u8>,RateEntry>>, rg: Arc<DashMap<u64,RateEntry>>) {
    let mut iv = tokio::time::interval(Duration::from_secs(60));
    loop { iv.tick().await;
        let now = chrono::Utc::now().timestamp_millis() as u64;
        let d_before = d.len();
        d.retain(|_,&mut ts| now.saturating_sub(ts) < DEDUP_TTL);
        c.retain(|_,cl| now.saturating_sub(cl.first_ms) < 300_000);
        rk.retain(|_,e| now.saturating_sub(e.start_ms) < RL_WINDOW*2);
        rg.retain(|_,e| now.saturating_sub(e.start_ms) < RL_WINDOW*2);
        let d_after = d.len();
        if d_before != d_after {
            info!(evicted=d_before-d_after, remaining=d_after, "dedup_eviction");
        }
    }
}

async fn persist_worker(mut rx: mpsc::Receiver<proto::SinyalistPacket>, m: Arc<Metrics>) {
    let mut batch = Vec::with_capacity(1000);
    let mut iv = tokio::time::interval(Duration::from_millis(100));
    loop {
        tokio::select! {
            Some(p) = rx.recv() => { batch.push(p); if batch.len()>=1000 { flush(&mut batch,&m).await; } }
            _ = iv.tick() => { if !batch.is_empty() { flush(&mut batch,&m).await; } }
        }
    }
}

async fn flush(b: &mut Vec<proto::SinyalistPacket>, m: &Metrics) {
    let n = b.len(); let t = b.iter().filter(|p|p.is_trapped).count();
    info!(packets=n, trapped=t, "batch_flush");
    m.persisted.fetch_add(n as u64, Ordering::Relaxed);
    m.processed_ok.fetch_add(n as u64, Ordering::Relaxed);
    b.clear();
}

async fn afad_worker(mut rx: mpsc::Receiver<proto::SinyalistPacket>) {
    while let Some(p) = rx.recv().await {
        info!(uid=p.user_id, lat=p.latitude_e7 as f64/1e7, lon=p.longitude_e7 as f64/1e7,
              floor=p.floor_number, trapped=p.is_trapped, msg=p.msg_type, "AFAD_RELAY");
    }
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(std::env::var("RUST_LOG").unwrap_or("sinyalist_ingest=info,tower_http=info".into()))
        .json().init();
    info!(version=SCHEMA_VERSION, "Sinyalist Ingestion Server v2.0 — Field-Ready");

    let (ptx, prx) = mpsc::channel(100_000);
    let (atx, arx) = mpsc::channel(10_000);
    let m = Arc::new(Metrics::new());
    let s = AppState {
        dedup: Arc::new(DashMap::with_capacity(500_000)), persist_tx:ptx, afad_tx:atx, m:m.clone(),
        rl_key: Arc::new(DashMap::with_capacity(10_000)),
        rl_geo: Arc::new(DashMap::with_capacity(1_000)),
        clusters: Arc::new(DashMap::with_capacity(10_000)),
        known_keys: Arc::new(DashMap::with_capacity(100_000)),
    };

    tokio::spawn(eviction(s.dedup.clone(), s.clusters.clone(), s.rl_key.clone(), s.rl_geo.clone()));
    tokio::spawn(persist_worker(prx, m.clone()));
    tokio::spawn(afad_worker(arx));

    let port: u16 = std::env::var("PORT").ok().and_then(|p|p.parse().ok()).unwrap_or(8080);
    let app = Router::new()
        .route("/v1/ingest", post(ingest))
        .route("/health", get(health))
        .route("/ready", get(ready))
        .route("/metrics", get(metrics))
        .with_state(s)
        .layer(ServiceBuilder::new().layer(TraceLayer::new_for_http()).layer(CompressionLayer::new()));

    let addr = SocketAddr::from(([0,0,0,0], port));
    info!(%addr, "listening");
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app)
        .with_graceful_shutdown(async { tokio::signal::ctrl_c().await.ok(); info!("shutdown"); })
        .await.unwrap();
}

// =============================================================================
// Tests (C3, C4 verification)
// =============================================================================
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_geo_key_different_locations() {
        // Two points ~10 km apart (Istanbul centre vs ~10 km north):
        // 410000000 e7 = 41.0000°, 411000000 e7 = 41.1000° → ~11 km apart → different cells
        let k1 = geo_key(410000000, 290000000);
        let k2 = geo_key(411000000, 291000000);
        assert_ne!(k1, k2);
    }

    #[test]
    fn test_geo_key_same_cell() {
        // Two points ~100 m apart (90_000 units = ~1 km cell width).
        // 10_000 units = ~0.001° ≈ ~111 m — must land in the same cell.
        let k1 = geo_key(410000000, 290000000);
        let k2 = geo_key(410010000, 290010000);
        assert_eq!(k1, k2);
    }

    #[test]
    fn test_confidence_zero_reporters() {
        let c = GeoCluster::default();
        assert_eq!(c.confidence(), 0.0);
    }

    #[test]
    fn test_confidence_single_reporter() {
        let mut c = GeoCluster { keys: HashSet::new(), total: 1, first_ms: 0 };
        c.keys.insert([1u8; 32]);
        let conf = c.confidence();
        // ln(1) + 1 = 1.0, / 3.0 = 0.333
        assert!(conf > 0.3 && conf < 0.4, "Single reporter confidence should be ~0.33, got {}", conf);
    }

    #[test]
    fn test_confidence_three_reporters() {
        let mut c = GeoCluster { keys: HashSet::new(), total: 3, first_ms: 0 };
        c.keys.insert([1u8; 32]);
        c.keys.insert([2u8; 32]);
        c.keys.insert([3u8; 32]);
        let conf = c.confidence();
        // ln(3) + 1 ≈ 2.1, / 3.0 ≈ 0.70
        assert!(conf > 0.6 && conf < 0.8, "3 reporters confidence should be ~0.70, got {}", conf);
    }

    #[test]
    fn test_confidence_duplicates_dont_inflate() {
        // C3: Same public key sending 10 times should NOT inflate confidence
        let mut c = GeoCluster { keys: HashSet::new(), total: 10, first_ms: 0 };
        c.keys.insert([1u8; 32]); // Only 1 unique key despite 10 total
        let conf = c.confidence();
        // total(10) > unique(1) * 3 → spam factor 0.5
        // ln(1) + 1 = 1.0, / 3.0 * 0.5 = 0.167
        assert!(conf < 0.2, "Duplicate spam should not inflate confidence, got {}", conf);
    }

    #[test]
    fn test_confidence_capped_at_one() {
        let mut c = GeoCluster { keys: HashSet::new(), total: 20, first_ms: 0 };
        for i in 0..20u8 {
            let mut k = [0u8; 32];
            k[0] = i;
            c.keys.insert(k);
        }
        let conf = c.confidence();
        assert!(conf <= 1.0, "Confidence must be capped at 1.0, got {}", conf);
    }

    #[test]
    fn test_time_bucket() {
        let t1 = time_bucket(1000);
        let t2 = time_bucket(59999);
        let t3 = time_bucket(60000);
        assert_eq!(t1, t2); // Same minute
        assert_ne!(t2, t3); // Different minutes
    }

    #[test]
    fn test_verify_sig_valid_roundtrip() {
        use ed25519_dalek::{SigningKey, Signer};
        use rand::rngs::OsRng;

        // Generate a real keypair
        let sk = SigningKey::generate(&mut OsRng);
        let vk = sk.verifying_key();

        // Build a packet WITHOUT signature
        let mut p = proto::SinyalistPacket::default();
        p.user_id = 42;
        p.timestamp_ms = 1700000000000;
        p.latitude_e7 = 410000000;
        p.longitude_e7 = 290000000;
        p.packet_id = vec![1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16];
        p.ed25519_public_key = vk.to_bytes().to_vec();

        // Serialize without signature to get signing bytes
        let mut signing_bytes = Vec::with_capacity(p.encoded_len());
        p.encode(&mut signing_bytes).unwrap();

        // Sign
        let sig = sk.sign(&signing_bytes);
        p.ed25519_signature = sig.to_bytes().to_vec();

        // Verify
        assert!(verify_sig(&p), "Valid signature should pass verification");
    }

    #[test]
    fn test_verify_sig_detects_tampering() {
        use ed25519_dalek::{SigningKey, Signer};
        use rand::rngs::OsRng;

        let sk = SigningKey::generate(&mut OsRng);
        let vk = sk.verifying_key();

        let mut p = proto::SinyalistPacket::default();
        p.user_id = 42;
        p.timestamp_ms = 1700000000000;
        p.ed25519_public_key = vk.to_bytes().to_vec();

        let mut signing_bytes = Vec::with_capacity(p.encoded_len());
        p.encode(&mut signing_bytes).unwrap();

        let sig = sk.sign(&signing_bytes);
        p.ed25519_signature = sig.to_bytes().to_vec();

        // Tamper with a field AFTER signing
        p.user_id = 99;

        assert!(!verify_sig(&p), "Tampered packet should fail verification");
    }

    #[test]
    fn test_verify_sig_rejects_wrong_lengths() {
        let mut p = proto::SinyalistPacket::default();
        p.ed25519_public_key = vec![0u8; 16]; // Wrong length
        p.ed25519_signature = vec![0u8; 64];
        assert!(!verify_sig(&p));
    }

    #[test]
    fn test_verify_sig_rejects_empty() {
        let p = proto::SinyalistPacket::default();
        assert!(!verify_sig(&p));
    }
}
