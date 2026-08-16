#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

namespace {
using Pixel = std::array<int, 3>;

struct Pending {
    bool valid = false;
    bool last = false;
    int bits = 8;
    int version = 2;
    int primary_qp = 0;
    int qy = 0;
    int qc = 0;
    bool force_mpp = false;
    bool next_very_flat = false;
    std::array<int, 3> vlc_size{};
    std::array<Pixel, 3> source{};
    std::array<Pixel, 3> candidate{};
    std::array<int, 3> index{};
    std::array<bool, 3> hit{};
};

struct State {
    std::array<Pixel, 32> history{};
    std::array<bool, 32> valid{};
    Pending pending{};
    int line = 0;
    std::array<int, 3> predicted_size{};
    int prev_qy = 0;
    int prev_qc = 0;
    bool prev_ich = false;
    bool selected = false;
    int group_count = 0;
};

State state;

Pixel unpack(std::uint64_t word)
{
    return Pixel{static_cast<int>((word >> 32) & 0xffffu),
                 static_cast<int>((word >> 16) & 0xffffu),
                 static_cast<int>(word & 0xffffu)};
}

std::uint64_t pack(const Pixel &pixel)
{
    return (static_cast<std::uint64_t>(pixel[0] & 0xffff) << 32) |
           (static_cast<std::uint64_t>(pixel[1] & 0xffff) << 16) |
           static_cast<std::uint64_t>(pixel[2] & 0xffff);
}

Pixel unpack_residual(std::uint64_t word)
{
    Pixel result{};
    for (int component = 0; component < 3; ++component) {
        const int shift = (2 - component) * 17;
        int value = static_cast<int>((word >> shift) & 0x1ffffu);
        if (value & 0x10000)
            value -= 0x20000;
        result[component] = value;
    }
    return result;
}

int ceil_log2(int value)
{
    // 与 C reference model (dsc_utils.c) 一致：返回 value 的二进制位宽。
    // 注意对精确 2 的幂（如 8）返回 4 而非 3，不能用数学上的 ceil(log2)。
    int result = 0;
    while (value > 0) {
        ++result;
        value >>= 1;
    }
    return result;
}

int clamp_size(int value, int maximum)
{
    return std::max(0, std::min(value, maximum));
}

int qlevel_8(int component, int qp)
{
    static constexpr int y[16] = {0,0,0,1,1,2,2,3,3,4,4,5,5,5,6,7};
    static constexpr int c[16] = {0,1,2,2,3,3,4,4,5,5,6,6,7,8,8,8};
    qp = std::clamp(qp, 0, 15);
    return component == 0 ? y[qp] : c[qp];
}

void move_to_front(const Pixel &pixel, bool selected)
{
    const int reserved = state.line == 0 ? 32 : 25;
    int location = reserved - 1;
    for (int index = 0; index < reserved; ++index) {
        if (!state.valid[index]) {
            location = index;
            break;
        }
        if (selected && state.history[index] == pixel) {
            location = index;
            break;
        }
    }
    for (int index = location; index > 0; --index) {
        state.history[index] = state.history[index - 1];
        state.valid[index] = state.valid[index - 1];
    }
    state.history[0] = pixel;
    state.valid[0] = true;
}
}

extern "C" void dsc_ich_model_reset()
{
    state = State{};
}

extern "C" void dsc_ich_model_group(
    int last, int bits, int version, int primary_qp, int qy, int qc,
    int force_mpp, int next_very_flat, int vlc_0, int vlc_1, int vlc_2,
    std::uint64_t group_0, std::uint64_t group_1, std::uint64_t group_2,
    std::uint64_t prev_0, std::uint64_t prev_1, std::uint64_t prev_2,
    std::uint64_t prev_3, std::uint64_t prev_4, std::uint64_t prev_5,
    std::uint64_t prev_6)
{
    Pending pending{};
    pending.valid = true;
    pending.last = last;
    pending.bits = bits;
    pending.version = version;
    pending.primary_qp = primary_qp;
    pending.qy = qy;
    pending.qc = qc;
    pending.force_mpp = force_mpp;
    pending.next_very_flat = next_very_flat;
    pending.vlc_size = {vlc_0, vlc_1, vlc_2};
    pending.source = {unpack(group_0), unpack(group_1), unpack(group_2)};
    const std::array<Pixel, 7> previous = {
        unpack(prev_0), unpack(prev_1), unpack(prev_2), unpack(prev_3),
        unpack(prev_4), unpack(prev_5), unpack(prev_6)};

    const int modified_qp = std::min(2 * bits - 1, primary_qp + 2);
    const int max_y = qlevel_8(0, modified_qp) == 0 ? 0 :
                      1 << (qlevel_8(0, modified_qp) - 1);
    const int max_c = qlevel_8(1, modified_qp) == 0 ? 0 :
                      1 << (qlevel_8(1, modified_qp) - 1);

    for (int sample = 0; sample < 3; ++sample) {
        int best = 0;
        int best_sad = 1 << 30;
        bool any_hit = false;
        for (int index = 0; index < 32; ++index) {
            const bool dynamic = state.line > 0 && index >= 25;
            const bool valid = dynamic || state.valid[index];
            if (!valid)
                continue;
            const Pixel &entry = dynamic ? previous[index - 25] : state.history[index];
            const int sad = 2 * std::abs(entry[0] - pending.source[sample][0]) +
                            std::abs(entry[1] - pending.source[sample][1]) +
                            std::abs(entry[2] - pending.source[sample][2]);
            if (sad < best_sad) {
                best_sad = sad;
                best = index;
                pending.candidate[sample] = entry;
            }
            any_hit |= std::abs(entry[0] - pending.source[sample][0]) <= max_y &&
                       std::abs(entry[1] - pending.source[sample][1]) <= max_c &&
                       std::abs(entry[2] - pending.source[sample][2]) <= max_c;
        }
        pending.index[sample] = best;
        pending.hit[sample] = any_hit;
    }
    state.pending = pending;
    ++state.group_count;
}

extern "C" void dsc_ich_model_decide(
    std::uint64_t predict_0, std::uint64_t predict_1, std::uint64_t predict_2,
    int residual_y_0, int residual_co_0, int residual_cg_0,
    int residual_y_1, int residual_co_1, int residual_cg_1,
    int residual_y_2, int residual_co_2, int residual_cg_2, int qy, int qc,
    int residual_size_0, int residual_size_1, int residual_size_2,
    int *select, int *index_0, int *index_1, int *index_2,
    std::uint64_t *pixel_0, std::uint64_t *pixel_1, std::uint64_t *pixel_2)
{
    const Pending &p = state.pending;
    const std::array<Pixel, 3> prediction = {
        unpack(predict_0), unpack(predict_1), unpack(predict_2)};
    const std::array<Pixel, 3> residual = {
        Pixel{residual_y_0, residual_co_0, residual_cg_0},
        Pixel{residual_y_1, residual_co_1, residual_cg_1},
        Pixel{residual_y_2, residual_co_2, residual_cg_2}};
    std::array<Pixel, 3> reconstructed = prediction;
    for (int sample = 0; sample < 3; ++sample) {
        for (int component = 0; component < 3; ++component) {
            const int shift = component == 0 ? qy : qc;
            const int maximum = 1 << (p.bits + (component != 0));
            reconstructed[sample][component] = std::clamp(
                prediction[sample][component] +
                (residual[sample][component] << shift), 0, maximum - 1);
        }
    }
    const std::array<int, 3> residual_size = {
        residual_size_0, residual_size_1, residual_size_2};
    const std::array<int, 3> depth = {p.bits, p.bits + 1, p.bits + 1};
    const std::array<int, 3> qlevel = {p.qy, p.qc, p.qc};
    const std::array<int, 3> previous_qlevel = {
        state.prev_qy, state.prev_qc, state.prev_qc};

    int log_predict = 0;
    int log_ich = 0;
    std::array<int, 3> max_predict_component{};
    std::array<int, 3> max_ich_component{};
    for (int component = 0; component < 3; ++component) {
        int max_predict = 0;
        int max_ich = 0;
        for (int sample = 0; sample < 3; ++sample) {
            max_predict = std::max(max_predict,
                std::abs(p.source[sample][component] -
                         reconstructed[sample][component]));
            max_ich = std::max(max_ich,
                std::abs(p.source[sample][component] - p.candidate[sample][component]));
        }
        log_predict += ceil_log2(max_predict >> std::max(p.bits - 8, 0));
        log_ich += ceil_log2(max_ich >> std::max(p.bits - 8, 0));
        max_predict_component[component] = max_predict;
        max_ich_component[component] = max_ich;
    }

    int bits_predict = 0;
    for (int component = 0; component < 3; ++component) {
        const int maximum = depth[component] - qlevel[component];
        const int adjusted = clamp_size(
            state.predicted_size[component] + previous_qlevel[component] -
            qlevel[component], maximum - 1);
        const int size = residual_size[component];
        if (size < adjusted)
            bits_predict += 1 + 3 * adjusted;
        else if (component == 0 && size < maximum && state.prev_ich)
            bits_predict += 2 + size - adjusted + 3 * size;
        else if (component != 0 && size == maximum)
            bits_predict += size - adjusted + 3 * size;
        else
            bits_predict += 1 + size - adjusted + 3 * size;
    }
    const int adjusted_y = clamp_size(
        state.predicted_size[0] + state.prev_qy - p.qy, p.bits - p.qy - 1);
    const int escape = p.bits + 1 - p.qy;
    const int bits_ich = 15 + (state.prev_ich ? 1 : escape - adjusted_y);
    bool choose = p.valid && p.hit[0] && p.hit[1] && p.hit[2] &&
                  bits_ich + 4 * log_ich < bits_predict + 4 * log_predict;
    if ((p.version == 1 || p.next_very_flat) && log_ich > log_predict)
        choose = false;
    if (p.force_mpp)
        choose = false;

    if ((state.group_count - 1 >= 392 && state.group_count - 1 <= 398) ||
        state.group_count - 1 == 504 ||
        (state.group_count - 1 >= 588 && state.group_count - 1 <= 594)) {
        std::fprintf(stderr,
            "ICH_MODEL group=%d hit=%d%d%d idx=%d/%d/%d bits=%d/%d log=%d/%d cost=%d/%d flat=%d force=%d choose=%d\n",
            state.group_count - 1,
            p.hit[0], p.hit[1], p.hit[2], p.index[0], p.index[1], p.index[2],
            bits_predict, bits_ich, log_predict, log_ich,
            bits_predict + 4 * log_predict, bits_ich + 4 * log_ich,
            p.next_very_flat, p.force_mpp, choose);
        std::fprintf(stderr,
            "ICH_MODEL_ERROR predict=%d/%d/%d ich=%d/%d/%d\n",
            max_predict_component[0], max_predict_component[1],
            max_predict_component[2], max_ich_component[0],
            max_ich_component[1], max_ich_component[2]);
        for (int sample = 0; sample < 3; ++sample) {
            std::fprintf(stderr,
                "ICH_MODEL_PIXEL sample=%d src=%d/%d/%d pred=%d/%d/%d recon=%d/%d/%d residual=%d/%d/%d\n",
                sample, p.source[sample][0], p.source[sample][1],
                p.source[sample][2], prediction[sample][0],
                prediction[sample][1], prediction[sample][2],
                reconstructed[sample][0], reconstructed[sample][1],
                reconstructed[sample][2], residual[sample][0],
                residual[sample][1], residual[sample][2]);
        }
    }

    state.selected = choose;
    *select = choose;
    *index_0 = p.index[0];
    *index_1 = p.index[1];
    *index_2 = p.index[2];
    *pixel_0 = pack(p.candidate[0]);
    *pixel_1 = pack(p.candidate[1]);
    *pixel_2 = pack(p.candidate[2]);
}

extern "C" void dsc_ich_model_update(
    int valid, int last,
    std::uint64_t predict_0, std::uint64_t predict_1, std::uint64_t predict_2,
    int residual_y_0, int residual_co_0, int residual_cg_0,
    int residual_y_1, int residual_co_1, int residual_cg_1,
    int residual_y_2, int residual_co_2, int residual_cg_2,
    int qy, int qc, int vlc_0, int vlc_1, int vlc_2)
{
    if (!valid)
        return;
    const std::array<Pixel, 3> prediction = {
        unpack(predict_0), unpack(predict_1), unpack(predict_2)};
    const std::array<Pixel, 3> residual = {
        Pixel{residual_y_0, residual_co_0, residual_cg_0},
        Pixel{residual_y_1, residual_co_1, residual_cg_1},
        Pixel{residual_y_2, residual_co_2, residual_cg_2}};
    std::array<Pixel, 3> reconstructed{};
    for (int sample = 0; sample < 3; ++sample) {
        reconstructed[sample] = state.selected ? state.pending.candidate[sample] : prediction[sample];
        if (!state.selected) {
            for (int component = 0; component < 3; ++component) {
                const int qlevel = component == 0 ? qy : qc;
                const int maximum = 1 << (state.pending.bits + (component != 0));
                reconstructed[sample][component] = std::clamp(
                    prediction[sample][component] +
                    (residual[sample][component] << qlevel), 0, maximum - 1);
            }
        }
    }
    if (!last) {
        for (int sample = 0; sample < 3; ++sample)
            move_to_front(reconstructed[sample], state.selected);
    }
    if (!state.selected)
        state.predicted_size = {vlc_0, vlc_1, vlc_2};
    state.prev_qy = qy;
    state.prev_qc = qc;
    state.prev_ich = state.selected;
    if (last)
        ++state.line;
}
