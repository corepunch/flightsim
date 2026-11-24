// Arcline's instrumental loops, rendered entirely with synthesized instruments.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr int sampleRate = 44100;
constexpr double tau = 6.283185307179586;
using Pattern = std::array<int, 16>;

enum Style { redline, apex, slipstream, pitLane };
enum class Voice { bass, pad, keys, lead, pluck };
enum class Drum { kick, snare, hat, openHat, tom, sweep };

struct Chord {
    int bass;
    std::array<int, 4> voicing;
};

struct Song {
    const char* file;
    Style style;
    int bpm;
    int tonic;
    int bars;
    double swing;
    std::array<Chord, 8> chords;
    std::array<Pattern, 4> hook;
};

// Hook patterns use minor-scale degrees. 0 is a rest, and 8 is the octave.
const std::array<Song, 4> songs{{
    {"music-race-redline", redline, 148, 66, 32, 0.010,
     {{{42, {57, 61, 64, 68}}, {38, {57, 61, 62, 66}}, {45, {57, 59, 61, 64}}, {40, {56, 59, 64, 66}},
       {47, {59, 62, 66, 69}}, {38, {57, 61, 62, 66}}, {45, {57, 59, 61, 64}}, {37, {56, 59, 61, 65}}}},
     {{{0,0,5,0,0,0,8,0,0,7,0,5,0,0,3,0}, {0,0,6,0,0,8,0,10,0,0,9,0,6,0,0,0},
       {0,0,5,0,0,0,9,0,0,8,0,10,0,0,0,0}, {7,0,0,0,5,0,0,4,0,0,2,0,0,0,0,0}}}},
    {"music-race-apex", apex, 156, 64, 32, 0.032,
     {{{40, {55, 59, 62, 66}}, {43, {55, 59, 62, 69}}, {38, {54, 57, 62, 64}}, {45, {55, 57, 60, 64}},
       {36, {55, 59, 60, 64}}, {43, {55, 59, 62, 69}}, {45, {55, 57, 60, 64}}, {35, {54, 57, 59, 63}}}},
     {{{0,0,0,3,0,5,0,0,8,0,0,7,0,0,5,0}, {0,0,0,3,0,5,0,0,10,0,0,9,0,7,0,0},
       {0,0,4,0,0,7,0,0,9,0,8,0,0,0,0,0}, {0,0,8,0,0,0,5,0,0,0,4,0,2,0,0,0}}}},
    {"music-race-slipstream", slipstream, 136, 57, 32, 0.042,
     {{{45, {55, 60, 64, 71}}, {41, {57, 60, 64, 67}}, {36, {55, 59, 62, 64}}, {43, {55, 59, 62, 69}},
       {38, {57, 60, 64, 65}}, {41, {57, 60, 64, 67}}, {36, {55, 59, 62, 64}}, {40, {56, 59, 62, 65}}}},
     {{{0,10,0,0,0,0,12,0,0,10,0,8,0,0,5,0}, {0,8,0,0,0,10,0,0,13,0,0,12,0,10,0,0},
       {0,10,0,0,0,0,12,0,0,14,0,12,0,10,0,0}, {0,9,0,0,0,12,0,0,11,0,0,9,0,0,0,0}}}},
    {"music-menu-pit-lane", pitLane, 112, 54, 24, 0.052,
     {{{42, {57, 61, 64, 68}}, {38, {57, 61, 64, 66}}, {45, {56, 59, 61, 64}}, {40, {56, 59, 64, 66}},
       {47, {57, 61, 62, 66}}, {38, {57, 61, 64, 66}}, {45, {56, 59, 61, 64}}, {37, {56, 59, 61, 66}}}},
     {{{0,0,0,0,9,0,0,0,8,0,0,0,7,0,0,0}, {0,0,0,0,6,0,0,8,0,0,10,0,0,0,0,0},
       {0,0,8,0,0,0,10,0,0,12,0,0,0,0,0,0}, {0,0,9,0,0,0,7,0,0,5,0,0,0,0,0,0}}}}
}};

struct Stereo {
    float left = 0;
    float right = 0;

    Stereo operator*(float level) const { return {left * level, right * level}; }
    Stereo& operator+=(Stereo value) {
        left += value.left;
        right += value.right;
        return *this;
    }
};

Stereo pan(double position) {
    return {float(std::sqrt(1 - position)), float(std::sqrt(1 + position))};
}

// Band-limit the oscillator discontinuity at the current pitch.
double blep(double phase, double step) {
    if (phase < step) {
        const double x = phase / step;
        return 2 * x - x * x - 1;
    }
    if (phase > 1 - step) {
        const double x = (phase - 1) / step;
        return x * x + 2 * x + 1;
    }
    return 0;
}

struct Oscillator {
    double phase;

    void advance(double step) {
        phase += step;
        if (phase >= 1) phase -= 1;
    }
    double saw(double step) const { return 2 * phase - 1 - blep(phase, step); }
    double pulse(double step, double width) const {
        const double edge = phase - width + (phase < width ? 1 : 0);
        return (phase < width ? 1 : -1) + blep(phase, step) - blep(edge, step);
    }
};

struct LowPass {
    void tune(double hz, double resonance) {
        const double g = std::tan(tau * 0.5 * hz / sampleRate);
        const double k = 1 / resonance;
        a = 1 / (1 + g * (g + k));
        b = g * a;
        c = g * b;
    }
    double process(double input) {
        const double delta = input - low;
        const double v1 = a * band + b * delta;
        const double v2 = low + b * band + c * delta;
        band = 2 * v1 - band;
        low = 2 * v2 - low;
        return v2;
    }

private:
    double a = 0, b = 0, c = 0;
    double band = 0, low = 0;
};

struct OnePole {
    explicit OnePole(double hz) : rate(1 - std::exp(-tau * hz / sampleRate)) {}
    double process(double input) { return memory += rate * (input - memory); }

private:
    double rate;
    double memory = 0;
};

struct Envelope {
    double attack, decay, sustain, release;

    double held(double time) const {
        if (time < attack) return time / attack;
        return sustain + (1 - sustain) * std::exp(-(time - attack) / decay);
    }
    double value(double time, double gate) const {
        if (time <= gate) return held(time);
        const double fade = std::max(0.0, 1 - (time - gate) / release);
        return held(gate) * fade * fade;
    }
};

Envelope envelope(Voice voice, Style style) {
    switch (voice) {
    case Voice::bass: return {0.005, 0.105, 0.76, 0.078};
    case Voice::pad: return {style == pitLane ? 0.42 : 0.23, 0.68, 0.78, 0.68};
    case Voice::keys: return {0.004, 0.19, 0.35, 0.34};
    case Voice::lead: return {0.014, 0.19, 0.66, 0.20};
    case Voice::pluck: return {0.006, 0.15, 0.21, 0.18};
    }
    throw std::logic_error("Unknown synth voice");
}

class Room {
    struct Comb {
        explicit Comb(int frames) : delay(frames) {}
        float process(float input) {
            const float reflection = delay[position];
            damping += 0.28f * (reflection - damping);
            delay[position] = input + 0.68f * damping;
            if (++position == delay.size()) position = 0;
            return reflection;
        }
        std::vector<float> delay;
        size_t position = 0;
        float damping = 0;
    };
    std::array<Comb, 4> left{{Comb(1499), Comb(1949), Comb(2539), Comb(3019)}};
    std::array<Comb, 4> right{{Comb(1607), Comb(2081), Comb(2687), Comb(3217)}};
    OnePole lowLeft{240}, lowRight{240};
    OnePole highLeft{5200}, highRight{5200};

public:
    Stereo process(Stereo send) {
        float l = 0, r = 0;
        for (size_t i = 0; i < left.size(); ++i) {
            l += left[i].process(send.left + 0.19f * send.right) * 0.24f;
            r += right[i].process(send.right + 0.19f * send.left) * 0.24f;
        }
        return {float(highLeft.process(l - lowLeft.process(l))), float(highRight.process(r - lowRight.process(r)))};
    }
};

class Mix {
    const Song& song;
    double beat;
    std::vector<Stereo> drums, bass, instruments, roomSend;
    std::vector<float> duck;
    std::mt19937 noise{7405};

    size_t frameAt(double beats) const { return size_t(std::llround(beats * beat * sampleRate)); }
    double random() { return double(noise()) / 4294967296.0; }
    void add(std::vector<Stereo>& bus, size_t frame, Stereo value) { bus[frame % bus.size()] += value; }

    void sidechain(size_t offset, double level) {
        const double length = beat * (song.style == apex ? 0.52 : 0.57);
        for (size_t i = 0; i < size_t(length * sampleRate); ++i) {
            const double x = double(i) / (length * sampleRate);
            const float depth = float(level * std::min(x * 65, 1.0) * std::pow(1 - x, 2.4));
            auto& current = duck[(offset + i) % duck.size()];
            current = std::max(current, depth);
        }
    }

public:
    explicit Mix(const Song& song)
        : song(song), beat(60.0 / song.bpm), drums(frameAt(song.bars * 4)), bass(drums.size()),
          instruments(drums.size()), roomSend(drums.size()), duck(drums.size()) {}

    void note(Voice voice, double start, double length, int midi, double volume, double position, double color = 0.65) {
        const Style style = song.style;
        const double hz = 440 * std::exp2((midi - 69) / 12.0);
        const double gate = length * beat;
        const Envelope env = envelope(voice, style);
        const size_t offset = frameAt(start);
        const size_t echo = frameAt(0.75);
        const size_t frames = size_t((gate + env.release) * sampleRate);
        const Stereo balance = pan(position);
        const double step = hz / sampleRate;
        Oscillator center{random()}, left{random()}, right{random()}, layer{random()};
        const double drift = random() * tau;
        const double detune = voice == Voice::pad ? 0.0058 : 0.0037;
        LowPass filterLeft, filterRight;
        OnePole wetLeft{3100}, wetRight{3100};
        for (size_t i = 0; i < frames; ++i) {
            const double t = double(i) / sampleRate;
            const double phase = tau * center.phase;
            const double motion = std::sin(tau * 0.54 * t + drift);
            const double bend = 1 + 0.0025 * motion - 0.006 * std::exp(-36 * t);
            const double waveStep = step * bend;
            const double snap = std::exp(-16 * t);
            double cutoff = 4200, resonance = 0.73;
            double l = 0, r = 0;
            switch (voice) {
            case Voice::bass: {
                // The center oscillator carries the sub; detuned upper voices add color in stereo.
                const double sub = 0.82 * std::sin(tau * hz * t);
                const double pulse = center.pulse(waveStep, 0.44 + 0.09 * motion);
                const double grit = style == apex ? 0.75 : (style == pitLane ? 0.25 : 0.52);
                const double mid = std::tanh(1.55 * (0.53 * pulse + 0.47 * layer.saw(2 * waveStep)));
                l = sub + grit * (mid + 0.25 * left.saw(waveStep * (1 - detune)));
                r = sub + grit * (mid + 0.25 * right.saw(waveStep * (1 + detune)));
                cutoff = 120 + 360 * color + 920 * snap * color + (style == apex ? 420 * (1 + motion) : 0);
                resonance = style == apex ? 1.08 : 0.72;
                break;
            }
            case Voice::pad: {
                const double warmth = 0.28 * std::sin(phase) + 0.16 * layer.pulse(2 * waveStep, 0.43 + 0.1 * motion);
                l = warmth + 0.66 * left.saw(waveStep * (1 - detune));
                r = warmth + 0.66 * right.saw(waveStep * (1 + detune));
                cutoff = 590 + color * (1200 + 420 * motion) + 240 * std::sin(tau * 0.21 * t);
                resonance = 0.83;
                break;
            }
            case Voice::keys: {
                // A short, bright tine over a longer vibrating body, with stereo tremolo.
                const double tine = 0.27 * std::sin(phase * 3 + 0.8 * std::sin(phase * 7)) * std::exp(-13 * t);
                const double body = std::sin(phase + (0.36 + 1.15 * std::exp(-7.3 * t)) * std::sin(phase * 2));
                const double tremolo = 0.16 * std::sin(tau * 3.9 * t + drift);
                l = (0.84 * body + tine) * (1 + tremolo);
                r = (0.84 * body + tine) * (1 - tremolo);
                cutoff = 1250 + 3400 * color * std::exp(-4 * t);
                break;
            }
            case Voice::lead: {
                if (style == redline) {
                    const double core = 0.40 * center.pulse(waveStep, 0.48 + 0.08 * motion) + 0.22 * std::sin(phase);
                    l = core + 0.58 * left.saw(waveStep * (1 - detune));
                    r = core + 0.58 * right.saw(waveStep * (1 + detune));
                } else {
                    const double reed = std::sin(phase + (0.48 + 1.1 * snap) * std::sin(phase * 2));
                    l = 0.74 * reed + 0.26 * left.pulse(waveStep * (1 - detune), 0.57);
                    r = 0.74 * reed + 0.26 * right.pulse(waveStep * (1 + detune), 0.57);
                }
                cutoff = 860 + 1690 * color + (1500 + 700 * motion) * std::exp(-7 * t);
                resonance = 0.88;
                break;
            }
            case Voice::pluck: {
                const double core = std::sin(phase + (0.28 + 1.35 * std::exp(-10 * t)) * std::sin(phase * 3));
                l = 0.83 * core + 0.23 * left.saw(waveStep * (1 - detune));
                r = 0.83 * core + 0.23 * right.saw(waveStep * (1 + detune));
                cutoff = 800 + 790 * color + 2300 * snap;
                break;
            }
            }
            if (i % 16 == 0) {
                filterLeft.tune(cutoff, resonance);
                filterRight.tune(cutoff * 1.026, resonance);
            }
            const double level = env.value(t, gate) * volume;
            const Stereo direct{float(filterLeft.process(l) * level * balance.left),
                                float(filterRight.process(r) * level * balance.right)};
            if (voice == Voice::bass) {
                add(bass, offset + i, direct);
            } else {
                add(instruments, offset + i, direct);
                add(roomSend, offset + i, direct * (voice == Voice::pad ? 0.35f : 0.30f));
                if (voice == Voice::lead || voice == Voice::pluck || voice == Voice::keys) {
                    const Stereo wet{float(wetLeft.process(direct.left)), float(wetRight.process(direct.right))};
                    add(instruments, offset + i + echo, Stereo{wet.right, wet.left} * 0.21f);
                    add(roomSend, offset + i + 2 * echo, wet * 0.21f);
                }
            }
            center.advance(waveStep);
            left.advance(waveStep * (1 - detune));
            right.advance(waveStep * (1 + detune));
            layer.advance(2 * waveStep);
        }
    }

    void drum(Drum drum, double start, double volume, double position = 0, double texture = 0.5) {
        const Style style = song.style;
        const size_t offset = frameAt(start);
        const bool menu = style == pitLane;
        const double length = drum == Drum::sweep ? 1.5 * beat :
            drum == Drum::hat ? 0.082 : drum == Drum::openHat ? 0.24 : 0.33;
        const Stereo balance = pan(position);
        OnePole low{drum == Drum::snare ? 900.0 : 5100.0};
        OnePole air{drum == Drum::hat ? 10400.0 : 7900.0};
        OnePole body{2300};
        LowPass sweep;
        const double shift = 0.96 + 0.08 * random();
        if (drum == Drum::kick) sidechain(offset, std::min(volume * 1.35, 1.0));
        for (size_t i = 0; i < size_t(length * sampleRate); ++i) {
            const double t = double(i) / sampleRate;
            const double white = 2 * random() - 1;
            const double high = air.process(white - low.process(white));
            double tone = 0;
            switch (drum) {
            case Drum::kick: {
                const double hz = menu ? 52 : (style == apex ? 47 : 51);
                const double phase = tau * (hz * t + 2.25 * (1 - std::exp(-74 * t)) + 0.52 * (1 - std::exp(-340 * t)));
                const double bottom = std::sin(phase) * std::exp(-(style == apex ? 14 : 16) * t);
                const double punch = 0.30 * std::sin(2 * phase) * std::exp(-55 * t);
                tone = std::tanh(1.32 * (bottom + punch)) + (0.34 * high + 0.17 * body.process(white)) * std::exp(-255 * t);
                break;
            }
            case Drum::snare: {
                const double hz = (menu ? 240 : (style == apex ? 178 : 204)) * shift;
                const double first = std::sin(tau * hz * t) * std::exp(-39 * t);
                const double second = std::sin(tau * 1.68 * hz * t) * std::exp(-62 * t);
                const double clap = 0.32 * std::exp(-220 * std::abs(t - 0.009)) + 0.24 * std::exp(-218 * std::abs(t - 0.019));
                const double tail = std::exp(-(menu ? 39 : 22) * t);
                tone = (0.35 * first + 0.18 * second + (1.69 * high + 0.55 * body.process(white)) * (tail + clap));
                break;
            }
            case Drum::hat:
            case Drum::openHat: {
                const double metal = std::sin(tau * 6181 * shift * t) * std::sin(tau * 3671 * t)
                    + 0.53 * std::sin(tau * 8929 * t) * std::sin(tau * 2377 * shift * t);
                const double decay = drum == Drum::hat ? 65 + 40 * texture : 18 + 10 * texture;
                tone = (2.1 * high + 0.17 * metal) * std::exp(-decay * t);
                break;
            }
            case Drum::tom: {
                const double phase = tau * ((82 + 38 * texture) * t + 0.9 * (1 - std::exp(-47 * t)));
                tone = 0.73 * std::sin(phase) * std::exp(-22 * t) + 0.65 * high * std::exp(-67 * t);
                break;
            }
            case Drum::sweep: {
                const double rise = t / length;
                if (i % 16 == 0) sweep.tune(450 + 5400 * rise * rise, 1.4);
                tone = (sweep.process(white) - 0.47 * body.process(white)) * rise * rise;
                break;
            }
            }
            const double edge = std::min(1.0, std::min(t / 0.0011, (length - t) / 0.019));
            const double level = tone * volume * edge;
            const Stereo sound{float(level * balance.left), float(level * balance.right)};
            add(drums, offset + i, sound);
            if (drum != Drum::kick) add(roomSend, offset + i, sound * (drum == Drum::snare ? 0.22f : 0.12f));
        }
    }

    void write(const std::string& path) const {
        Room room;
        OnePole dcLeft{23}, dcRight{23}, sheenLeft{4400}, sheenRight{4400};
        std::vector<Stereo> master(drums.size());
        double energy = 0;
        // Pre-roll the filters and room with the end of the loop, so ambience survives the wrap.
        for (size_t n = drums.size() - 2 * sampleRate; n < 2 * drums.size(); ++n) {
            const size_t i = n % drums.size();
            const float kick = duck[i];
            Stereo sample = drums[i];
            sample += bass[i] * (1 - 0.66f * kick);
            sample += instruments[i] * (1 - 0.46f * kick);
            sample += room.process(roomSend[i]) * (0.61f - 0.20f * kick);
            sample.left -= float(dcLeft.process(sample.left));
            sample.right -= float(dcRight.process(sample.right));
            sample.left += 0.083f * (sample.left - float(sheenLeft.process(sample.left)));
            sample.right += 0.083f * (sample.right - float(sheenRight.process(sample.right)));
            if (n >= drums.size()) {
                master[i] = sample;
                energy += sample.left * sample.left + sample.right * sample.right;
            }
        }
        const double rms = std::sqrt(energy / (2 * master.size()));
        const double gain = (song.style == pitLane ? 0.15 : 0.183) / rms;
        std::vector<float> envelope(master.size());
        double peak = 0;
        for (size_t n = master.size() + 2205; n > 0; --n) {
            const size_t i = (n - 1) % master.size();
            peak = std::max(gain * std::max(std::abs(master[i].left), std::abs(master[i].right)), peak * 0.995);
            envelope[i] = float(peak);
        }
        writeWave(path, master, envelope, gain);
    }

private:
    static void writeWave(const std::string& path, const std::vector<Stereo>& master,
                          const std::vector<float>& envelope, double gain) {
        std::ofstream output(path, std::ios::binary);
        const auto word = [&](uint32_t value, int bytes) {
            for (int i = 0; i < bytes; ++i) output.put(char((value >> (8 * i)) & 0xff));
        };
        const auto dataBytes = uint32_t(master.size() * 4);
        output.write("RIFF", 4);
        word(36 + dataBytes, 4);
        output.write("WAVEfmt ", 8);
        word(16, 4); word(1, 2); word(2, 2); word(sampleRate, 4); word(sampleRate * 4, 4);
        word(4, 2); word(16, 2);
        output.write("data", 4);
        word(dataBytes, 4);
        constexpr float ceiling = 0.70f;
        double limiter = 1;
        // Start from the previous pass's end so gain is stable at the loop point.
        for (size_t n = master.size() - sampleRate / 2; n < 2 * master.size(); ++n) {
            const size_t i = n % master.size();
            const double target = ceiling / std::max(ceiling, envelope[i]);
            limiter = std::min(target, limiter + (1 - limiter) * 0.00042);
            if (n < master.size()) continue;
            // Fade only the outer 4 ms to suppress encoder transients on repeat.
            const size_t edge = std::min(i, master.size() - 1 - i);
            const double fade = std::min(1.0, edge / (0.004 * sampleRate));
            const double level = 32767 * 0.95 * limiter * gain * (0.5 - 0.5 * std::cos(tau * 0.5 * fade));
            word(uint16_t(std::lround(level * master[i].left)), 2);
            word(uint16_t(std::lround(level * master[i].right)), 2);
        }
        if (!output) throw std::runtime_error("Could not write " + path);
    }
};

struct Groove {
    Pattern kick, snare, hats, bass;
};

// Drum values are accents on a ten-point scale. Bass values select register or interval.
constexpr std::array<Groove, 4> grooves{{
    {{10,0,0,0,9,0,0,0,10,0,0,0,9,0,0,0}, {0,0,0,0,8,0,0,0,0,0,0,0,9,0,0,2},
     {0,2,8,0,3,0,7,3,0,2,8,0,3,0,7,4}, {0,0,1,1,0,0,1,0,0,0,1,2,0,0,1,3}},
    {{10,0,0,0,0,0,6,0,0,0,9,0,0,0,5,0}, {0,0,0,2,10,0,0,0,0,3,0,2,9,0,0,0},
     {5,2,7,0,0,4,0,5,6,0,6,3,0,2,8,4}, {1,0,0,2,0,0,1,0,0,1,0,2,0,0,3,0}},
    {{10,0,0,0,8,0,0,0,9,0,0,0,8,0,0,0}, {0,0,0,0,8,0,0,0,0,0,0,0,9,0,2,0},
     {3,0,8,3,2,0,7,2,4,0,8,3,2,0,8,2}, {1,0,0,2,0,1,0,0,1,0,3,0,0,1,0,2}},
    {{9,0,0,0,0,0,3,0,0,0,7,0,0,0,0,0}, {0,0,0,0,6,0,0,0,0,0,0,2,8,0,0,0},
     {3,0,6,0,0,2,5,0,3,0,5,3,0,0,6,0}, {1,0,0,0,0,0,2,0,0,0,1,0,3,0,0,0}}
}};

struct Section {
    double drums, bass, chords, hook, color;
};

Section section(const Song& song, int bar) {
    switch (song.style) {
    case redline:
        if (bar < 4) return {0.92, 0.96, 0.85, 0.20, 0.43};
        if (bar < 16) return {1, 1, 0.90, 1, 0.78};
        if (bar < 20) return {0.12, 0.25, 1.17, 0.62, 0.40};
        if (bar < 24) return {0.72, 0.84, 1.08, 0.75, 0.61};
        return {1.03, 1.04, 1.02, 1.05, 0.86};
    case apex:
        if (bar < 4) return {0.96, 0.75, 0.72, 0.35, 0.55};
        if (bar < 12) return {1.08, 1, 0.78, 0.87, 0.86};
        if (bar < 16) return {0.93, 1.03, 0.58, 0.43, 0.68};
        if (bar < 20) return {0.63, 0.64, 1, 0.83, 0.52};
        return {1.12, 1.06, 0.70, 0.93, 0.93};
    case slipstream:
        if (bar < 8) return {0.95, 0.90, 1, 0.54, 0.61};
        if (bar < 16) return {1, 1.02, 1.06, 1, 0.82};
        if (bar < 20) return {0.25, 0.43, 0.80, 0.66, 0.47};
        return {1.02, 1.02, 1.08, 0.90, 0.89};
    case pitLane:
        if (bar < 8) return {0.84, 0.88, 1.05, 0.81, 0.50};
        if (bar < 16) return {0.98, 1, 0.92, 0.96, 0.63};
        if (bar < 20) return {0.23, 0.49, 1.03, 0.77, 0.42};
        return {0.72, 0.79, 0.96, 0.85, 0.56};
    }
    throw std::logic_error("Unknown arrangement");
}

void arrange(const Song& song, const std::string& folder) {
    const Style style = song.style;
    const bool menu = style == pitLane;
    const auto& groove = grooves[style];
    constexpr std::array scale{0, 2, 3, 5, 7, 8, 10};
    Mix mix(song);
    for (int bar = 0; bar < song.bars; ++bar) {
        const double start = 4 * bar;
        const Chord& chord = song.chords[bar % 8];
        const Chord& next = song.chords[(bar + 1) % 8];
        const Section part = section(song, bar);
        const bool phraseEnd = bar % 4 == 3;
        const bool turnaround = bar % 8 == 7;
        const bool breakdown = part.drums < 0.7;
        const bool lastPhrase = bar >= song.bars - 8;

        for (size_t i = 0; i < chord.voicing.size(); ++i) {
            // Spread the chord voices and open the top voicing on alternate phrases.
            const int note = chord.voicing[i] + (i == 3 && bar % 8 >= 4 ? 12 : 0);
            mix.note(Voice::pad, start + i * 0.024, 3.64, note,
                     part.chords * (menu ? 0.087 : 0.065), (double(i) - 1.5) * 0.40, part.color);
        }
        if (turnaround && !menu) mix.drum(Drum::sweep, start + 2.5, 0.15 * part.chords, -0.07);

        for (int step = 0; step < 16; ++step) {
            const double time = start + step * 0.25 + (step % 2 ? song.swing : 0);
            const double accent = std::array{1.0, 0.81, 0.92, 0.77}[step % 4] *
                (0.97 + 0.03 * std::sin(step * 1.9 + bar * 2.7));
            int kick = groove.kick[step];
            int snare = groove.snare[step];
            if (breakdown && step != 0 && step != 8) kick = 0;
            if (style == apex && (bar < 4 || breakdown)) {
                kick = step == 0 ? 10 : step == 10 ? 7 : 0;
                snare = step == 8 ? 10 : step == 14 ? 3 : 0;
            }
            // Leave air before each phrase returns to beat one.
            if (turnaround && step >= 12) kick = 0;
            if (kick) mix.drum(Drum::kick, time, 0.085 * kick * part.drums);
            if (snare && (!breakdown || step >= 8))
                mix.drum(Drum::snare, time + (style == apex ? 0.012 : 0.020),
                         (menu ? 0.060 : 0.079) * snare * part.drums, step % 4 == 0 ? 0.02 : -0.19);
            const int hat = groove.hats[step];
            if (hat && (!breakdown || step % 4 != 1)) {
                const bool open = hat >= 7 && (step % 8 == 2 || lastPhrase || style == slipstream);
                const double position = step % 4 == 2 ? 0.32 : -0.35;
                mix.drum(open ? Drum::openHat : Drum::hat, time + 0.010, (menu ? 0.053 : 0.060) * hat * part.drums,
                         position, accent);
            }
            if (turnaround && (step == 12 || step == 14 || step == 15))
                mix.drum(Drum::tom, time, (menu ? 0.19 : 0.38) * part.drums * accent,
                         (step - 14) * 0.23, (step - 12) / 3.0);
            if (style == apex && phraseEnd && step == 13 && !turnaround)
                mix.drum(Drum::snare, time, 0.20 * part.drums, 0.33);

            const int pulse = groove.bass[step];
            if (pulse && (!breakdown || step % 4 == 0 || step == 10)) {
                int note = chord.bass - 12;
                if (pulse == 2) note += (style == apex && step != 11 ? 7 : 12);
                if (pulse == 3) note = turnaround ? next.bass - 13 : note + 7;
                if (note < 28) note += 12;
                const double gate = menu ? 0.44 : style == apex ? 0.32 : style == redline ? 0.16 : 0.22;
                mix.note(Voice::bass, time + 0.017, gate, note, (menu ? 0.31 : 0.42) * part.bass * accent,
                         0, part.color * accent);
            }

            const bool keys = (style == slipstream && (step == 2 || step == 7 || step == 11 || step == 14)) ||
                              (menu && (step == 0 || step == 6 || (step == 11 && bar % 2 == 0)));
            if (keys) {
                for (size_t i = 0; i < chord.voicing.size(); ++i) {
                    const double strum = i * (menu ? 0.026 : 0.012);
                    mix.note(Voice::keys, time + strum, menu ? 0.91 : (step == 2 ? 0.58 : 0.27),
                             chord.voicing[i], 0.14 * part.chords * accent, (double(i) - 1.5) * 0.35, part.color);
                }
            }
            const bool arp = (style == redline && (step % 4 == 0 || (step % 4 == 3 && lastPhrase))) ||
                             (style == apex && (step == 2 || step == 9) && (breakdown || bar < 8));
            if (arp) {
                const int note = chord.voicing[(step / 2 + bar) % 4] + (step % 4 == 3 ? 12 : 0);
                mix.note(Voice::pluck, time + 0.026, 0.38, note, (breakdown ? 0.19 : 0.12) * accent,
                         step % 4 == 0 ? -0.30 : 0.33, part.color);
            }

            const Pattern& melody = song.hook[bar % 4];
            const int degree = melody[step] - 1;
            if (degree >= 0 && (!breakdown || step % 2 == 0 || menu)) {
                int note = song.tonic + scale[degree % 7] + (degree / 7) * 12;
                if (turnaround && degree % 7 == 6) ++note;
                const bool sustained = step < 14 && !melody[step + 1] && !melody[step + 2];
                const double gate = menu ? 0.68 : sustained ? 0.53 : 0.27;
                const Voice voice = menu ? Voice::keys : style == slipstream ? Voice::pluck : Voice::lead;
                mix.note(voice, time + 0.028, gate, note, (menu ? 0.20 : 0.30) * part.hook * accent,
                         -0.11, part.color);
                if (style == redline && lastPhrase && sustained)
                    mix.note(Voice::lead, time + 0.057, gate, note - 12, 0.083, 0.30, part.color * 0.55);
            }
        }
    }
    mix.write(folder + "/" + song.file + ".wav");
}
} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "Usage: synth-music <output directory>\n";
        return 1;
    }
    for (const auto& song : songs) arrange(song, argv[1]);
}
