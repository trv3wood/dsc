// 多 slice / 多分辨率端到端对拍 testbench。
//
// 运行：verilator 构建后 `./obj_dir/Vtb_dsc_e2e_multi +case=<name>`
// 读取 tests/verilator/generated/<name>/ 下由 generate_golden.py 产出的向量
// （无 <name> 时读取 generated/），动态分配输入与期望 payload 数组。
//
// 以 axi_tdata_out（bypass 后 48-bit 原生）与 dsce_slice_mux 原生码流两路
// 逐字节比对 C model payload；多 slice 的交织顺序即 slice_mux 的轮询顺序，
// 若与 C 模型 chunk 交织不一致会在首个失配暴露。
`timescale 1ns/1ps

module tb_dsc_e2e_multi;
    localparam int kSPC = 4;                 // 顶层 pSLICE_PROCESSOR_COUNT
    localparam int kPIXELS_PER_CYCLE = 4;

    logic         apb_clk = 1'b0;
    logic         dsc_clk = 1'b0;
    logic         axi_clk = 1'b0;
    logic         async_reset_n = 1'b0;
    logic         async_test_mode = 1'b0;
    logic         apb_select = 1'b0;
    logic         apb_enable = 1'b0;
    logic         apb_write = 1'b0;
    logic [3:0]   apb_strobe = 4'h0;
    logic [2:0]   apb_protect = 3'h0;
    logic [11:0]  apb_addr = 12'h000;
    logic [31:0]  apb_wdata = 32'h0;
    logic         apb_ready;
    logic         apb_slave_error;
    logic         apb_int;
    logic [31:0]  apb_rdata;
    logic         axi_tvalid_in = 1'b0;
    logic         axi_tready_in;
    logic         axi_tline_in = 1'b0;
    logic         axi_tframe_in = 1'b0;
    logic [191:0] axi_tdata_in = 192'h0;
    logic         axi_tvalid_out;
    logic         axi_tready_out = 1'b1;
    logic         axi_tline_out;
    logic         axi_tframe_out;
    logic [191:0] axi_tdata_out;
    logic [11:0]  bist_sram_in [kSPC*4+1:0];
    logic [11:0]  bist_sram_out [kSPC*4+1:0];

    // 来自 metadata 的参数
    int           width;
    int           height;
    int           slice_width;
    int           slice_height;
    int           slices_per_line;
    int           payload_bytes;
    int           beats;
    int unsigned  flow_seed = 32'h9e37_79b9;
    int           input_gap_pct = 0;
    int           output_stall_pct = 0;
    logic [31:0]  input_prng;
    logic [31:0]  output_prng;

    // 向量数组按上限静态分配（覆盖至 4K/DCI 4K；5K/8K 不做 RTL 仿真）。
    localparam int kMAX_BEATS   = 2_000_000;
    localparam int kMAX_PAYLOAD = 32_000_000;
    logic [191:0] input_beats [0:kMAX_BEATS-1];
    logic [7:0]   expected_payload [0:kMAX_PAYLOAD-1];
    logic [7:0]   pps [0:127];

    // 计数器/比较
    int  out_count = 0, top_mis = 0, top_excess = 0;
    int  mux_count = 0, mux_mis = 0;
    int  accepted_input = 0;
    int  done_topo = 0, done_mux = 0;

    always begin apb_clk <= ~apb_clk; #10; end
    always begin dsc_clk <= ~dsc_clk; #5;  end   // dsc 域 2x
    always begin axi_clk <= ~axi_clk; #10; end

    function automatic logic [31:0] prng_next(input logic [31:0] state);
        logic feedback;
        begin
            feedback = state[31] ^ state[21] ^ state[1] ^ state[0];
            prng_next = {state[30:0], feedback};
            if (prng_next == 0)
                prng_next = 32'h1;
        end
    endfunction

    // 输出背压使用独立 PRNG；同一 flow_seed 可稳定复现。
    always @(negedge axi_clk) begin
        if (!async_reset_n) begin
            output_prng <= flow_seed ^ 32'ha5a5_5a5a;
            axi_tready_out <= 1'b1;
        end else begin
            output_prng <= prng_next(output_prng);
            axi_tready_out <= (output_prng % 100) >= output_stall_pct;
        end
    end

    dsc_encoder dut (
        .apb_clk(apb_clk), .apb_select(apb_select), .apb_enable(apb_enable),
        .apb_write(apb_write), .apb_strobe(apb_strobe), .apb_protect(apb_protect),
        .apb_addr(apb_addr), .apb_wdata(apb_wdata), .apb_ready(apb_ready),
        .apb_slave_error(apb_slave_error), .apb_int(apb_int), .apb_rdata(apb_rdata),
        .dsc_clk(dsc_clk), .async_reset_n(async_reset_n), .async_test_mode(async_test_mode),
        .axi_clk(axi_clk), .axi_tvalid_in(axi_tvalid_in), .axi_tready_in(axi_tready_in),
        .axi_tline_in(axi_tline_in), .axi_tframe_in(axi_tframe_in), .axi_tdata_in(axi_tdata_in),
        .axi_tvalid_out(axi_tvalid_out), .axi_tready_out(axi_tready_out),
        .axi_tline_out(axi_tline_out), .axi_tframe_out(axi_tframe_out),
        .axi_tdata_out(axi_tdata_out),
        .bist_sram_in(bist_sram_in), .bist_sram_out(bist_sram_out)
    );

    task automatic apb_write32(input logic [11:0] address, input logic [31:0] data);
        @(negedge apb_clk);
        apb_select = 1'b1; apb_enable = 1'b0; apb_write = 1'b1;
        apb_strobe = 4'hf; apb_addr = address; apb_wdata = data;
        @(negedge apb_clk);
        apb_enable = 1'b1;
        do @(posedge apb_clk); while (!apb_ready);
        @(negedge apb_clk);
        apb_select = 1'b0; apb_enable = 1'b0; apb_write = 1'b0; apb_strobe = 4'h0;
    endtask

    task automatic pulse_frame;
        @(negedge axi_clk);
        axi_tframe_in = 1'b1;
        repeat (2) @(negedge axi_clk);
        axi_tframe_in = 1'b0;
    endtask

    always @(posedge axi_clk) begin : SliceDiag
        if (!async_reset_n) begin
            part_valid <= '{default: 0};
            mux_ready  <= '{default: 0};
            last_in    <= '{default: 0};
            select_chg <= 0;
            select_last <= 0;
        end else begin
            for (int g = 0; g < kSPC; g++) begin
                if (dut.dsce_engine_inst.dsce_partition_inst.axi_valid_out[g])
                    part_valid[g]++;
                if (dut.dsce_engine_inst.dsce_slice_mux_inst.axi_tready_in[g])
                    mux_ready[g]++;
                if (dut.dsce_engine_inst.i_axi_last[g])
                    last_in[g]++;
            end
            if (dut.dsce_engine_inst.dsce_slice_mux_inst.i_slice_select != select_last) begin
                select_chg <= select_chg + 1;
                select_last <= dut.dsce_engine_inst.dsce_slice_mux_inst.i_slice_select;
            end
        end
    end
    int part_valid [kSPC];
    int mux_ready  [kSPC];
    int last_in    [kSPC];
    int select_chg = 0;
    int select_last = 0;
    int new_frame_count = 0;

    always @(posedge axi_clk) begin : NewFrameWatch
        if (async_reset_n && dut.axi_new_frame) new_frame_count++;
    end

    int mux_last_ok = 0;
    always @(posedge axi_clk) begin : MuxLastOk
        if (async_reset_n &&
            dut.dsce_engine_inst.dsce_slice_mux_inst.i_valid_in &&
            dut.dsce_engine_inst.dsce_slice_mux_inst.i_ready_in &&
            dut.dsce_engine_inst.dsce_slice_mux_inst.i_last_in)
            mux_last_ok++;
    end

`ifdef DSC_E2E_DEBUG
    // 深层层级探针仅供临时定位，不参与标准回归判定。
    // 逐 processor 捕获 muxword 流到文件，供离线与 C model 对比定位编码/交织问题。
    integer       proc_mw_file [kSPC];
    int           proc_mw_count [kSPC];
    initial begin
        for (int gfi = 0; gfi < kSPC; gfi++) begin
            proc_mw_file[gfi] = $fopen($sformatf("tests/verilator/generated/proc%0d_muxwords.hex", gfi), "w");
            if (proc_mw_file[gfi] == 0) $fatal(1, "无法创建 proc muxword 文件 g=%0d", gfi);
        end
    end
    always @(posedge axi_clk) begin : ProcMuxCapture
        for (int gp = 0; gp < kSPC; gp++) begin
            if (async_reset_n && dut.dsce_engine_inst.i_axi_ready[gp] &&
                dut.dsce_engine_inst.i_axi_accept[gp] &&
                proc_mw_count[gp] < 16384) begin
                $fwrite(proc_mw_file[gp], "%012x\n", dut.dsce_engine_inst.i_axi_muxword[gp][47:0]);
                proc_mw_count[gp]++;
            end
        end
    end
`endif

    // AXI 输出（bypass 后，每拍 6 bytes 位于低位 48 bit）逐字节比对。
    always @(posedge axi_clk) begin : TopScoreboard
        if (async_reset_n && axi_tvalid_out && axi_tready_out) begin
            for (int byte_index = 0; byte_index < 6; byte_index++) begin
                if (out_count < payload_bytes) begin
                    if (axi_tdata_out[byte_index*8 +: 8] !== expected_payload[out_count]) begin
                        if (top_mis < 8)
                            $display("TOP_MISMATCH byte=%0d expected=%02x actual=%02x",
                                     out_count, expected_payload[out_count],
                                     axi_tdata_out[byte_index*8 +: 8]);
                        top_mis++;
                    end
                end else begin
                    top_excess++;
                end
                out_count++;
            end
            if (out_count >= payload_bytes) done_topo = 1;
        end
    end

    // slice_mux 原生 48-bit 流逐字节比对。
    always @(posedge axi_clk) begin : MuxScoreboard
        if (async_reset_n && dut.dsce_engine_inst.i_axi_tvalid_mux &&
            dut.dsce_engine_inst.i_axi_tready_mux) begin
            for (int byte_index = 0; byte_index < 6; byte_index++) begin
                if (mux_count < payload_bytes) begin
                    if (dut.dsce_engine_inst.i_axi_tdata_mux[byte_index*8 +: 8] !==
                        expected_payload[mux_count]) begin
                        if (mux_mis < 8)
                            $display("MUX_MISMATCH byte=%0d expected=%02x actual=%02x",
                                     mux_count, expected_payload[mux_count],
                                     dut.dsce_engine_inst.i_axi_tdata_mux[byte_index*8 +: 8]);
                        mux_mis++;
                    end
                end
                mux_count++;
            end
            if (mux_count >= payload_bytes) done_mux = 1;
        end
    end

    always @(posedge axi_clk)
        if (async_reset_n && axi_tvalid_in && axi_tready_in) accepted_input++;

`ifdef DSC_E2E_DEBUG
    // 捕获 slice0 的 VLC 片段流({size,data})，与 c_vlc_trace.txt 逐片段对比定位首分歧 group。
    integer vlc_file;
    int     vlc_frag_cnt [3];
    initial vlc_file = $fopen("tests/verilator/generated/rtl_vlc_s0.log", "w");
    always @(posedge dsc_clk) begin : VlcCapture
        if (async_reset_n) begin
            for (int vx = 0; vx < 3; vx++) begin
                if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_valid_vlc[vx]) begin
                    $fwrite(vlc_file, "ssp=%0d frag=%0d size=%0d data=%04x\n",
                            vx, vlc_frag_cnt[vx],
                            dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_size_vlc[vx],
                            dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_data_vlc[vx]);
                    vlc_frag_cnt[vx]++;
                end
            end
        end
    end

    // 捕获 slice0 逐 group 的 VLC 输入边界(residual/qp/ich),对照 c_group_trace.txt。
    integer gb_file;
    int     gb_cnt;
    initial gb_file = $fopen("tests/verilator/generated/rtl_group_s0.log", "w");
    always @(posedge dsc_clk) begin : GroupBoundaryCapture
        if (async_reset_n && dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_pd) begin
            $fwrite(gb_file, "g=%0d qp=%0d ich=%0b r=%016x/%016x/%016x p=%06x last=%0b\n",
                    gb_cnt,
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_primary_qp_res,
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_ich_selected_dec,
                    {dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[0].res_y,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[0].res_co,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[0].res_cg},
                    {dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[1].res_y,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[1].res_co,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[1].res_cg},
                    {dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[2].res_y,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[2].res_co,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[2].res_cg},
                    {dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_size_dec[0],
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_size_dec[1],
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_size_dec[2]},
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_last_pd);
            gb_cnt++;
        end
    end

    // 停摆 watchdog：mux 向选中 slice 持续 ready 但 tvalid 长期为低时，
    // 转储各 slice 的 format/slice_buffer 内部状态，定位编码停摆点。
    int stall_wait_cycles = 0;
    int stall_dumped = 0;
    // 周期性打印各 slice 的 format/slice_buffer 进展，观察编码推进与停摆位置。
    int prog_tick = 0;
    always @(posedge axi_clk) begin : ProgProbe
        if (!async_reset_n) prog_tick <= 0;
        else prog_tick <= prog_tick + 1;
        if (prog_tick[9:0] == 10'd0 && async_reset_n) begin
            $display("DET t=%0d g0=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d | g1=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d",
                     $time,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_out_count,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_dsc_write_count,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_raddr,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_waddr,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_read_state,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.dsc_start_of_slice,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_write_ready,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_pipeline_state,
                     dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_out_count,
                     dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_dsc_write_count,
                     dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_raddr,
                     dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_waddr,
                     dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_read_state,
                     dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_slice_buffer_inst.dsc_start_of_slice,
                     dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_write_ready,
                     dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_slice_buffer_inst.i_pipeline_state);
        end
    end

    // dump proc0 format AXI 侧每拍信号，分析 chunk 边界处丢失 word 的机制。
    integer fbd_file;
    initial fbd_file = $fopen("tests/verilator/generated/fmt_boundary.log", "w");
    always @(posedge axi_clk) begin : FmtBoundaryDump
        if (async_reset_n && dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.axi_tvalid_out &&
            dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.axi_tready_out)
            $fwrite(fbd_file, "out=%0d st=%0d raddr=%0d ren=%0b data=%012x\n",
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_out_count,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_read_state,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_raddr,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_ren,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.axi_muxword_out[47:0]);
    end

    // 捕获 slice_mux 原生输出流 + 当时选中的 slice/状态，离线对照 golden payload。
    integer smx_file;
    initial smx_file = $fopen("tests/verilator/generated/mux_stream.log", "w");
    always @(posedge axi_clk) begin : MuxStreamDump
        if (async_reset_n && dut.dsce_engine_inst.i_axi_tvalid_mux &&
            dut.dsce_engine_inst.i_axi_tready_mux)
            $fwrite(smx_file, "sel=%0d st=%0d last_ok=%0b data=%012x\n",
                dut.dsce_engine_inst.dsce_slice_mux_inst.i_slice_select,
                dut.dsce_engine_inst.dsce_slice_mux_inst.i_slice_state,
                dut.dsce_engine_inst.dsce_slice_mux_inst.i_last_in,
                dut.dsce_engine_inst.i_axi_tdata_mux[47:0]);
    end

    // 前 3000 拍逐周期转储 mux 与 format0 的 chunk 配置/边界，定位首 chunk 切 slice 时机。
    integer fc_file;
    int     fc_cycle;
    initial fc_file = $fopen("tests/verilator/generated/first_chunk.log", "w");
    always @(posedge axi_clk) begin : FirstChunkDump
        if (!async_reset_n) fc_cycle <= 0;
        else begin
            if (fc_cycle < 3000 && fc_cycle > 300)
                $fwrite(fc_file, "cyc=%0d msel=%0d mst=%0d mlast=%0b mvalid=%0b | f0_tv=%0b f0_last=%0b f0_cw=%0d f0_tw=%0d f0_sh=%0d f0_out=%0d f0_st=%0d f0_bound=%0b\n",
                    fc_cycle,
                    dut.dsce_engine_inst.dsce_slice_mux_inst.i_slice_select,
                    dut.dsce_engine_inst.dsce_slice_mux_inst.i_slice_state,
                    dut.dsce_engine_inst.dsce_slice_mux_inst.i_last_in,
                    dut.dsce_engine_inst.dsce_slice_mux_inst.i_valid_in,
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.axi_tvalid_out,
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.axi_last_out,
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_chunk_words,
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_target_words,
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_slice_height,
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_out_count,
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_read_state,
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_chunk_boundary);
            fc_cycle <= fc_cycle + 1;
        end
    end

    always @(posedge axi_clk) begin : StallWatchdog
        if (!async_reset_n) begin
            stall_wait_cycles <= 0;
            stall_dumped <= 0;
        end else if (dut.axi_encoder_enable &&
                     dut.dsce_engine_inst.dsce_slice_mux_inst.i_valid_in == 1'b0 &&
                     dut.dsce_engine_inst.dsce_slice_mux_inst.i_ready_in == 1'b1) begin
            stall_wait_cycles <= stall_wait_cycles + 1;
            if (stall_wait_cycles == 500 && !stall_dumped) begin
                stall_dumped <= 1;
                $display("STALL mux_select=%0d mux_state=%0d ready_in=%0b valid_in=%0b tready_out=%0b",
                         dut.dsce_engine_inst.dsce_slice_mux_inst.i_slice_select,
                         dut.dsce_engine_inst.dsce_slice_mux_inst.i_slice_state,
                         dut.dsce_engine_inst.dsce_slice_mux_inst.i_ready_in,
                         dut.dsce_engine_inst.dsce_slice_mux_inst.i_valid_in,
                         dut.dsce_engine_inst.dsce_slice_mux_inst.axi_tready_out);
                // gen_slice[g] 层级索引须为常量，手动展开 kSPC=4。
                for (int gd = 0; gd < 4; gd++) begin
                    case (gd)
                        0: $display("STALL_SLICE g=0 fmt_state=%0d fmt_out=%0d fmt_waddr=%0d fmt_raddr=%0d fmt_pause=%0b fmt_tvalid=%0b fmt_idle=%0b | slb_wrdy=%0b slb_pipe=%0d slb_rstate=%0d slb_raddr=%0d slb_waddr=%0d slb_valid=%0b slb_last=%0b slb_sos=%0b",
                                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_read_state,
                                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_out_count,
                                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_dsc_waddr,
                                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_raddr,
                                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_pause_chunk,
                                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.axi_tvalid_out,
                                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_write_idle,
                                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_write_ready,
                                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_pipeline_state,
                                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_read_state,
                                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_raddr,
                                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_axi_waddr,
                                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.dsc_valid_out,
                                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.dsc_last_out,
                                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.dsc_start_of_slice);
                        1: $display("STALL_SLICE g=1 fmt_state=%0d fmt_out=%0d fmt_waddr=%0d fmt_raddr=%0d fmt_pause=%0b fmt_tvalid=%0b fmt_idle=%0b | slb_wrdy=%0b slb_pipe=%0d slb_rstate=%0d slb_raddr=%0d slb_waddr=%0d slb_valid=%0b slb_last=%0b slb_sos=%0b",
                                    dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_read_state,
                                    dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_out_count,
                                    dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_dsc_waddr,
                                    dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_raddr,
                                    dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_pause_chunk,
                                    dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.axi_tvalid_out,
                                    dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_write_idle,
                                    dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_write_ready,
                                    dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_slice_buffer_inst.i_pipeline_state,
                                    dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_slice_buffer_inst.i_read_state,
                                    dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_raddr,
                                    dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_slice_buffer_inst.i_axi_waddr,
                                    dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_slice_buffer_inst.dsc_valid_out,
                                    dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_slice_buffer_inst.dsc_last_out,
                                    dut.dsce_engine_inst.gen_slice[1].dsce_slice_inst.dsce_slice_buffer_inst.dsc_start_of_slice);
                        2: $display("STALL_SLICE g=2 fmt_state=%0d fmt_out=%0d fmt_waddr=%0d fmt_raddr=%0d fmt_pause=%0b fmt_tvalid=%0b fmt_idle=%0b | slb_wrdy=%0b slb_pipe=%0d slb_rstate=%0d slb_raddr=%0d slb_waddr=%0d slb_valid=%0b slb_last=%0b slb_sos=%0b",
                                    dut.dsce_engine_inst.gen_slice[2].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_read_state,
                                    dut.dsce_engine_inst.gen_slice[2].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_out_count,
                                    dut.dsce_engine_inst.gen_slice[2].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_dsc_waddr,
                                    dut.dsce_engine_inst.gen_slice[2].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_raddr,
                                    dut.dsce_engine_inst.gen_slice[2].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_pause_chunk,
                                    dut.dsce_engine_inst.gen_slice[2].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.axi_tvalid_out,
                                    dut.dsce_engine_inst.gen_slice[2].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_write_idle,
                                    dut.dsce_engine_inst.gen_slice[2].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_write_ready,
                                    dut.dsce_engine_inst.gen_slice[2].dsce_slice_inst.dsce_slice_buffer_inst.i_pipeline_state,
                                    dut.dsce_engine_inst.gen_slice[2].dsce_slice_inst.dsce_slice_buffer_inst.i_read_state,
                                    dut.dsce_engine_inst.gen_slice[2].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_raddr,
                                    dut.dsce_engine_inst.gen_slice[2].dsce_slice_inst.dsce_slice_buffer_inst.i_axi_waddr,
                                    dut.dsce_engine_inst.gen_slice[2].dsce_slice_inst.dsce_slice_buffer_inst.dsc_valid_out,
                                    dut.dsce_engine_inst.gen_slice[2].dsce_slice_inst.dsce_slice_buffer_inst.dsc_last_out,
                                    dut.dsce_engine_inst.gen_slice[2].dsce_slice_inst.dsce_slice_buffer_inst.dsc_start_of_slice);
                        3: $display("STALL_SLICE g=3 fmt_state=%0d fmt_out=%0d fmt_waddr=%0d fmt_raddr=%0d fmt_pause=%0b fmt_tvalid=%0b fmt_idle=%0b | slb_wrdy=%0b slb_pipe=%0d slb_rstate=%0d slb_raddr=%0d slb_waddr=%0d slb_valid=%0b slb_last=%0b slb_sos=%0b",
                                    dut.dsce_engine_inst.gen_slice[3].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_read_state,
                                    dut.dsce_engine_inst.gen_slice[3].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_out_count,
                                    dut.dsce_engine_inst.gen_slice[3].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_dsc_waddr,
                                    dut.dsce_engine_inst.gen_slice[3].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_raddr,
                                    dut.dsce_engine_inst.gen_slice[3].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_pause_chunk,
                                    dut.dsce_engine_inst.gen_slice[3].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.axi_tvalid_out,
                                    dut.dsce_engine_inst.gen_slice[3].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_write_idle,
                                    dut.dsce_engine_inst.gen_slice[3].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_write_ready,
                                    dut.dsce_engine_inst.gen_slice[3].dsce_slice_inst.dsce_slice_buffer_inst.i_pipeline_state,
                                    dut.dsce_engine_inst.gen_slice[3].dsce_slice_inst.dsce_slice_buffer_inst.i_read_state,
                                    dut.dsce_engine_inst.gen_slice[3].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_raddr,
                                    dut.dsce_engine_inst.gen_slice[3].dsce_slice_inst.dsce_slice_buffer_inst.i_axi_waddr,
                                    dut.dsce_engine_inst.gen_slice[3].dsce_slice_inst.dsce_slice_buffer_inst.dsc_valid_out,
                                    dut.dsce_engine_inst.gen_slice[3].dsce_slice_inst.dsce_slice_buffer_inst.dsc_last_out,
                                    dut.dsce_engine_inst.gen_slice[3].dsce_slice_inst.dsce_slice_buffer_inst.dsc_start_of_slice);
                        default: ;
                    endcase
                end
            end
        end else begin
            stall_wait_cycles <= 0;
        end
    end

`endif

    // 以 <case> 名读取向量文件；空则使用 generated/。
    string  base_path;
    initial begin
        string case_name;
        int    fd;
        void'($value$plusargs("flow_seed=%d", flow_seed));
        void'($value$plusargs("input_gap_pct=%d", input_gap_pct));
        void'($value$plusargs("output_stall_pct=%d", output_stall_pct));
        if (input_gap_pct < 0 || input_gap_pct > 90 ||
            output_stall_pct < 0 || output_stall_pct > 90)
            $fatal(1, "流控百分比必须位于 0..90");
        input_prng = flow_seed ^ 32'h3c6e_f372;
        base_path = "tests/verilator/generated";
        if ($value$plusargs("case=%s", case_name) && case_name.len() > 0)
            base_path = {base_path, "/", case_name};

        fd = $fopen({base_path, "/metadata.txt"}, "r");
        if (fd == 0) $fatal(1, "无法打开 %s/metadata.txt", base_path);
        void'($fscanf(fd, "width=%d", width));
        void'($fscanf(fd, "height=%d", height));
        void'($fscanf(fd, "slice_width=%d", slice_width));
        void'($fscanf(fd, "slice_height=%d", slice_height));
        void'($fscanf(fd, "slices_per_line=%d", slices_per_line));
        void'($fscanf(fd, "beats=%d", beats));
        void'($fscanf(fd, "payload_bytes=%d", payload_bytes));
        $fclose(fd);

        if (beats > kMAX_BEATS || payload_bytes > kMAX_PAYLOAD)
            $fatal(1, "向量超静态数组上限：beats=%0d payload=%0d", beats, payload_bytes);
        $readmemh({base_path, "/pps.hex"}, pps);
        $readmemh({base_path, "/pixels.hex"}, input_beats);
        $readmemh({base_path, "/expected_payload.hex"}, expected_payload);

        $display("CASE=%0s %0dx%0d slice=%0dx%0d spl=%0d beats=%0d payload=%0dB flow_seed=%0d gap=%0d%% stall=%0d%%",
                 case_name.len() ? case_name : "<default>",
                 width, height, slice_width, slice_height, slices_per_line,
                 beats, payload_bytes, flow_seed, input_gap_pct, output_stall_pct);
    end

    initial begin : TestSequence
        int beat_index, timeout;
        int nproc, slices_per_proc, chunk_size, total_slices;

        repeat (8) @(posedge apb_clk);
        async_reset_n = 1'b1;
        repeat (20) @(posedge apb_clk);
        for (int index = 0; index < kSPC*4+2; index++)
            bist_sram_in[index] = 12'h000;

        // 依据 slice 划分计算配置值
        nproc = (slices_per_line < kSPC) ? slices_per_line : kSPC;
        total_slices = slices_per_line * (height / slice_height);
        slices_per_proc = total_slices / nproc;
        chunk_size = slice_width * 12 / 8;

        apb_write32(12'h008, 32'd4);              // pixels per cycle
        apb_write32(12'h030, 32'd4);              // output mode（48-bit 原生）
        // 每位对应尾组中的一个有效像素；整除时三个像素均有效。
        case (slice_width % 3)
            1: apb_write32(12'h040, 32'd1);
            2: apb_write32(12'h040, 32'd3);
            default: apb_write32(12'h040, 32'd7);
        endcase
        apb_write32(12'h044, slices_per_line);    // slices per line
        apb_write32(12'h048, slices_per_proc);    // slices per processor
        apb_write32(12'h04c, nproc);              // slice processor count
        apb_write32(12'h050, 32'd0);
        apb_write32(12'h060, 32'd36);             // max bits per group
        apb_write32(12'h064, 32'd0);              // trailing bits flag
        apb_write32(12'h068, chunk_size);         // chunk size

        // PPS RAM 写入与 commit
        apb_write32(12'h104, 32'd0);
        repeat (2) @(posedge apb_clk);
        for (int index = 0; index < 128; index++)
            apb_write32(12'h100, pps[index]);
        repeat (2) @(posedge apb_clk);
        apb_write32(12'h108, 32'd1);

        pulse_frame();
        repeat (180) @(posedge axi_clk);
        assert (dut.cfg_pps.pic_width == width)
            else $fatal(1, "PPS pic_width=%0d expected %0d",
                        dut.cfg_pps.pic_width, width);
        assert (dut.cfg_pps.pic_height == height)
            else $fatal(1, "PPS pic_height=%0d expected %0d",
                        dut.cfg_pps.pic_height, height);
        assert (dut.cfg_pps.dsc_version_major == 4'd1 &&
                dut.cfg_pps.dsc_version_minor == 4'd2)
            else $fatal(1, "PPS DSC 版本 %0d.%0d 异常",
                        dut.cfg_pps.dsc_version_major, dut.cfg_pps.dsc_version_minor);

        // force_enable + 连续运行
        apb_write32(12'h024, 32'd1);              // force enable
        apb_write32(12'h000, 32'd4);              // start encoder
        timeout = 0;
        while (!dut.axi_encoder_enable && timeout < 200) begin
            @(posedge axi_clk);
            timeout++;
        end
        assert (dut.axi_encoder_enable) else $fatal(1, "编码器未启动");

        // 逐行送入像素；partition 对多 slice 轮换分配，tready 为全体 backpressure。
        beat_index = 0;
        for (int line = 0; line < height; line++) begin
            @(negedge axi_clk);
            axi_tline_in = 1'b1;
            axi_tvalid_in = 1'b0;
            @(negedge axi_clk);
            axi_tline_in = 1'b0;

            for (int column_beat = 0; column_beat < width/4; column_beat++) begin
                input_prng = prng_next(input_prng);
                while ((input_prng % 100) < input_gap_pct) begin
                    axi_tvalid_in = 1'b0;
                    @(negedge axi_clk);
                    input_prng = prng_next(input_prng);
                end
                axi_tdata_in = input_beats[beat_index];
                axi_tvalid_in = 1'b1;
                do @(posedge axi_clk); while (!axi_tready_in);
                @(negedge axi_clk);
                beat_index++;
            end
            axi_tvalid_in = 1'b0;
            axi_tdata_in = 192'h0;

            // 单 slice 下等待本行 slice buffer 读完，避免下一行复用写地址覆盖未编码数据。
// 多 slice 由 partition 的 tready backpressure 自然流控，不做此等待。
            if (slices_per_line == 1) begin
                timeout = 0;
                while (!(dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_slb &&
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_last_slb) &&
                       timeout < 20000) begin
                    @(posedge dsc_clk);
                    timeout++;
                end
                assert (timeout < 20000) else $fatal(1, "slice buffer 行读取超时：line=%0d", line);
            end
        end

        // 等待两路输出完成
        timeout = 0;
        while ((!done_topo || !done_mux || mux_count < payload_bytes) &&
               timeout < 2000000) begin
            @(posedge axi_clk);
            timeout++;
        end

        $display("RESULT accepted=%0d out=%0d top_mis=%0d top_excess=%0d mux=%0d mux_mis=%0d",
                 accepted_input, out_count, top_mis, top_excess, mux_count, mux_mis);
`ifdef DSC_E2E_DEBUG
        $display("PROC_MW cnt=%0d/%0d/%0d/%0d",
                 proc_mw_count[0], proc_mw_count[1], proc_mw_count[2], proc_mw_count[3]);
`endif
        $display("DIAG partition_v=%0d/%0d/%0d/%0d mux_ready=%0d/%0d/%0d/%0d last_in=%0d/%0d/%0d/%0d select_chg=%0d new_frame=%0d",
                 part_valid[0], part_valid[1], part_valid[2], part_valid[3],
                 mux_ready[0], mux_ready[1], mux_ready[2], mux_ready[3],
                 last_in[0], last_in[1], last_in[2], last_in[3],
                 select_chg, new_frame_count, mux_last_ok);
        $display("CFG spl=%0d spo=%0d spc=%0d chunk=%0d",
                 dut.cfg_dsc_encoder.slices_per_line,
                 dut.cfg_dsc_encoder.slices_per_processor,
                 dut.cfg_dsc_encoder.slice_processor_count,
                 dut.cfg_pps.chunk_size);
        if (mux_mis != 0 || top_mis != 0 || out_count != payload_bytes ||
            top_excess != 0 || mux_count != payload_bytes)
            $fatal(1, "端到端 payload 不匹配");
        $display("PASS: RTL payload matches C model (%0d bytes, %0d slices/frame)",
                 out_count, total_slices);
        $finish;
    end

    initial begin
        #200000000 $fatal(1, "全局测试超时");
    end

    initial begin
        $dumpfile("/tmp/dsc_tb_multi.vcd");
        $dumpvars(0, tb_dsc_e2e_multi);
    end
endmodule : tb_dsc_e2e_multi
