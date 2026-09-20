// Synthesizes every sound in the game: spell effects, interface blips and the
// two music layers. Nothing is sampled, so the audio is the project's own.
//
//   g++ -O2 -std=c++17 tools/make_sounds.cpp -o /tmp/make_sounds && /tmp/make_sounds game/audio /tmp
//
// Effects are written as 16-bit mono WAV into the first directory. The music
// layers are 7 MB each as WAV, so they go to the second directory (kept out of
// the project, or Godot would import and export them) and are committed as Ogg:
//
//   for m in calm battle; do ffmpeg -y -i /tmp/music_$m.wav -c:a libvorbis -q:a 4 game/audio/music_$m.ogg; done
//
// Both layers are exactly the same length and loop without a seam: every event
// is written modulo the loop, and the reverb is run twice around so the tail of
// the end is already under the beginning.

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static const int SR = 44100;
static const double PI = 3.14159265358979323846;

using Mono = std::vector<float>;
struct Stereo {
	Mono l, r;
};

// --- Basics -------------------------------------------------------------------

struct Rng {
	uint32_t s;
	explicit Rng(uint32_t seed) : s(seed ? seed : 1u) {}
	uint32_t next() {
		s ^= s << 13;
		s ^= s >> 17;
		s ^= s << 5;
		return s;
	}
	float uni() { return (next() >> 8) * (1.0f / 16777216.0f); } // [0, 1)
	float bi() { return uni() * 2.0f - 1.0f; } // [-1, 1)
};

static inline float hz(float midi) {
	return 440.0f * std::pow(2.0f, (midi - 69.0f) / 12.0f);
}

static inline float smooth(float x) { // 0..1 -> 0..1, flat at both ends
	x = std::min(1.0f, std::max(0.0f, x));
	return x * x * (3.0f - 2.0f * x);
}

static Mono seconds(double s) {
	return Mono(static_cast<size_t>(s * SR), 0.0f);
}

/// Andrew Simper's state variable filter: stays stable while its cutoff moves.
struct Svf {
	float ic1 = 0, ic2 = 0, a1 = 0, a2 = 0, a3 = 0, k = 1;
	float low = 0, band = 0, high = 0;
	void set(float fc, float q) {
		fc = std::min(18000.0f, std::max(20.0f, fc));
		const float g = std::tan(static_cast<float>(PI) * fc / SR);
		k = 1.0f / std::max(0.3f, q);
		a1 = 1.0f / (1.0f + g * (g + k));
		a2 = g * a1;
		a3 = g * a2;
	}
	void tick(float x) {
		const float v3 = x - ic2;
		const float v1 = a1 * ic1 + a2 * v3;
		const float v2 = ic2 + a2 * ic1 + a3 * v3;
		ic1 = 2.0f * v1 - ic1;
		ic2 = 2.0f * v2 - ic2;
		low = v2;
		band = v1;
		high = x - k * v1 - v2;
	}
};

static void mix(Mono &dst, const Mono &src, double at_s, float gain) {
	const size_t at = static_cast<size_t>(std::max(0.0, at_s) * SR);
	if (dst.size() < at + src.size()) {
		dst.resize(at + src.size(), 0.0f);
	}
	for (size_t i = 0; i < src.size(); i++) {
		dst[at + i] += src[i] * gain;
	}
}

/// Into a loop: what runs past the end comes back in at the beginning.
static void mix_wrap(Mono &dst, const Mono &src, double at_s, float gain) {
	const size_t n = dst.size();
	size_t at = static_cast<size_t>(std::fmod(std::max(0.0, at_s), static_cast<double>(n) / SR) * SR);
	for (size_t i = 0; i < src.size(); i++) {
		dst[(at + i) % n] += src[i] * gain;
	}
}

static void fade_edges(Mono &b, float in_ms, float out_ms) {
	const size_t in = std::min(b.size(), static_cast<size_t>(in_ms * 0.001f * SR));
	const size_t out = std::min(b.size(), static_cast<size_t>(out_ms * 0.001f * SR));
	for (size_t i = 0; i < in; i++) {
		b[i] *= smooth(static_cast<float>(i) / in);
	}
	for (size_t i = 0; i < out; i++) {
		b[b.size() - 1 - i] *= smooth(static_cast<float>(i) / out);
	}
}

static void remove_dc(Mono &b) {
	float x1 = 0, y1 = 0;
	for (float &v : b) {
		const float y = v - x1 + 0.9975f * y1;
		x1 = v;
		y1 = y;
		v = y;
	}
}

static void soft_clip(Mono &b, float drive) {
	const float norm = 1.0f / std::tanh(drive);
	for (float &v : b) {
		v = std::tanh(v * drive) * norm;
	}
}

static float peak_of(const Mono &b) {
	float p = 0;
	for (float v : b) {
		p = std::max(p, std::fabs(v));
	}
	return p;
}

static void normalize(Mono &b, float peak_db) {
	const float p = peak_of(b);
	if (p > 1e-9f) {
		const float g = std::pow(10.0f, peak_db / 20.0f) / p;
		for (float &v : b) {
			v *= g;
		}
	}
}

// --- Freeverb -------------------------------------------------------------------

struct Comb {
	Mono buf;
	size_t idx = 0;
	float store = 0, feedback = 0.8f, damp1 = 0.2f, damp2 = 0.8f;
	float tick(float x) {
		const float y = buf[idx];
		store = y * damp2 + store * damp1;
		buf[idx] = x + store * feedback;
		if (++idx >= buf.size()) {
			idx = 0;
		}
		return y;
	}
};

struct Allpass {
	Mono buf;
	size_t idx = 0;
	float tick(float x) {
		const float b = buf[idx];
		const float y = b - x;
		buf[idx] = x + b * 0.5f;
		if (++idx >= buf.size()) {
			idx = 0;
		}
		return y;
	}
};

struct Reverb {
	Comb combs[2][8];
	Allpass passes[2][4];
	Reverb(float room, float damp) {
		static const int comb_len[8] = { 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 };
		static const int pass_len[4] = { 556, 441, 341, 225 };
		for (int ch = 0; ch < 2; ch++) {
			for (int i = 0; i < 8; i++) {
				combs[ch][i].buf.assign(comb_len[i] + ch * 23, 0.0f);
				combs[ch][i].feedback = room * 0.28f + 0.7f;
				combs[ch][i].damp1 = damp * 0.4f;
				combs[ch][i].damp2 = 1.0f - damp * 0.4f;
			}
			for (int i = 0; i < 4; i++) {
				passes[ch][i].buf.assign(pass_len[i] + ch * 23, 0.0f);
			}
		}
	}
	void tick(float x, float &out_l, float &out_r) {
		const float in = x * 0.015f;
		float acc[2] = { 0, 0 };
		for (int ch = 0; ch < 2; ch++) {
			for (int i = 0; i < 8; i++) {
				acc[ch] += combs[ch][i].tick(in);
			}
			for (int i = 0; i < 4; i++) {
				acc[ch] = passes[ch][i].tick(acc[ch]);
			}
		}
		out_l = acc[0] * 3.0f;
		out_r = acc[1] * 3.0f;
	}
};

/// A mono effect with some room on it; `tail_s` of silence is added for the decay.
static Mono with_room(const Mono &dry, float room, float damp, float wet, double tail_s) {
	Reverb reverb(room, damp);
	Mono out(dry.size() + static_cast<size_t>(tail_s * SR), 0.0f);
	for (size_t i = 0; i < out.size(); i++) {
		const float x = i < dry.size() ? dry[i] : 0.0f;
		float l, r;
		reverb.tick(x, l, r);
		out[i] = x + (l + r) * 0.5f * wet;
	}
	return out;
}

// --- Voices ---------------------------------------------------------------------

/// Noise through a band-pass whose centre follows `sweep` (time -> Hz).
template <class Sweep, class Env>
static Mono noise_sweep(double dur, uint32_t seed, float q, Sweep sweep, Env env, bool low_pass = false) {
	Mono out = seconds(dur);
	Rng rng(seed);
	Svf f;
	for (size_t i = 0; i < out.size(); i++) {
		const float t = static_cast<float>(i) / SR;
		if ((i & 15) == 0) {
			f.set(sweep(t), q);
		}
		f.tick(rng.bi());
		out[i] = (low_pass ? f.low : f.band) * env(t);
	}
	fade_edges(out, 0.0f, std::min(40.0f, static_cast<float>(dur) * 250.0f)); // a layer never ends on a step
	return out;
}

/// A sine whose pitch glides from f0 to f1 with time constant `glide`.
template <class Env>
static Mono glide_sine(double dur, float f0, float f1, float glide, Env env) {
	Mono out = seconds(dur);
	double phase = 0;
	for (size_t i = 0; i < out.size(); i++) {
		const float t = static_cast<float>(i) / SR;
		const float f = f1 + (f0 - f1) * std::exp(-t / glide);
		phase += 2.0 * PI * f / SR;
		out[i] = static_cast<float>(std::sin(phase)) * env(t);
	}
	fade_edges(out, 0.0f, std::min(40.0f, static_cast<float>(dur) * 250.0f));
	return out;
}

/// A water bubble: a short sine that rises in pitch as it dies.
static Mono bubble(float f0, float rise, float dur) {
	Mono out = seconds(dur);
	double phase = 0;
	for (size_t i = 0; i < out.size(); i++) {
		const float t = static_cast<float>(i) / SR;
		const float f = f0 * (1.0f + rise * t / dur);
		phase += 2.0 * PI * f / SR;
		const float env = smooth(t / 0.004f) * std::exp(-t / (dur * 0.3f));
		out[i] = static_cast<float>(std::sin(phase)) * env;
	}
	fade_edges(out, 0.5f, 4.0f);
	return out;
}

static void bubbles(Mono &dst, uint32_t seed, int count, double from_s, double to_s, float f_lo, float f_hi, float gain) {
	Rng rng(seed);
	for (int i = 0; i < count; i++) {
		const double at = from_s + (to_s - from_s) * rng.uni() * rng.uni(); // denser early
		const float f0 = f_lo * std::pow(f_hi / f_lo, rng.uni());
		mix(dst, bubble(f0, 0.5f + rng.uni() * 0.9f, 0.03f + rng.uni() * 0.06f), at, gain * (0.4f + 0.6f * rng.uni()));
	}
}

/// Sparks: random clicks ringing in a narrow band, thinning out over time.
static Mono crackle(double dur, uint32_t seed, float rate, float tau, float fc, float q) {
	Mono out = seconds(dur);
	Rng rng(seed);
	Svf f;
	f.set(fc, q);
	for (size_t i = 0; i < out.size(); i++) {
		const float t = static_cast<float>(i) / SR;
		const float p = rate * std::exp(-t / tau) / SR;
		const float click = rng.uni() < p ? rng.bi() * 6.0f : 0.0f;
		f.tick(click);
		out[i] = f.band;
	}
	fade_edges(out, 0.0f, 40.0f);
	return out;
}

/// Struck metal or crystal: inharmonic partials, the high ones dying first.
static Mono bell(float f, double dur, const std::vector<float> &ratios, const std::vector<float> &amps, float tau, float attack_ms = 2.0f) {
	Mono out = seconds(dur);
	for (size_t p = 0; p < ratios.size(); p++) {
		const float fp = f * ratios[p];
		if (fp > SR * 0.45f) {
			continue;
		}
		const float tau_p = tau / (1.0f + 0.55f * p);
		const double w = 2.0 * PI * fp / SR;
		for (size_t i = 0; i < out.size(); i++) {
			const float t = static_cast<float>(i) / SR;
			out[i] += amps[p] * static_cast<float>(std::sin(w * i)) * std::exp(-t / tau_p);
		}
	}
	fade_edges(out, attack_ms, 30.0f);
	return out;
}

static const std::vector<float> CHIME_RATIOS = { 1.0f, 2.0f, 3.01f, 4.2f, 5.43f };
static const std::vector<float> CHIME_AMPS = { 1.0f, 0.45f, 0.28f, 0.16f, 0.08f };
static const std::vector<float> CRYSTAL_RATIOS = { 1.0f, 1.48f, 2.76f, 3.9f, 5.4f, 6.8f };
static const std::vector<float> CRYSTAL_AMPS = { 1.0f, 0.6f, 0.5f, 0.35f, 0.25f, 0.18f };
static const std::vector<float> GONG_RATIOS = { 1.0f, 1.51f, 2.23f, 2.98f, 3.71f, 4.6f, 5.9f };
static const std::vector<float> GONG_AMPS = { 1.0f, 0.8f, 0.7f, 0.5f, 0.4f, 0.3f, 0.2f };

/// A band-limited sawtooth-like tone: harmonics falling off as 1/n^rolloff.
static float harmonic_tone(double phase, float f, int max_harmonics, float rolloff) {
	const int n = std::max(1, std::min(max_harmonics, static_cast<int>(SR * 0.42f / f)));
	float v = 0;
	for (int h = 1; h <= n; h++) {
		v += static_cast<float>(std::sin(phase * h)) / std::pow(static_cast<float>(h), rolloff);
	}
	return v;
}

/// A brass-like note: the upper harmonics open up during the attack.
static Mono brass(float f, double dur, double release = 0.09) {
	Mono out = seconds(dur + release);
	double phase = 0;
	for (size_t i = 0; i < out.size(); i++) {
		const float t = static_cast<float>(i) / SR;
		const float vib = 1.0f + 0.004f * std::sin(2.0f * static_cast<float>(PI) * 5.2f * t) * smooth((t - 0.15f) / 0.2f);
		phase += 2.0 * PI * f * vib / SR;
		const float bright = 0.35f + 0.4f * smooth(t / 0.05f) - 0.18f * smooth((t - 0.06f) / 0.3f);
		const int n = std::max(1, std::min(12, static_cast<int>(SR * 0.42f / f)));
		float v = 0, b = 1;
		for (int h = 1; h <= n; h++) {
			v += b * static_cast<float>(std::sin(phase * h)) / h;
			b *= bright * 1.6f > 1.0f ? 1.0f : bright * 1.6f;
		}
		float env = smooth(t / 0.025f);
		if (t > dur) {
			env *= 1.0f - smooth(static_cast<float>((t - dur) / release));
		}
		out[i] = v * env;
	}
	return out;
}

// --- Effects --------------------------------------------------------------------

static Mono make_bolt_fire() {
	Mono out = seconds(0.6);
	mix(out, noise_sweep(0.6, 11, 1.1f,
				 [](float t) { return t < 0.07f ? 450.0f + 2300.0f * (t / 0.07f) : 500.0f + 2250.0f * std::exp(-(t - 0.07f) / 0.13f); },
				 [](float t) { return smooth(t / 0.015f) * std::exp(-t / 0.15f); }),
			0, 1.0f);
	mix(out, glide_sine(0.35, 170, 58, 0.06f, [](float t) { return smooth(t / 0.004f) * std::exp(-t / 0.09f); }), 0, 0.75f);
	mix(out, crackle(0.55, 12, 140, 0.16f, 3200, 3.5f), 0.02, 0.22f);
	remove_dc(out);
	soft_clip(out, 1.6f);
	fade_edges(out, 1, 60);
	return out;
}

static Mono make_wave_fire() {
	Mono out = seconds(1.4);
	// The roar: low noise that swells, flutters and dies away.
	Mono roar = noise_sweep(1.4, 21, 0.8f,
			[](float t) { return 260.0f + 1500.0f * smooth(t / 0.25f) * std::exp(-t / 0.55f); },
			[](float t) { return smooth(t / 0.14f) * std::exp(-t / 0.5f) * (0.78f + 0.22f * std::sin(2.0f * float(PI) * 17.0f * t + 3.0f * std::sin(2.0f * float(PI) * 3.1f * t))); },
			true);
	mix(out, roar, 0, 1.0f);
	mix(out, noise_sweep(1.2, 22, 1.4f, [](float t) { return 900.0f + 2200.0f * std::exp(-t / 0.3f); },
				 [](float t) { return smooth(t / 0.1f) * std::exp(-t / 0.3f); }),
			0, 0.35f);
	mix(out, glide_sine(1.1, 85, 44, 0.3f, [](float t) { return smooth(t / 0.06f) * std::exp(-t / 0.42f); }), 0, 0.7f);
	mix(out, crackle(1.3, 23, 190, 0.45f, 2800, 3.0f), 0.05, 0.2f);
	remove_dc(out);
	soft_clip(out, 1.8f);
	fade_edges(out, 2, 120);
	return out;
}

static Mono make_bolt_water() {
	Mono out = seconds(0.55);
	mix(out, noise_sweep(0.5, 31, 2.4f,
				 [](float t) { return t < 0.06f ? 900.0f + 2400.0f * (t / 0.06f) : 1100.0f + 2200.0f * std::exp(-(t - 0.06f) / 0.12f); },
				 [](float t) { return smooth(t / 0.012f) * std::exp(-t / 0.13f); }),
			0, 0.8f);
	mix(out, noise_sweep(0.3, 32, 0.7f, [](float) { return 4200.0f; }, [](float t) { return smooth(t / 0.003f) * std::exp(-t / 0.06f); }), 0, 0.4f);
	mix(out, bubble(420, 1.1f, 0.09f), 0.0, 0.9f);
	mix(out, bubble(640, 0.9f, 0.07f), 0.045, 0.6f);
	mix(out, bubble(930, 0.8f, 0.05f), 0.085, 0.45f);
	bubbles(out, 33, 7, 0.1, 0.4, 500, 1600, 0.28f);
	remove_dc(out);
	soft_clip(out, 1.3f);
	fade_edges(out, 1, 60);
	return out;
}

static Mono make_wave_water() {
	Mono out = seconds(1.5);
	mix(out, noise_sweep(1.5, 41, 0.9f,
				 [](float t) { return 500.0f + 1500.0f * smooth(t / 0.4f) * std::exp(-t / 0.7f) + 250.0f * std::sin(2.0f * float(PI) * 2.3f * t); },
				 [](float t) { return smooth(t / 0.22f) * std::exp(-t / 0.5f); }),
			0, 1.0f);
	mix(out, noise_sweep(1.3, 42, 0.6f, [](float) { return 5200.0f; }, [](float t) { return smooth(t / 0.3f) * std::exp(-t / 0.35f); }), 0, 0.3f);
	mix(out, glide_sine(0.9, 110, 52, 0.2f, [](float t) { return smooth(t / 0.05f) * std::exp(-t / 0.3f); }), 0, 0.6f);
	bubbles(out, 43, 30, 0.05, 1.2, 320, 1500, 0.3f);
	remove_dc(out);
	soft_clip(out, 1.4f);
	fade_edges(out, 2, 140);
	return out;
}

static Mono make_shield(bool up) {
	const double dur = up ? 0.7 : 0.45;
	Mono out = seconds(dur);
	double p1 = 0, p2 = 0, p3 = 0;
	Svf f;
	for (size_t i = 0; i < out.size(); i++) {
		const float t = static_cast<float>(i) / SR;
		const float u = static_cast<float>(t / dur);
		const float rise = up ? smooth(u / 0.55f) : 1.0f - smooth(u / 0.8f);
		const float base = 98.0f * (1.0f + 0.5f * rise);
		p1 += 2.0 * PI * base / SR;
		p2 += 2.0 * PI * base * 1.503 / SR;
		p3 += 2.0 * PI * (up ? 240.0f + 480.0f * rise : 200.0f + 420.0f * rise) / SR;
		float v = harmonic_tone(p1, base, 10, 1.1f) + 0.7f * harmonic_tone(p2, base * 1.503f, 8, 1.2f);
		if ((i & 15) == 0) {
			f.set(280.0f + 3200.0f * rise * rise, 1.6f);
		}
		f.tick(v);
		const float shimmer = 0.85f + 0.15f * std::sin(2.0f * float(PI) * 11.0f * t);
		const float env = up ? smooth(u / 0.3f) * (1.0f - smooth((u - 0.6f) / 0.4f)) : smooth(u / 0.04f) * (1.0f - smooth(u));
		out[i] = (f.low * 0.6f * shimmer + 0.35f * static_cast<float>(std::sin(p3))) * env;
	}
	fade_edges(out, 3, 40);
	return with_room(out, 0.5f, 0.5f, 0.25f, 0.35);
}

static Mono make_shield_block() {
	Mono out = seconds(0.2);
	mix(out, bell(540, 0.8, CRYSTAL_RATIOS, CRYSTAL_AMPS, 0.32f, 1.0f), 0, 0.8f);
	mix(out, bell(811, 0.6, CRYSTAL_RATIOS, CRYSTAL_AMPS, 0.2f, 1.0f), 0.004, 0.35f);
	mix(out, noise_sweep(0.12, 51, 1.2f, [](float) { return 4200.0f; }, [](float t) { return std::exp(-t / 0.012f); }), 0, 0.9f);
	mix(out, glide_sine(0.18, 1900, 260, 0.04f, [](float t) { return std::exp(-t / 0.05f); }), 0, 0.3f);
	remove_dc(out);
	fade_edges(out, 0.5f, 60);
	return with_room(out, 0.55f, 0.4f, 0.3f, 0.5);
}

static Mono make_hit(bool fire) {
	Mono out = seconds(1.0);
	if (fire) {
		mix(out, glide_sine(0.7, 125, 36, 0.11f, [](float t) { return smooth(t / 0.003f) * std::exp(-t / 0.24f); }), 0, 1.0f);
		mix(out, noise_sweep(0.8, 61, 0.8f, [](float t) { return 300.0f + 1300.0f * std::exp(-t / 0.12f); },
					 [](float t) { return smooth(t / 0.003f) * std::exp(-t / 0.2f); }, true),
				0, 0.9f);
		mix(out, noise_sweep(0.25, 62, 0.8f, [](float) { return 3000.0f; }, [](float t) { return std::exp(-t / 0.03f); }), 0, 0.35f);
		mix(out, crackle(0.9, 63, 260, 0.3f, 2600, 3.0f), 0.03, 0.24f);
		soft_clip(out, 2.4f);
	} else {
		mix(out, glide_sine(0.5, 150, 46, 0.07f, [](float t) { return smooth(t / 0.003f) * std::exp(-t / 0.15f); }), 0, 0.95f);
		mix(out, noise_sweep(0.7, 64, 0.7f, [](float t) { return 1200.0f + 2600.0f * std::exp(-t / 0.1f); },
					 [](float t) { return smooth(t / 0.004f) * std::exp(-t / 0.17f); }),
				0, 0.95f);
		mix(out, noise_sweep(0.5, 65, 0.6f, [](float) { return 6000.0f; }, [](float t) { return smooth(t / 0.01f) * std::exp(-t / 0.12f); }), 0.01, 0.3f);
		bubbles(out, 66, 16, 0.08, 0.8, 380, 1700, 0.34f);
		soft_clip(out, 1.7f);
	}
	remove_dc(out);
	fade_edges(out, 0.5f, 100);
	return with_room(out, 0.45f, 0.6f, 0.18f, 0.3);
}

static Mono make_clash() {
	Mono out = seconds(0.3);
	mix(out, noise_sweep(0.3, 71, 0.9f, [](float t) { return 5200.0f - 2500.0f * t; }, [](float t) { return std::exp(-t / 0.07f); }), 0, 0.8f);
	mix(out, bell(880, 0.7, CRYSTAL_RATIOS, CRYSTAL_AMPS, 0.26f, 1.0f), 0, 0.55f);
	mix(out, bell(1174, 0.5, CRYSTAL_RATIOS, CRYSTAL_AMPS, 0.18f, 1.0f), 0.01, 0.3f);
	mix(out, glide_sine(0.35, 2600, 240, 0.07f, [](float t) { return std::exp(-t / 0.09f); }), 0, 0.5f);
	mix(out, glide_sine(0.3, 140, 60, 0.05f, [](float t) { return std::exp(-t / 0.08f); }), 0, 0.6f);
	remove_dc(out);
	soft_clip(out, 1.5f);
	fade_edges(out, 0.5f, 60);
	return with_room(out, 0.6f, 0.4f, 0.3f, 0.5);
}

static Mono make_heal() {
	Mono out = seconds(1.2);
	const float notes[4] = { 74, 81, 86, 90 }; // D5 A5 D6 F#6
	for (int i = 0; i < 4; i++) {
		mix(out, bell(hz(notes[i]), 1.1, CHIME_RATIOS, CHIME_AMPS, 0.55f, 4.0f), 0.11 * i, 0.55f - 0.06f * i);
	}
	// A breath of air rising underneath.
	mix(out, noise_sweep(0.9, 81, 2.0f, [](float t) { return 1500.0f + 4500.0f * smooth(t / 0.8f); },
				 [](float t) { return smooth(t / 0.3f) * (1.0f - smooth((t - 0.4f) / 0.5f)); }),
			0, 0.12f);
	remove_dc(out);
	fade_edges(out, 2, 120);
	return with_room(out, 0.7f, 0.3f, 0.4f, 0.9);
}

static Mono make_count() {
	Mono out = seconds(0.2);
	for (size_t i = 0; i < out.size(); i++) {
		const float t = static_cast<float>(i) / SR;
		const float env = smooth(t / 0.003f) * std::exp(-t / 0.05f);
		out[i] = (std::sin(2.0f * float(PI) * 660.0f * t) + 0.3f * std::sin(2.0f * float(PI) * 1320.0f * t)) * env;
	}
	fade_edges(out, 1, 30);
	return with_room(out, 0.4f, 0.5f, 0.15f, 0.2);
}

static Mono make_fight() {
	Mono out = seconds(1.2);
	mix(out, bell(98, 1.8, GONG_RATIOS, GONG_AMPS, 1.1f, 3.0f), 0, 0.7f);
	mix(out, bell(147, 1.4, GONG_RATIOS, GONG_AMPS, 0.8f, 3.0f), 0, 0.35f);
	mix(out, noise_sweep(0.5, 91, 0.7f, [](float t) { return 2500.0f * std::exp(-t / 0.15f) + 300.0f; }, [](float t) { return std::exp(-t / 0.09f); }, true), 0, 0.8f);
	mix(out, glide_sine(0.5, 110, 45, 0.08f, [](float t) { return std::exp(-t / 0.18f); }), 0, 0.8f);
	// A bright rush of air on top.
	mix(out, noise_sweep(0.7, 92, 1.5f, [](float t) { return 1200.0f + 5000.0f * smooth(t / 0.5f); }, [](float t) { return smooth(t / 0.2f) * std::exp(-t / 0.25f); }), 0, 0.3f);
	remove_dc(out);
	soft_clip(out, 1.6f);
	fade_edges(out, 1, 200);
	return with_room(out, 0.75f, 0.35f, 0.3f, 0.8);
}

static Mono make_ko() {
	Mono out = seconds(1.8);
	mix(out, glide_sine(1.6, 92, 28, 0.35f, [](float t) { return smooth(t / 0.004f) * std::exp(-t / 0.55f); }), 0, 1.0f);
	mix(out, noise_sweep(1.2, 101, 0.8f, [](float t) { return 200.0f + 1100.0f * std::exp(-t / 0.2f); }, [](float t) { return smooth(t / 0.004f) * std::exp(-t / 0.35f); }, true), 0, 0.8f);
	// A falling pair of tones, slightly apart, for the "down he goes".
	mix(out, glide_sine(1.5, 392, 98, 0.45f, [](float t) { return smooth(t / 0.05f) * std::exp(-t / 0.6f); }), 0.05, 0.22f);
	mix(out, glide_sine(1.5, 396, 99.5f, 0.45f, [](float t) { return smooth(t / 0.05f) * std::exp(-t / 0.6f); }), 0.05, 0.22f);
	remove_dc(out);
	soft_clip(out, 2.0f);
	fade_edges(out, 1, 250);
	return with_room(out, 0.8f, 0.4f, 0.35f, 0.9);
}

static Mono make_victory() {
	Mono out = seconds(3.0);
	// D major: three pickup notes, a long top note, then the chord with a drum under it.
	const float melody[4][3] = { { 62, 0.0f, 0.2f }, { 66, 0.25f, 0.2f }, { 69, 0.5f, 0.2f }, { 74, 0.75f, 0.65f } };
	for (const auto &n : melody) {
		mix(out, brass(hz(n[0]), n[2]), n[1], 0.5f);
		mix(out, brass(hz(n[0] - 12), n[2]), n[1], 0.28f);
	}
	const float chord[4] = { 50, 62, 66, 69 };
	for (float n : chord) {
		mix(out, brass(hz(n), 1.1, 0.35), 1.5, 0.3f);
	}
	mix(out, brass(hz(74), 1.1, 0.35), 1.5, 0.42f);
	mix(out, glide_sine(0.6, 120, 62, 0.06f, [](float t) { return std::exp(-t / 0.2f); }), 1.5, 0.9f);
	mix(out, glide_sine(0.4, 110, 62, 0.05f, [](float t) { return std::exp(-t / 0.15f); }), 0.75, 0.5f);
	mix(out, bell(hz(86), 1.2, CHIME_RATIOS, CHIME_AMPS, 0.6f, 3.0f), 1.5, 0.18f);
	remove_dc(out);
	soft_clip(out, 1.2f);
	fade_edges(out, 2, 200);
	return with_room(out, 0.7f, 0.35f, 0.3f, 0.8);
}

static Mono make_two_notes(float first, float second, float gain) {
	Mono out = seconds(0.5);
	mix(out, bell(hz(first), 0.5, CHIME_RATIOS, CHIME_AMPS, 0.25f, 3.0f), 0, gain);
	mix(out, bell(hz(second), 0.6, CHIME_RATIOS, CHIME_AMPS, 0.3f, 3.0f), 0.11, gain);
	fade_edges(out, 1, 80);
	return with_room(out, 0.5f, 0.4f, 0.25f, 0.4);
}

static Mono make_fizzle() {
	Mono out = seconds(0.35);
	mix(out, noise_sweep(0.35, 111, 0.9f, [](float t) { return 900.0f * std::exp(-t / 0.1f) + 180.0f; }, [](float t) { return smooth(t / 0.01f) * std::exp(-t / 0.09f); }, true), 0, 1.0f);
	mix(out, glide_sine(0.3, 300, 120, 0.08f, [](float t) { return smooth(t / 0.01f) * std::exp(-t / 0.08f); }), 0, 0.5f);
	remove_dc(out);
	fade_edges(out, 1, 60);
	return out;
}

static Mono make_ui_move() {
	Mono out = seconds(0.07);
	for (size_t i = 0; i < out.size(); i++) {
		const float t = static_cast<float>(i) / SR;
		out[i] = std::sin(2.0f * float(PI) * 1250.0f * t) * smooth(t / 0.002f) * std::exp(-t / 0.014f);
	}
	fade_edges(out, 0.5f, 15);
	return out;
}

static Mono make_ui_select() {
	Mono out = seconds(0.2);
	mix(out, bell(hz(81), 0.12, CHIME_RATIOS, CHIME_AMPS, 0.06f, 2.0f), 0, 0.8f);
	mix(out, bell(hz(88), 0.18, CHIME_RATIOS, CHIME_AMPS, 0.09f, 2.0f), 0.055, 0.8f);
	fade_edges(out, 0.5f, 30);
	return out;
}

static Mono make_ui_panel(bool open) {
	Mono out = seconds(0.3);
	mix(out, noise_sweep(0.3, 121, 2.2f,
				 [open](float t) { return open ? 900.0f + 2600.0f * smooth(t / 0.25f) : 3500.0f - 2600.0f * smooth(t / 0.25f); },
				 [](float t) { return smooth(t / 0.05f) * (1.0f - smooth((t - 0.1f) / 0.2f)); }),
			0, 0.6f);
	mix(out, glide_sine(0.28, open ? 420 : 760, open ? 760 : 420, 0.09f, [](float t) { return smooth(t / 0.02f) * std::exp(-t / 0.1f); }), 0, 0.5f);
	fade_edges(out, 1, 50);
	return out;
}

// --- Music ----------------------------------------------------------------------
// 96 BPM, 16 bars of 4/4 = 40 s exactly. D minor, one chord every two bars:
//   Dm  Bb  F  C  Dm  Bb  Gm  A

static const double BEAT = 60.0 / 96.0;
static const int BEATS = 64;
static const size_t LOOP = static_cast<size_t>(BEATS * BEAT * SR);

/// A sustained tone only loops cleanly if it completes whole cycles in the loop:
/// otherwise its phase jumps at the seam, which is a click every 40 seconds.
/// Rounding to the nearest multiple of 1/40 Hz moves a pitch by 0.0125 Hz at most.
static float loop_hz(float f) {
	const double cycle = static_cast<double>(SR) / LOOP;
	return static_cast<float>(std::round(f / cycle) * cycle);
}

struct Chord {
	float bass;
	float pad[4];
};
static const Chord CHORDS[8] = {
	{ 38, { 50, 57, 62, 65 } }, // Dm
	{ 34, { 50, 58, 62, 65 } }, // Bb
	{ 41, { 48, 57, 60, 65 } }, // F
	{ 36, { 48, 55, 60, 64 } }, // C
	{ 38, { 50, 57, 62, 65 } }, // Dm
	{ 34, { 50, 58, 62, 65 } }, // Bb
	{ 31, { 50, 55, 58, 62 } }, // Gm
	{ 33, { 49, 57, 61, 64 } }, // A
};

/// How loud chord `c` is at loop time `t`: full inside its two bars, cross-fading
/// into its neighbours over `overlap` seconds, and wrapping around the loop.
static float chord_gain(int c, double t, double overlap) {
	const double span = 8 * BEAT;
	const double total = BEATS * BEAT;
	double d = t - c * span; // time since this chord's start
	d = std::fmod(d + total, total);
	if (d > total - overlap) {
		d -= total; // just before the start: fading in
	}
	if (d < -overlap || d > span) {
		return 0.0f;
	}
	if (d < 0) {
		return smooth(static_cast<float>((d + overlap) / overlap));
	}
	if (d > span - overlap) {
		return 1.0f - smooth(static_cast<float>((d - (span - overlap)) / overlap));
	}
	return 1.0f;
}

static Stereo make_pad() {
	Stereo out{ Mono(LOOP, 0.0f), Mono(LOOP, 0.0f) };
	const double overlap = 1.6;
	for (int c = 0; c < 8; c++) {
		for (int n = 0; n < 4; n++) {
			for (int voice = 0; voice < 3; voice++) {
				const float cents = (voice - 1) * 7.0f;
				const float f = loop_hz(hz(CHORDS[c].pad[n]) * std::pow(2.0f, cents / 1200.0f));
				const float pan = 0.5f + 0.38f * (voice - 1) + 0.06f * (n - 1.5f);
				const float gl = std::cos(pan * float(PI) * 0.5f), gr = std::sin(pan * float(PI) * 0.5f);
				const double phase0 = 0.37 * (c * 12 + n * 3 + voice);
				for (size_t i = 0; i < LOOP; i++) {
					const double t = static_cast<double>(i) / SR;
					const float g = chord_gain(c, t, overlap);
					if (g <= 0.0f) {
						continue;
					}
					// From absolute time, not accumulated: exact at the seam whatever the rounding.
					const double phase = phase0 + 2.0 * PI * static_cast<double>(f) * t;
					// Brightness breathes over 20 s (two cycles per loop, so it loops too).
					const float bright = 1.75f - 0.35f * static_cast<float>(std::cos(2.0 * PI * t / 20.0));
					const float v = harmonic_tone(phase, f, 6, bright) * g * 0.05f;
					out.l[i] += v * gl;
					out.r[i] += v * gr;
				}
			}
		}
		// Bass: a soft sine with a little second harmonic under each chord.
		const float fb = loop_hz(hz(CHORDS[c].bass));
		for (size_t i = 0; i < LOOP; i++) {
			const double t = static_cast<double>(i) / SR;
			const float g = chord_gain(c, t, 0.6);
			if (g <= 0.0f) {
				continue;
			}
			const double ph = 2.0 * PI * static_cast<double>(fb) * t;
			const float v = (static_cast<float>(std::sin(ph)) + 0.25f * static_cast<float>(std::sin(2.0 * ph))) * g * 0.16f;
			out.l[i] += v;
			out.r[i] += v;
		}
	}
	return out;
}

/// Runs the loop through the reverb twice and keeps the second lap, so the tail
/// of the ending is already sounding under the beginning.
static void loop_reverb(Stereo &s, float room, float damp, float wet) {
	Reverb reverb(room, damp);
	Stereo lap = s;
	for (int pass = 0; pass < 2; pass++) {
		for (size_t i = 0; i < LOOP; i++) {
			float l, r;
			reverb.tick((s.l[i] + s.r[i]) * 0.5f, l, r);
			lap.l[i] = s.l[i] + l * wet;
			lap.r[i] = s.r[i] + r * wet;
		}
	}
	s = lap;
}

static void normalize_stereo(Stereo &s, float peak_db) {
	const float p = std::max(peak_of(s.l), peak_of(s.r));
	if (p > 1e-9f) {
		const float g = std::pow(10.0f, peak_db / 20.0f) / p;
		for (float &v : s.l) {
			v *= g;
		}
		for (float &v : s.r) {
			v *= g;
		}
	}
}

static Stereo make_music_calm() {
	Stereo out = make_pad();
	// A sparse bell line over the chords, with a dotted-eighth echo bouncing side to side.
	static const float line[32][2] = {
		{ 0, 74 }, { 2.5f, 81 }, { 4, 77 }, { 6.5f, 79 }, { 8, 77 }, { 10.5f, 74 }, { 12, 70 }, { 14.5f, 77 },
		{ 16, 72 }, { 18.5f, 81 }, { 20, 77 }, { 22.5f, 72 }, { 24, 76 }, { 26.5f, 79 }, { 28, 72 }, { 30.5f, 74 },
		{ 32, 74 }, { 34.5f, 81 }, { 36, 86 }, { 38.5f, 81 }, { 40, 82 }, { 42.5f, 77 }, { 44, 74 }, { 46.5f, 77 },
		{ 48, 79 }, { 50.5f, 74 }, { 52, 70 }, { 54.5f, 79 }, { 56, 76 }, { 58.5f, 73 }, { 60, 81 }, { 62.5f, 76 },
	};
	for (const auto &n : line) {
		const Mono note = bell(hz(n[1]), 2.2, CHIME_RATIOS, CHIME_AMPS, 0.9f, 6.0f);
		const double at = n[0] * BEAT;
		float gain = 0.085f;
		for (int echo = 0; echo < 4; echo++) {
			const float pan = echo == 0 ? 0.5f : (echo % 2 ? 0.2f : 0.8f);
			mix_wrap(out.l, note, at + echo * 0.75 * BEAT, gain * std::cos(pan * float(PI) * 0.5f));
			mix_wrap(out.r, note, at + echo * 0.75 * BEAT, gain * std::sin(pan * float(PI) * 0.5f));
			gain *= 0.42f;
		}
	}
	// Air: band-passed noise moving slowly; its period divides the loop.
	Rng rng(131);
	Svf fl, fr;
	for (size_t i = 0; i < LOOP; i++) {
		const double t = static_cast<double>(i) / SR;
		if ((i & 63) == 0) {
			fl.set(700.0f + 350.0f * static_cast<float>(std::sin(2.0 * PI * t / 10.0)), 0.8f);
			fr.set(820.0f + 380.0f * static_cast<float>(std::sin(2.0 * PI * t / 8.0 + 1.0)), 0.8f);
		}
		fl.tick(rng.bi());
		fr.tick(rng.bi());
		const float swell = 0.6f + 0.4f * static_cast<float>(std::sin(2.0 * PI * t / 20.0 + 2.0));
		out.l[i] += fl.band * 0.012f * swell;
		out.r[i] += fr.band * 0.012f * swell;
	}
	loop_reverb(out, 0.84f, 0.35f, 0.45f);
	normalize_stereo(out, -3.0f);
	return out;
}

static Stereo make_music_battle() {
	Stereo out{ Mono(LOOP, 0.0f), Mono(LOOP, 0.0f) };
	// Big low drum.
	Mono drum = seconds(0.6);
	mix(drum, glide_sine(0.55, 105, 46, 0.05f, [](float t) { return smooth(t / 0.002f) * std::exp(-t / 0.2f); }), 0, 1.0f);
	mix(drum, noise_sweep(0.12, 141, 0.8f, [](float) { return 900.0f; }, [](float t) { return std::exp(-t / 0.025f); }, true), 0, 0.7f);
	soft_clip(drum, 1.8f);
	fade_edges(drum, 0.5f, 60);
	// Smaller, higher drum for the off-beats and fills.
	Mono tom = seconds(0.35);
	mix(tom, glide_sine(0.3, 190, 95, 0.04f, [](float t) { return smooth(t / 0.002f) * std::exp(-t / 0.1f); }), 0, 1.0f);
	mix(tom, noise_sweep(0.08, 142, 0.9f, [](float) { return 1800.0f; }, [](float t) { return std::exp(-t / 0.015f); }, true), 0, 0.5f);
	fade_edges(tom, 0.5f, 40);
	// Shaker tick.
	Mono tick = noise_sweep(0.09, 143, 1.3f, [](float) { return 7200.0f; }, [](float t) { return smooth(t / 0.002f) * std::exp(-t / 0.022f); });
	fade_edges(tick, 0.5f, 20);

	for (int bar = 0; bar < 16; bar++) {
		const double b0 = bar * 4 * BEAT;
		mix_wrap(out.l, drum, b0, 0.6f);
		mix_wrap(out.r, drum, b0, 0.6f);
		mix_wrap(out.l, drum, b0 + 2.5 * BEAT, 0.42f);
		mix_wrap(out.r, drum, b0 + 2.5 * BEAT, 0.42f);
		mix_wrap(out.l, tom, b0 + 1.5 * BEAT, 0.3f);
		mix_wrap(out.r, tom, b0 + 1.5 * BEAT, 0.24f);
		mix_wrap(out.l, tom, b0 + 3.0 * BEAT, 0.24f);
		mix_wrap(out.r, tom, b0 + 3.0 * BEAT, 0.3f);
		if (bar % 4 == 3) { // a fill into the next four bars
			for (int s = 0; s < 4; s++) {
				const float g = 0.18f + 0.06f * s;
				mix_wrap(out.l, tom, b0 + (3.0 + s * 0.25) * BEAT, g * (s % 2 ? 0.7f : 1.0f));
				mix_wrap(out.r, tom, b0 + (3.0 + s * 0.25) * BEAT, g * (s % 2 ? 1.0f : 0.7f));
			}
		}
		for (int e = 0; e < 8; e++) {
			const float g = (e % 2 == 0 ? 0.05f : 0.085f) * (e == 7 ? 1.3f : 1.0f);
			mix_wrap(out.l, tick, b0 + e * 0.5 * BEAT, g * (e % 2 ? 1.0f : 0.6f));
			mix_wrap(out.r, tick, b0 + e * 0.5 * BEAT, g * (e % 2 ? 0.6f : 1.0f));
		}
		// Eighth-note pulse on the chord's root, an octave above the bass.
		const Chord &chord = CHORDS[bar / 2];
		for (int e = 0; e < 8; e++) {
			const float f = hz(chord.bass + 12 + ((e == 3 || e == 6) ? 7 : 0));
			Mono pluck = seconds(0.3);
			Svf lp;
			double phase = 0;
			for (size_t i = 0; i < pluck.size(); i++) {
				const float t = static_cast<float>(i) / SR;
				phase += 2.0 * PI * f / SR;
				if ((i & 15) == 0) {
					lp.set(180.0f + 1500.0f * std::exp(-t / 0.05f), 1.2f);
				}
				lp.tick(harmonic_tone(phase, f, 10, 1.0f));
				pluck[i] = lp.low * smooth(t / 0.003f) * std::exp(-t / 0.13f);
			}
			fade_edges(pluck, 0.5f, 40);
			const float g = e % 2 == 0 ? 0.2f : 0.13f;
			mix_wrap(out.l, pluck, b0 + e * 0.5 * BEAT, g);
			mix_wrap(out.r, pluck, b0 + e * 0.5 * BEAT, g);
		}
	}
	loop_reverb(out, 0.6f, 0.5f, 0.16f);
	normalize_stereo(out, -3.0f);
	return out;
}

// --- Files ----------------------------------------------------------------------

static bool write_wav(const std::string &path, const Mono *channels[], int channel_count) {
	const size_t frames = channels[0]->size();
	FILE *f = std::fopen(path.c_str(), "wb");
	if (f == nullptr) {
		std::fprintf(stderr, "cannot write %s\n", path.c_str());
		return false;
	}
	const uint32_t data_bytes = static_cast<uint32_t>(frames * channel_count * 2);
	const uint32_t riff_bytes = 36 + data_bytes;
	const uint16_t format = 1, channels16 = static_cast<uint16_t>(channel_count), bits = 16;
	const uint16_t block = static_cast<uint16_t>(channel_count * 2);
	const uint32_t rate = SR, byte_rate = SR * block, fmt_bytes = 16;
	std::fwrite("RIFF", 1, 4, f);
	std::fwrite(&riff_bytes, 4, 1, f);
	std::fwrite("WAVEfmt ", 1, 8, f);
	std::fwrite(&fmt_bytes, 4, 1, f);
	std::fwrite(&format, 2, 1, f);
	std::fwrite(&channels16, 2, 1, f);
	std::fwrite(&rate, 4, 1, f);
	std::fwrite(&byte_rate, 4, 1, f);
	std::fwrite(&block, 2, 1, f);
	std::fwrite(&bits, 2, 1, f);
	std::fwrite("data", 1, 4, f);
	std::fwrite(&data_bytes, 4, 1, f);
	std::vector<int16_t> pcm(frames * channel_count);
	for (size_t i = 0; i < frames; i++) {
		for (int c = 0; c < channel_count; c++) {
			const float v = std::min(1.0f, std::max(-1.0f, (*channels[c])[i]));
			pcm[i * channel_count + c] = static_cast<int16_t>(std::lround(v * 32767.0f));
		}
	}
	std::fwrite(pcm.data(), 2, pcm.size(), f);
	std::fclose(f);
	return true;
}

static bool save(const std::string &dir, const char *name, Mono sound, float peak_db = -1.0f) {
	fade_edges(sound, 0.0f, 80.0f); // a reverb tail is cut somewhere: make sure it is cut at silence
	normalize(sound, peak_db);
	const Mono *channels[1] = { &sound };
	std::printf("%-16s %5.2f s\n", name, static_cast<double>(sound.size()) / SR);
	return write_wav(dir + "/" + name + ".wav", channels, 1);
}

static bool save(const std::string &dir, const char *name, const Stereo &sound) {
	const Mono *channels[2] = { &sound.l, &sound.r };
	std::printf("%-16s %5.2f s (stereo loop, %zu frames)\n", name, static_cast<double>(sound.l.size()) / SR, sound.l.size());
	return write_wav(dir + "/" + name + ".wav", channels, 2);
}

int main(int argc, char **argv) {
	const std::string dir = argc > 1 ? argv[1] : "game/audio";
	const std::string music_dir = argc > 2 ? argv[2] : "/tmp";
	bool ok = true;
	ok &= save(dir, "bolt_fire", make_bolt_fire());
	ok &= save(dir, "bolt_water", make_bolt_water());
	ok &= save(dir, "wave_fire", make_wave_fire());
	ok &= save(dir, "wave_water", make_wave_water());
	ok &= save(dir, "shield_up", make_shield(true));
	ok &= save(dir, "shield_down", make_shield(false));
	ok &= save(dir, "shield_block", make_shield_block());
	ok &= save(dir, "hit_fire", make_hit(true));
	ok &= save(dir, "hit_water", make_hit(false));
	ok &= save(dir, "clash", make_clash());
	ok &= save(dir, "heal", make_heal());
	ok &= save(dir, "count", make_count());
	ok &= save(dir, "fight", make_fight());
	ok &= save(dir, "ko", make_ko());
	ok &= save(dir, "victory", make_victory());
	ok &= save(dir, "join", make_two_notes(81, 86, 0.6f));
	ok &= save(dir, "leave", make_two_notes(81, 76, 0.6f));
	ok &= save(dir, "fizzle", make_fizzle());
	ok &= save(dir, "ui_move", make_ui_move());
	ok &= save(dir, "ui_select", make_ui_select());
	ok &= save(dir, "ui_open", make_ui_panel(true));
	ok &= save(dir, "ui_close", make_ui_panel(false));
	ok &= save(music_dir, "music_calm", make_music_calm());
	ok &= save(music_dir, "music_battle", make_music_battle());
	return ok ? 0 : 1;
}
