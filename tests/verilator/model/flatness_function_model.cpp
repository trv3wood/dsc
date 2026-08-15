#include <algorithm>

// 从 C reference model 的 FlatnessAdjustment 移植的行尾 QP 调整。
// 该函数只依赖边界输入，不读取 golden 输出或仿真绝对周期。
extern "C" int dsc_flatness_adjust_qp_model(
    int last_used_qp,
    int somewhat_flat_threshold,
    int very_flat_qp)
{
    if (last_used_qp < somewhat_flat_threshold)
        return std::max(last_used_qp - 4, 0);
    return very_flat_qp;
}
