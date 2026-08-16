#include <cstdint>

// 从 C reference model VLCUnit 的 chroma ICH 分支移植：unit>0 时不发送
// prefix/residual，只在该 unit 对应的 phase 发送一个 5-bit history index。
// 返回布局为 valid[21], size[20:16], data[15:0]。
extern "C" int dsc_vlc_ich_chroma_fragment_model(
    int phase,
    int ich_selected,
    int ich_index)
{
    if (!ich_selected)
        return 0;

    // RTL pipeline phase 2 (4'b0010) 对应已寄存的 ICH index 发射阶段。
    if (phase == 0x2) {
        const std::uint32_t valid = 1u << 21;
        const std::uint32_t size = 5u << 16;
        return static_cast<int>(valid | size | (static_cast<unsigned>(ich_index) & 0x1fu));
    }
    return 0;
}
