#include <algorithm>
#include <array>
#include <cstdint>
#include <deque>

namespace {
struct Fragment {
    unsigned size;
    unsigned data;
    bool last;
};

struct UnitState {
    unsigned previous_qlevel = 0;
    unsigned predicted_size = 0;
    bool previous_ich = false;
    unsigned group_index = 0;
    std::deque<Fragment> fragments;
};

std::array<UnitState, 3> units;

unsigned clamp_size(int value, unsigned maximum)
{
    return static_cast<unsigned>(std::clamp(value, 0, static_cast<int>(maximum)));
}

void add_bits(UnitState &state, unsigned size, unsigned data, bool last = false)
{
    // C reference model 的 AddBits(size=0) 不产生输出事务。
    if (size != 0)
        state.fragments.push_back(Fragment{size & 0x1fu, data & 0xffffu, last});
}
}

// 返回布局：fragment valid[62], last[61], size[60:56], data[55:40],
// unit-size valid[39], coded size[38:33], RC size[32:27]。
extern "C" std::uint64_t dsc_vlc_unit_model_step(
    int unit,
    int reset_model,
    int push_group,
    int group_last,
    int bits_per_component,
    int convert_rgb,
    int primary_qp,
    int qlevel_y,
    int qlevel_c,
    int residual_size,
    int vlc_size,
    int residual_0,
    int residual_1,
    int residual_2,
    int ich_selected,
    int ich_index,
    int flatness_flags)
{
    UnitState &state = units[static_cast<unsigned>(unit) % units.size()];
    if (reset_model)
        state = UnitState{};

    std::uint64_t result = 0;
    if (push_group) {
        const unsigned qlevel = unit == 0 ? qlevel_y : qlevel_c;
        const unsigned component_depth = static_cast<unsigned>(bits_per_component) +
            ((unit != 0 && convert_rgb) ? 1u : 0u);
        const unsigned max_residual = component_depth - qlevel;
        const unsigned adjusted = clamp_size(
            static_cast<int>(state.predicted_size) +
                static_cast<int>(state.previous_qlevel) - static_cast<int>(qlevel),
            max_residual == 0 ? 0 : max_residual - 1);
        const int difference = residual_size - static_cast<int>(adjusted);
        const unsigned coded_residual = difference < 0 ? adjusted :
            static_cast<unsigned>(residual_size);

        unsigned one_bits = 0;
        unsigned prefix_size = 0;
        if (!state.previous_ich && !ich_selected) {
            one_bits = (static_cast<unsigned>(residual_size) < max_residual || unit == 0) ? 1u : 0u;
            prefix_size = (difference <= 0) ? 1u : static_cast<unsigned>(difference) + one_bits;
        } else if (!state.previous_ich && ich_selected) {
            if (unit == 0) {
                const int maximum_difference = static_cast<int>(max_residual) -
                    static_cast<int>(adjusted) + 1;
                prefix_size = maximum_difference < 0 ? 1u :
                    static_cast<unsigned>(maximum_difference);
            }
        } else if (state.previous_ich && !ich_selected) {
            one_bits = static_cast<unsigned>(residual_size) < max_residual ? 1u : 0u;
            if (unit == 0)
                prefix_size = difference < 0 ? 1u + one_bits :
                    static_cast<unsigned>(difference) + one_bits + 1u;
            else
                prefix_size = difference < 0 ? one_bits :
                    static_cast<unsigned>(difference) + one_bits;
        } else {
            one_bits = unit == 0 ? 1u : 0u;
            prefix_size = one_bits;
        }
        const unsigned prefix_data = one_bits == 0 ? 0u : 1u;

        const bool next_flatness_flag = (flatness_flags & 0x80) != 0;
        const bool send_flatness = (flatness_flags & 0x40) != 0;
        const unsigned first_flat = (static_cast<unsigned>(flatness_flags) >> 4) & 3u;
        const unsigned flatness_type = (static_cast<unsigned>(flatness_flags) >> 3) & 1u;
        const bool flatness_qp = unit == 0 && primary_qp >= 3 && primary_qp <= 12;

        if (unit == 0 && state.group_index == 3 && flatness_qp)
            add_bits(state, 1, next_flatness_flag ? 1u : 0u);
        if (unit == 0 && state.group_index == 0 && send_flatness) {
            if (primary_qp >= 7)
                add_bits(state, 1, flatness_type);
            add_bits(state, 2, first_flat);
        }

        if (unit != 0 && ich_selected) {
            add_bits(state, 5, static_cast<unsigned>(ich_index), group_last != 0);
        } else {
            add_bits(state, prefix_size, prefix_data);
            if (ich_selected) {
                add_bits(state, 5, static_cast<unsigned>(ich_index), group_last != 0);
            } else {
                const int residuals[3] = {residual_0, residual_1, residual_2};
                for (unsigned index = 0; index < 3; ++index) {
                    add_bits(state, coded_residual,
                        static_cast<unsigned>(residuals[index]),
                        group_last != 0 && index == 2);
                }
            }
        }

        unsigned coded_size = 0;
        unsigned rc_size = 0;
        if (!ich_selected) {
            const unsigned flat_size = unit == 0 && state.group_index == 3 && flatness_qp ? 1u : 0u;
            coded_size = flat_size + prefix_size + 3u * coded_residual;
            rc_size = 1u + 3u * static_cast<unsigned>(residual_size);
        } else if (unit == 0) {
            const unsigned flat_size = state.group_index == 3 && flatness_qp ? 1u : 0u;
            const unsigned ich_prefix = state.previous_ich ? 1u :
                component_depth + 1u - (static_cast<unsigned>(qlevel_y) + adjusted);
            coded_size = flat_size + ich_prefix + 5u;
            rc_size = 6u;
        } else {
            coded_size = 5u;
            rc_size = 5u;
        }
        result |= 1ull << 39;
        result |= static_cast<std::uint64_t>(coded_size & 0x3fu) << 33;
        result |= static_cast<std::uint64_t>(rc_size & 0x3fu) << 27;

        state.previous_qlevel = qlevel;
        state.previous_ich = ich_selected != 0;
        if (!ich_selected)
            state.predicted_size = static_cast<unsigned>(vlc_size) & 0x1fu;
        state.group_index = (state.group_index + 1u) & 3u;
    }

    if (!state.fragments.empty()) {
        const Fragment fragment = state.fragments.front();
        state.fragments.pop_front();
        result |= 1ull << 62;
        if (fragment.last)
            result |= 1ull << 61;
        result |= static_cast<std::uint64_t>(fragment.size) << 56;
        result |= static_cast<std::uint64_t>(fragment.data) << 40;
    }
    return result;
}
