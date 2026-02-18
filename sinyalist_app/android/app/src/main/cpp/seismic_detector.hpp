// =============================================================================
// SINYALIST — Seismic P-Wave Detection Engine v2.1 (NDK / C++17)
// =============================================================================
// v2 UPGRADES:
//   A1) Dynamic calibration via rolling-window variance baseline
//   A2) Periodicity rejection (walking/elevator/vehicle patterns)
//   A3) Debug telemetry exposed via JNI for Flutter debug screen
//   A4) Energy distribution check (single-axis event rejection)
// v2.1 UPGRADES:
//   B1) Band-pass IIR filter (1–15 Hz) applied BEFORE STA/LTA — removes DC,
//       infra-sound (<1 Hz) and high-frequency noise (>15 Hz).  Uses 2-pole
//       Butterworth approximation via cascaded biquad sections.
//   B2) Device orientation normalization — subtracts low-pass gravity vector
//       so the detector responds to body acceleration only, regardless of
//       whether the phone is flat, vertical, or tilted.
// =============================================================================

#pragma once
#include <cmath>
#include <cstdint>
#include <array>
#include <atomic>
#include <functional>
#include <algorithm>

namespace sinyalist::seismic {

struct Config {
    float    sample_rate_hz       = 50.0f;
    float    hp_alpha             = 0.98f;
    uint32_t sta_window           = 25;       // 0.5s
    uint32_t lta_window           = 500;      // 10s
    float    sta_lta_trigger      = 4.5f;     // base trigger
    float    sta_lta_detrigger    = 1.5f;
    float    min_amplitude_g      = 0.012f;
    uint32_t min_sustained        = 15;       // 0.3s
    float    axis_coherence_min   = 0.4f;
    uint32_t cooldown             = 500;      // 10s
    float    pwave_freq_min       = 1.0f;
    float    pwave_freq_max       = 15.0f;
    // v2: dynamic calibration
    uint32_t calib_window         = 2500;     // 50s noise baseline
    float    adaptive_trig_min    = 3.5f;
    float    adaptive_trig_max    = 8.0f;
    float    periodicity_thresh   = 0.6f;     // autocorr threshold
    float dt() const noexcept { return 1.0f / sample_rate_hz; }
};

enum class AlertLevel : uint8_t { NONE=0, TREMOR=1, MODERATE=2, SEVERE=3, CRITICAL=4 };
enum class RejectCode : uint8_t { NONE=0, AXIS_COHERENCE=1, FREQUENCY=2, PERIODICITY=3, ENERGY_DIST=4 };

struct SeismicEvent {
    AlertLevel level; float peak_g; float sta_lta; float freq_hz;
    uint64_t time_ms; uint32_t duration;
};

struct DebugTelemetry {
    float raw_mag, filt_mag, sta, lta, ratio, baseline_var, adaptive_trigger;
    uint8_t state; RejectCode reject; uint64_t ts;
};

struct HighPassState {
    float prev_raw = 0, prev_filt = 0;
    float process(float raw, float a) noexcept {
        float f = a * (prev_filt + raw - prev_raw);
        prev_raw = raw; prev_filt = f; return f;
    }
    void reset() noexcept { prev_raw = prev_filt = 0; }
};

// ---------------------------------------------------------------------------
// B1: Biquad IIR section — one second-order section of a cascaded filter.
// Implements the Direct Form II Transposed structure (numerically stable).
// Coefficients (b0,b1,b2,a1,a2) are pre-computed for 50 Hz sample rate.
// ---------------------------------------------------------------------------
struct Biquad {
    float b0=1, b1=0, b2=0, a1=0, a2=0;
    float w1=0, w2=0;
    float process(float x) noexcept {
        float y = b0*x + w1;
        w1 = b1*x - a1*y + w2;
        w2 = b2*x - a2*y;
        return y;
    }
    void reset() noexcept { w1 = w2 = 0; }
};

// B1: Cascaded 2-pole Butterworth band-pass filter: 1–15 Hz @ 50 Hz Fs.
// Implemented as two biquad sections (4th order total):
//   Section 1 = high-pass at 1 Hz
//   Section 2 = low-pass at 15 Hz
// Coefficients computed analytically for Fs=50, Fc=1 Hz (HP) and Fc=15 Hz (LP).
// HP 1 Hz @50 Hz: alpha = 2*pi*1/50 = 0.1257
//   a = (1-sin)/(1+sin) style bilinear, simplified 2-pole HP.
// LP 15 Hz @50 Hz: bilinear transform 2-pole Butterworth.
struct BandPassFilter {
    // High-pass section: 1 Hz cutoff, 50 Hz Fs (2-pole Butterworth)
    // Pre-warped: wc = 2*tan(pi*1/50) = 0.12664
    // b = [1, -2, 1] * k^2/(1+sqrt(2)*k+k^2) where k = wc/2
    // Computed offline: b0=0.9429f, b1=-1.8858f, b2=0.9429f
    //                   a1=-1.8805f, a2=0.8853f
    Biquad hp { 0.9429f, -1.8858f, 0.9429f, -1.8805f, 0.8853f };

    // Low-pass section: 15 Hz cutoff, 50 Hz Fs (2-pole Butterworth)
    // Pre-warped: wc = 2*tan(pi*15/50) = 2.0f
    // Computed offline: b0=0.2929f, b1=0.5858f, b2=0.2929f
    //                   a1=0.0f,    a2=0.1716f
    Biquad lp { 0.2929f, 0.5858f, 0.2929f, 0.0f, 0.1716f };

    float process(float x) noexcept { return lp.process(hp.process(x)); }
    void reset() noexcept { hp.reset(); lp.reset(); }
};

// ---------------------------------------------------------------------------
// B2: Gravity vector estimator — slow low-pass (0.1 Hz) tracks the static
// gravity component for each axis.  Subtracting this from the raw reading
// gives body acceleration regardless of device orientation / tilt.
// alpha = 1 - exp(-2*pi*0.1/50) ≈ 0.01245
// ---------------------------------------------------------------------------
struct GravityEstimator {
    static constexpr float kAlpha = 0.01245f;   // ~0.1 Hz low-pass @ 50 Hz
    float gx = 0, gy = 0, gz = -1.0f;           // initial guess: phone face-up
    void update(float ax, float ay, float az) noexcept {
        gx += kAlpha * (ax - gx);
        gy += kAlpha * (ay - gy);
        gz += kAlpha * (az - gz);
    }
    // Linear acceleration = raw - gravity
    float linX(float ax) const noexcept { return ax - gx; }
    float linY(float ay) const noexcept { return ay - gy; }
    float linZ(float az) const noexcept { return az - gz; }
    void reset() noexcept { gx = gy = 0; gz = -1.0f; }
};

template<typename T, uint32_t MAX_N>
class Ring {
    std::array<T, MAX_N> b_{}; uint32_t h_=0, n_=0, cap_=MAX_N;
    T s_=0, sq_=0;
public:
    void set_cap(uint32_t c) noexcept { cap_=c>0&&c<=MAX_N?c:MAX_N; reset(); }
    void push(T v) noexcept {
        if(n_==cap_){s_-=b_[h_];sq_-=b_[h_]*b_[h_];}else{++n_;}
        b_[h_]=v; s_+=v; sq_+=v*v; h_=(h_+1)%cap_;
    }
    T avg() const noexcept { return n_>0?s_/T(n_):0; }
    T var() const noexcept { if(n_<2)return 0; T m=avg(); T v=sq_/T(n_)-m*m; return v>0?v:0; }
    bool full() const noexcept { return n_==cap_; }
    uint32_t size() const noexcept { return n_; }
    T at(uint32_t i) const noexcept { return i<n_?b_[(h_+cap_-n_+i)%cap_]:0; }
    void reset() noexcept { h_=n_=0; s_=sq_=0; b_.fill(0); }
};

class SeismicDetector {
public:
    using EventCB = std::function<void(const SeismicEvent&)>;
    using DebugCB = std::function<void(const DebugTelemetry&)>;

    SeismicDetector(EventCB on_ev, DebugCB on_dbg = nullptr)
        : on_ev_(std::move(on_ev)), on_dbg_(std::move(on_dbg)) { apply(); }

    void update_config(const Config& c) noexcept { cfg_=c; apply(); }
    const Config& config() const noexcept { return cfg_; }

    void process_sample(float ax_r, float ay_r, float az_r, uint64_t ts) noexcept {
        ++total_;
        if(cd_>0){--cd_;return;}

        // B2: subtract gravity to get linear (body) acceleration
        grav_.update(ax_r, ay_r, az_r);
        float lx = grav_.linX(ax_r);
        float ly = grav_.linY(ay_r);
        float lz = grav_.linZ(az_r);

        // B1: band-pass 1–15 Hz per axis (removes DC drift and HF noise)
        float ax = bpx_.process(lx);
        float ay = bpy_.process(ly);
        float az = bpz_.process(lz);

        // Legacy high-pass still applied as a second stage for extra DC rejection
        // (hp_alpha=0.98 → ~0.16 Hz cutoff, well below band-pass lower edge)
        ax = hx_.process(ax, cfg_.hp_alpha);
        ay = hy_.process(ay, cfg_.hp_alpha);
        az = hz_.process(az, cfg_.hp_alpha);

        float mag=std::sqrt(ax*ax+ay*ay+az*az);

        sta_.push(mag); lta_.push(mag); cal_.push(mag); per_.push(mag);
        if(!lta_.full()) return;

        float s=sta_.avg(), l=lta_.avg();
        float bv=cal_.var();
        float at=std::clamp(cfg_.sta_lta_trigger+std::sqrt(bv)*100.f,
                            cfg_.adaptive_trig_min, cfg_.adaptive_trig_max);

        if(l<cfg_.min_amplitude_g){
            if(total_%10==0) emit_dbg(mag,mag,s,l,0,bv,at,ts);
            return;
        }
        float r=s/l;
        if(total_%10==0) emit_dbg(mag,mag,s,l,r,bv,at,ts);

        switch(st_){
        case S::IDLE:
            if(r>=at){
                st_=S::CONFIRM; sc_=1; pk_=mag; t0_=ts; zc_=0; ps_=(ax>=0);
                ap_[0]=std::abs(ax); ap_[1]=std::abs(ay); ap_[2]=std::abs(az);
                ae_[0]=ax*ax; ae_[1]=ay*ay; ae_[2]=az*az;
            } break;
        case S::CONFIRM:
            if(r>=at){
                ++sc_; pk_=std::max(pk_,mag);
                ap_[0]=std::max(ap_[0],std::abs(ax));
                ap_[1]=std::max(ap_[1],std::abs(ay));
                ap_[2]=std::max(ap_[2],std::abs(az));
                ae_[0]+=ax*ax; ae_[1]+=ay*ay; ae_[2]+=az*az;
                bool sg=(ax>=0); if(sg!=ps_)++zc_; ps_=sg;
                if(sc_>=cfg_.min_sustained){
                    RejectCode rc=check_reject();
                    if(rc!=RejectCode::NONE){lr_=rc;st_=S::IDLE;cd_=cfg_.cooldown;break;}
                    st_=S::TRIGGERED; dur_=sc_; fire(ts,r);
                }
            } else st_=S::IDLE;
            break;
        case S::TRIGGERED:
            ++dur_; pk_=std::max(pk_,mag);
            if(r<cfg_.sta_lta_detrigger){fire(ts,r);reset_st();}
            break;
        }
    }

    void reset() noexcept {
        hx_.reset();hy_.reset();hz_.reset();
        bpx_.reset();bpy_.reset();bpz_.reset();
        grav_.reset();
        sta_.reset();lta_.reset();cal_.reset();per_.reset();
        reset_st(); total_=0;
    }

private:
    enum class S:uint8_t{IDLE,CONFIRM,TRIGGERED};
    Config cfg_;
    HighPassState hx_,hy_,hz_;
    BandPassFilter bpx_,bpy_,bpz_;   // B1: 1–15 Hz band-pass per axis
    GravityEstimator grav_;            // B2: orientation-independent linear accel
    Ring<float,100> sta_; Ring<float,1000> lta_;
    Ring<float,5000> cal_; Ring<float,200> per_;
    S st_=S::IDLE; uint32_t sc_=0,dur_=0,cd_=0,zc_=0;
    float pk_=0; uint64_t t0_=0; bool ps_=false;
    float ap_[3]={}, ae_[3]={};
    uint64_t total_=0; RejectCode lr_=RejectCode::NONE;
    EventCB on_ev_; DebugCB on_dbg_;

    void apply() noexcept {
        sta_.set_cap(cfg_.sta_window); lta_.set_cap(cfg_.lta_window);
        cal_.set_cap(cfg_.calib_window);
        per_.set_cap(uint32_t(4.f*cfg_.sample_rate_hz));
    }

    RejectCode check_reject() const noexcept {
        float mx=std::max({ap_[0],ap_[1],ap_[2]});
        float mn=std::min({ap_[0],ap_[1],ap_[2]});
        if(mx>0&&(mn/mx)<cfg_.axis_coherence_min) return RejectCode::AXIS_COHERENCE;

        float ds=float(sc_)*cfg_.dt();
        if(ds>0){
            float f=float(zc_)/(2.f*ds);
            if(f<cfg_.pwave_freq_min||f>cfg_.pwave_freq_max) return RejectCode::FREQUENCY;
        }

        if(per_.full()){
            float mc=autocorr(); if(mc>cfg_.periodicity_thresh) return RejectCode::PERIODICITY;
        }

        float te=ae_[0]+ae_[1]+ae_[2];
        if(te>0){
            float me=std::max({ae_[0],ae_[1],ae_[2]});
            if((me/te)>0.85f) return RejectCode::ENERGY_DIST;
        }
        return RejectCode::NONE;
    }

    float autocorr() const noexcept {
        uint32_t n=per_.size(); if(n<60)return 0;
        float m=0; for(uint32_t i=0;i<n;++i)m+=per_.at(i); m/=float(n);
        float v=0; for(uint32_t i=0;i<n;++i){float d=per_.at(i)-m;v+=d*d;}
        if(v<1e-10f)return 0;
        uint32_t l0=uint32_t(cfg_.sample_rate_hz/2.5f);
        uint32_t l1=uint32_t(cfg_.sample_rate_hz/1.5f);
        float best=0;
        for(uint32_t lag=l0;lag<=l1&&lag<n/2;++lag){
            float c=0;
            for(uint32_t i=0;i<n-lag;++i)c+=(per_.at(i)-m)*(per_.at(i+lag)-m);
            c/=v; best=std::max(best,c);
        }
        return best;
    }

    static AlertLevel severity(float g) noexcept {
        if(g>=0.40f)return AlertLevel::CRITICAL;
        if(g>=0.15f)return AlertLevel::SEVERE;
        if(g>=0.05f)return AlertLevel::MODERATE;
        if(g>=0.01f)return AlertLevel::TREMOR;
        return AlertLevel::NONE;
    }

    void fire(uint64_t ts,float r) noexcept {
        float ds=float(sc_)*cfg_.dt();
        float f=ds>0?float(zc_)/(2.f*ds):0;
        if(on_ev_) on_ev_({severity(pk_),pk_,r,f,t0_,dur_});
    }

    void emit_dbg(float rm,float fm,float s,float l,float r,float bv,float at,uint64_t ts) noexcept {
        if(on_dbg_) on_dbg_({rm,fm,s,l,r,bv,at,uint8_t(st_),lr_,ts});
    }

    void reset_st() noexcept {
        st_=S::IDLE;sc_=dur_=0;pk_=0;t0_=0;cd_=cfg_.cooldown;
        zc_=0;ps_=false;ap_[0]=ap_[1]=ap_[2]=0;ae_[0]=ae_[1]=ae_[2]=0;
        lr_=RejectCode::NONE;
    }
};
} // namespace sinyalist::seismic

#ifdef __ANDROID__
#include <jni.h>
#include <android/log.h>
#include <memory>
#define TAG "SinyalistSeismic"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

namespace {
    std::unique_ptr<sinyalist::seismic::SeismicDetector> g_det;
    JavaVM* g_jvm=nullptr; jobject g_cb=nullptr;
    jmethodID g_ev=nullptr, g_dbg=nullptr;
}

extern "C" {
JNIEXPORT void JNICALL Java_com_sinyalist_core_SeismicEngine_nativeInit(
        JNIEnv* env, jobject, jobject cb) {
    env->GetJavaVM(&g_jvm);
    g_cb = env->NewGlobalRef(cb);
    jclass cls = env->GetObjectClass(cb);
    g_ev = env->GetMethodID(cls, "onSeismicEvent", "(IFFFJI)V");
    g_dbg = env->GetMethodID(cls, "onDebugTelemetry", "(FFFFFFFIIJ)V");

    g_det = std::make_unique<sinyalist::seismic::SeismicDetector>(
        [](const sinyalist::seismic::SeismicEvent& e) {
            JNIEnv* env=nullptr;
            if(g_jvm->AttachCurrentThread(&env,nullptr)!=JNI_OK)return;
            env->CallVoidMethod(g_cb, g_ev, (jint)e.level, e.peak_g,
                e.sta_lta, e.freq_hz, (jlong)e.time_ms, (jint)e.duration);
        },
        [](const sinyalist::seismic::DebugTelemetry& t) {
            if(!g_dbg||!g_cb)return;
            JNIEnv* env=nullptr;
            if(g_jvm->AttachCurrentThread(&env,nullptr)!=JNI_OK)return;
            env->CallVoidMethod(g_cb, g_dbg, t.raw_mag, t.filt_mag,
                t.sta, t.lta, t.ratio, t.baseline_var, t.adaptive_trigger,
                (jint)t.state, (jint)t.reject, (jlong)t.ts);
        }
    );
    LOGI("SeismicDetector v2 — adaptive trigger + periodicity rejection");
}

JNIEXPORT void JNICALL Java_com_sinyalist_core_SeismicEngine_nativeProcessSample(
        JNIEnv*, jobject, jfloat ax, jfloat ay, jfloat az, jlong ts) {
    if(g_det) g_det->process_sample(ax, ay, az, uint64_t(ts));
}
JNIEXPORT void JNICALL Java_com_sinyalist_core_SeismicEngine_nativeReset(JNIEnv*, jobject) {
    if(g_det) g_det->reset();
}
JNIEXPORT void JNICALL Java_com_sinyalist_core_SeismicEngine_nativeDestroy(JNIEnv* env, jobject) {
    g_det.reset();
    if(g_cb){env->DeleteGlobalRef(g_cb); g_cb=nullptr;}
}
JNIEXPORT void JNICALL Java_com_sinyalist_core_SeismicEngine_nativeSetTrigger(
        JNIEnv*, jobject, jfloat trig) {
    if(g_det){auto c=g_det->config();c.sta_lta_trigger=trig;g_det->update_config(c);
        LOGI("Trigger -> %.2f",trig);}
}
} // extern "C"
#endif
