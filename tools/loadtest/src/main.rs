// =============================================================================
// SINYALIST — Load Test Tool
// =============================================================================
// Generates properly Ed25519-signed SinyalistPacket protobuf payloads and
// sends them to the ingest server at configurable rates.
// =============================================================================

use clap::Parser;
use ed25519_dalek::{Signer, SigningKey};
use prost::Message;
use rand::rngs::OsRng;
use rand::Rng;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

// Proto types matching the server
pub mod proto {
    #[derive(Clone, prost::Message)]
    pub struct SinyalistPacket {
        #[prost(fixed64, tag = "1")]
        pub user_id: u64,
        #[prost(sint32, tag = "3")]
        pub latitude_e7: i32,
        #[prost(sint32, tag = "4")]
        pub longitude_e7: i32,
        #[prost(uint32, tag = "6")]
        pub accuracy_cm: u32,
        #[prost(fixed64, tag = "16")]
        pub timestamp_ms: u64,
        #[prost(bool, tag = "21")]
        pub is_trapped: bool,
        #[prost(bytes, tag = "24")]
        pub packet_id: Vec<u8>,
        #[prost(fixed64, tag = "25")]
        pub created_at_ms: u64,
        #[prost(enumeration = "i32", tag = "26")]
        pub msg_type: i32,
        #[prost(enumeration = "i32", tag = "27")]
        pub priority: i32,
        #[prost(bytes, tag = "28")]
        pub ed25519_signature: Vec<u8>,
        #[prost(bytes, tag = "29")]
        pub ed25519_public_key: Vec<u8>,
    }
}

#[derive(Parser)]
#[command(name = "sinyalist-loadtest")]
#[command(about = "Load test tool for Sinyalist ingest server")]
struct Args {
    /// Server base URL
    #[arg(long, default_value = "http://localhost:8080")]
    url: String,

    /// Packets per second
    #[arg(long, default_value_t = 100)]
    rate: u32,

    /// Duration in seconds
    #[arg(long, default_value_t = 30)]
    duration: u64,

    /// Number of distinct Ed25519 keypairs
    #[arg(long, default_value_t = 10)]
    keys: usize,

    /// Center latitude (e7)
    #[arg(long, default_value_t = 410000000)]
    lat: i32,

    /// Center longitude (e7)
    #[arg(long, default_value_t = 290000000)]
    lon: i32,
}

struct Counters {
    sent: AtomicU64,
    accepted: AtomicU64,
    rejected: AtomicU64,
    rate_limited: AtomicU64,
    queue_full: AtomicU64,
    network_error: AtomicU64,
    latency_sum_us: AtomicU64,
}

impl Counters {
    fn new() -> Self {
        Self {
            sent: AtomicU64::new(0),
            accepted: AtomicU64::new(0),
            rejected: AtomicU64::new(0),
            rate_limited: AtomicU64::new(0),
            queue_full: AtomicU64::new(0),
            network_error: AtomicU64::new(0),
            latency_sum_us: AtomicU64::new(0),
        }
    }
}

fn build_signed_packet(
    sk: &SigningKey,
    rng: &mut impl Rng,
    lat: i32,
    lon: i32,
) -> Vec<u8> {
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;

    let mut packet_id = vec![0u8; 16];
    rng.fill(&mut packet_id[..]);

    let vk = sk.verifying_key();

    // Build packet WITHOUT signature
    let mut p = proto::SinyalistPacket {
        user_id: rng.gen(),
        latitude_e7: lat + rng.gen_range(-1000..1000),
        longitude_e7: lon + rng.gen_range(-1000..1000),
        accuracy_cm: rng.gen_range(100..5000),
        timestamp_ms: now_ms,
        is_trapped: rng.gen_bool(0.3),
        packet_id: packet_id.clone(),
        created_at_ms: now_ms,
        msg_type: rng.gen_range(1..=4),
        priority: rng.gen_range(1..=3),
        ed25519_signature: Vec::new(),
        ed25519_public_key: vk.to_bytes().to_vec(),
    };

    // Serialize without signature for signing
    let mut signing_bytes = Vec::with_capacity(p.encoded_len());
    p.encode(&mut signing_bytes).unwrap();

    // Sign
    let sig = sk.sign(&signing_bytes);
    p.ed25519_signature = sig.to_bytes().to_vec();

    // Re-serialize with signature
    let mut final_bytes = Vec::with_capacity(p.encoded_len());
    p.encode(&mut final_bytes).unwrap();
    final_bytes
}

fn main() {
    let args = Args::parse();

    println!("=== Sinyalist Load Test ===");
    println!("Target:   {}/v1/ingest", args.url);
    println!("Rate:     {} pkt/s", args.rate);
    println!("Duration: {}s", args.duration);
    println!("Keys:     {}", args.keys);
    println!("Center:   lat={} lon={}", args.lat, args.lon);
    println!();

    // Pre-generate keypairs
    let keypairs: Vec<SigningKey> = (0..args.keys)
        .map(|_| SigningKey::generate(&mut OsRng))
        .collect();

    println!("Generated {} Ed25519 keypairs", keypairs.len());

    // Check server health
    let health_url = format!("{}/health", args.url);
    match reqwest::blocking::get(&health_url) {
        Ok(r) if r.status().is_success() => println!("Server health: OK"),
        Ok(r) => {
            eprintln!("Server health check failed: {}", r.status());
            std::process::exit(1);
        }
        Err(e) => {
            eprintln!("Cannot reach server: {}", e);
            std::process::exit(1);
        }
    }

    let counters = Arc::new(Counters::new());
    let ingest_url = format!("{}/v1/ingest", args.url);

    let interval = Duration::from_micros(1_000_000 / args.rate as u64);
    let deadline = Instant::now() + Duration::from_secs(args.duration);

    println!("\nSending...\n");
    let start = Instant::now();

    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .unwrap();

    let mut rng = rand::thread_rng();
    let mut tick = 0u64;

    while Instant::now() < deadline {
        let key_idx = (tick as usize) % keypairs.len();
        let payload = build_signed_packet(&keypairs[key_idx], &mut rng, args.lat, args.lon);

        let req_start = Instant::now();
        counters.sent.fetch_add(1, Ordering::Relaxed);

        match client
            .post(&ingest_url)
            .header("Content-Type", "application/x-protobuf")
            .body(payload)
            .send()
        {
            Ok(resp) => {
                let lat = req_start.elapsed().as_micros() as u64;
                counters.latency_sum_us.fetch_add(lat, Ordering::Relaxed);

                match resp.status().as_u16() {
                    200 => {
                        counters.accepted.fetch_add(1, Ordering::Relaxed);
                    }
                    403 => {
                        counters.rejected.fetch_add(1, Ordering::Relaxed);
                    }
                    429 => {
                        counters.rate_limited.fetch_add(1, Ordering::Relaxed);
                    }
                    503 => {
                        counters.queue_full.fetch_add(1, Ordering::Relaxed);
                    }
                    other => {
                        counters.rejected.fetch_add(1, Ordering::Relaxed);
                        if tick < 5 {
                            eprintln!("Unexpected status: {}", other);
                        }
                    }
                }
            }
            Err(_) => {
                counters.network_error.fetch_add(1, Ordering::Relaxed);
            }
        }

        tick += 1;

        // Print progress every 500 packets
        if tick % 500 == 0 {
            let elapsed = start.elapsed().as_secs_f64();
            let sent = counters.sent.load(Ordering::Relaxed);
            println!(
                "  [{:.1}s] sent={} accepted={} rejected={} rate_limited={} queue_full={} err={} ({:.0} pkt/s)",
                elapsed,
                sent,
                counters.accepted.load(Ordering::Relaxed),
                counters.rejected.load(Ordering::Relaxed),
                counters.rate_limited.load(Ordering::Relaxed),
                counters.queue_full.load(Ordering::Relaxed),
                counters.network_error.load(Ordering::Relaxed),
                sent as f64 / elapsed,
            );
        }

        // Rate limiting
        let target = Duration::from_micros(tick * interval.as_micros() as u64);
        let actual = start.elapsed();
        if actual < target {
            std::thread::sleep(target - actual);
        }
    }

    let elapsed = start.elapsed();
    let sent = counters.sent.load(Ordering::Relaxed);
    let accepted = counters.accepted.load(Ordering::Relaxed);
    let avg_lat = if sent > 0 {
        counters.latency_sum_us.load(Ordering::Relaxed) / sent
    } else {
        0
    };

    println!("\n=== Results ===");
    println!("Duration:     {:.2}s", elapsed.as_secs_f64());
    println!("Total sent:   {}", sent);
    println!("Accepted:     {} ({:.1}%)", accepted, accepted as f64 / sent.max(1) as f64 * 100.0);
    println!("Rejected:     {}", counters.rejected.load(Ordering::Relaxed));
    println!("Rate limited: {}", counters.rate_limited.load(Ordering::Relaxed));
    println!("Queue full:   {}", counters.queue_full.load(Ordering::Relaxed));
    println!("Net errors:   {}", counters.network_error.load(Ordering::Relaxed));
    println!("Avg latency:  {} us", avg_lat);
    println!("Throughput:   {:.1} pkt/s", sent as f64 / elapsed.as_secs_f64());
}
