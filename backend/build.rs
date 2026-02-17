// =============================================================================
// SINYALIST — Build Script (Proto Compilation)
// =============================================================================
// Compiles sinyalist_packet.proto into Rust types at build time.
// In development, we define types manually in main.rs for faster iteration.
// Enable this for production builds.
// =============================================================================

fn main() {
    // Uncomment for production proto compilation:
    // prost_build::compile_protos(&["../proto/sinyalist_packet.proto"], &["../proto/"])
    //     .expect("Failed to compile protobuf definitions");
    println!("cargo:rerun-if-changed=../proto/sinyalist_packet.proto");
}
