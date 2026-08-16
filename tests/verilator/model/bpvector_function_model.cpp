#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>

namespace {
constexpr int kMaxWidth = 4096;
using Pixel = std::array<int, 3>;

struct State {
    std::array<Pixel, kMaxWidth> previous{};
    std::array<Pixel, kMaxWidth> current_recon{};
    std::array<std::array<int, 13>, 3> sad_history{};
    int group = 0;
    int line = 0;
    int bp_count = 0;
    int last_edge_count = 10;
};

State state;

Pixel unpack_pixel(std::uint64_t word)
{
    return Pixel{static_cast<int>((word >> 32) & 0xffffu),
                 static_cast<int>((word >> 16) & 0xffffu),
                 static_cast<int>(word & 0xffffu)};
}

std::uint64_t pack_pixel(const Pixel &pixel)
{
    return (static_cast<std::uint64_t>(pixel[0] & 0xffff) << 32) |
           (static_cast<std::uint64_t>(pixel[1] & 0xffff) << 16) |
           static_cast<std::uint64_t>(pixel[2] & 0xffff);
}

std::uint64_t pack_residual(const Pixel &residual)
{
    return (static_cast<std::uint64_t>(residual[0] & 0x1ffff) << 34) |
           (static_cast<std::uint64_t>(residual[1] & 0x1ffff) << 17) |
           static_cast<std::uint64_t>(residual[2] & 0x1ffff);
}

int modified_abs_diff(int lhs, int rhs, int shift)
{
    return std::min(std::abs(lhs - rhs) >> shift, 0x3f);
}
}

extern "C" void dsc_bpvector_model_step(
    int reset_model,
    int push_group,
    int group_last,
    int block_pred_enable,
    int bits_per_component,
    std::uint64_t group_0,
    std::uint64_t group_1,
    std::uint64_t group_2,
    std::uint64_t prev_0,
    std::uint64_t prev_1,
    std::uint64_t prev_2,
    std::uint64_t prev_3,
    std::uint64_t prev_4,
    std::uint64_t prev_5,
    std::uint64_t recon_0,
    std::uint64_t recon_1,
    std::uint64_t recon_2,
    int *use_bp,
    int *bp_vector,
    std::uint64_t *predict_0,
    std::uint64_t *predict_1,
    std::uint64_t *predict_2,
    std::uint64_t *residual_0,
    std::uint64_t *residual_1,
    std::uint64_t *residual_2)
{
    if (reset_model)
        state = State{};
    *use_bp = 0;
    *bp_vector = 0;
    if (!push_group)
        return;

    const std::array<Pixel, 3> source = {
        unpack_pixel(group_0), unpack_pixel(group_1), unpack_pixel(group_2)};
    const std::array<Pixel, 6> window = {
        unpack_pixel(prev_0), unpack_pixel(prev_1), unpack_pixel(prev_2),
        unpack_pixel(prev_3), unpack_pixel(prev_4), unpack_pixel(prev_5)};
    const int x = state.group * 3;
    if (state.group != 0) {
        const std::array<Pixel, 3> recon = {
            unpack_pixel(recon_0), unpack_pixel(recon_1), unpack_pixel(recon_2)};
        for (int sample = 0; sample < 3; ++sample)
            state.current_recon[x - 3 + sample] = recon[sample];
    }
    for (int sample = 0; sample < 3; ++sample)
        state.previous[x + sample] = window[2 + sample];

    bool edge = false;
    Pixel left = window[1];
    const int edge_threshold = 32 << std::max(bits_per_component - 8, 0);
    for (int sample = 0; sample < 3; ++sample) {
        const Pixel &current = state.previous[x + sample];
        for (int component = 0; component < 3; ++component)
            edge |= std::abs(current[component] - left[component]) > edge_threshold;
        left = current;
    }
    state.last_edge_count = edge ? 0 : state.last_edge_count + 3;

    std::array<int, 13> sad{};
    for (int candidate = 0; candidate < 13; ++candidate) {
        int total = 0;
        for (int position = std::max(0, x - 6); position <= x + 2; ++position) {
            const Pixel midpoint = {1 << (bits_per_component - 1),
                                    1 << bits_per_component,
                                    1 << bits_per_component};
            const Pixel &prediction = position > candidate ?
                state.previous[position - 1 - candidate] : midpoint;
            for (int component = 0; component < 3; ++component) {
                const int depth = bits_per_component + (component == 0 ? 0 : 1);
                total += modified_abs_diff(state.previous[position][component],
                                           prediction[component], depth - 7);
            }
        }
        sad[candidate] = total >> 3;
    }

    int selected = 0;
    int minimum = sad[0];
    for (int candidate = 2; candidate <= 9; ++candidate) {
        if (minimum > sad[candidate]) {
            minimum = sad[candidate];
            selected = candidate;
        }
    }
    if (block_pred_enable && x + 2 >= 9)
        state.bp_count = selected > 0 ? state.bp_count + 1 : 0;
    // 首行没有可用的前一行，参考模型固定使用 LEFT/MAP 路径。
    const bool select_bp = state.line > 0 && state.bp_count >= 3 &&
                           state.last_edge_count < 3;
    *use_bp = select_bp ? 1 : 0;
    *bp_vector = selected;

    std::array<std::uint64_t *, 3> predict_words = {predict_0, predict_1, predict_2};
    std::array<std::uint64_t *, 3> residual_words = {residual_0, residual_1, residual_2};
    for (int sample = 0; sample < 3; ++sample) {
        Pixel prediction{};
        Pixel residual{};
        for (int component = 0; component < 3; ++component) {
            prediction[component] = select_bp ?
                state.current_recon[x + sample - 1 - selected][component] : 0;
            residual[component] = source[sample][component] - prediction[component];
        }
        *predict_words[sample] = pack_pixel(prediction);
        *residual_words[sample] = pack_residual(residual);
    }

    if (group_last) {
        state.group = 0;
        ++state.line;
        state.bp_count = 0;
        state.last_edge_count = 10;
    } else {
        ++state.group;
    }
}
