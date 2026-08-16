#include <cstdint>

extern "C" void dsc_mpp_model_step(
    int component,
    int bits_per_component,
    int convert_rgb,
    int qlevel,
    int right,
    int sample_0,
    int sample_1,
    int sample_2,
    int *predict,
    int *residual_0,
    int *residual_1,
    int *residual_2)
{
    // 参考模型的 Co/Cg 在 RGB 转换模式下比 Y 多一位。
    const int depth = bits_per_component +
                      ((convert_rgb && component != 0) ? 1 : 0);
    const int midpoint = 1 << (depth - 1);
    const int mask = qlevel == 0 ? 0 : ((1 << qlevel) - 1);
    const int value = midpoint + (right & mask);

    *predict = value;
    *residual_0 = sample_0 - value;
    *residual_1 = sample_1 - value;
    *residual_2 = sample_2 - value;
}
