`timescale 1ns/1ps

module tb_dsc_e2e;
    localparam int kSPC = 1;
    localparam int kWIDTH = 96;
    localparam int kHEIGHT = 108;
    localparam int kINPUT_BEATS = kWIDTH * kHEIGHT / 4;
    localparam int kPAYLOAD_BYTES = kWIDTH * kHEIGHT * 12 / 8;

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

    logic [7:0]   pps [0:127];
    logic [191:0] input_beats [0:kINPUT_BEATS-1];
    logic [7:0]   expected_payload [0:kPAYLOAD_BYTES-1];
    logic [47:0]  expected_ssp0_muxwords [0:kPAYLOAD_BYTES/6-1];
    logic [47:0]  expected_ssp1_muxwords [0:kPAYLOAD_BYTES/6-1];
    logic [47:0]  expected_ssp2_muxwords [0:kPAYLOAD_BYTES/6-1];
    logic [20:0]  expected_ssp0_vlc [0:16383];
    logic [20:0]  expected_ssp1_vlc [0:16383];
    logic [20:0]  expected_ssp2_vlc [0:16383];
    logic [7:0]   expected_flatness_flags [0:3455];
    logic [4:0]   expected_flatness_qp [0:3455];
    logic [143:0] expected_flatness_pixels [0:3455];
    logic [152:0] expected_group_residual [0:3455];
    logic [14:0]  expected_group_predicted [0:3455];
    logic [4:0]   expected_group_qp [0:3455];
    logic         expected_group_ich [0:3455];
    logic [14:0]  expected_group_ich_index [0:3455];
    int           output_count = 0;
    int           mismatch_count = 0;
    int           mux_output_count = 0;
    int           mux_mismatch_count = 0;
    int           mux_valid_count = 0;
    int           pre_ram_output_count = 0;
    int           pre_ram_mismatch_count = 0;
    int           excess_output_count = 0;
    int           accepted_input_count = 0;
    int           partition_valid_count = 0;
    int           csc_valid_count = 0;
    int           slice_group_count = 0;
    int           flatness_valid_count = 0;
    int           flatness_flag_nonzero_count = 0;
    int           flatness_flag_print_count = 0;
    int           predict_valid_count = 0;
    int           muxword_count = 0;
    int           write_ready_count = 0;
    int           dsc_write_ready_count = 0;
    int           dsc_pps_update_count = 0;
    int           linemem_collision_count = 0;
    int           ssp_muxword_count [0:2] = '{default: 0};
    int           ssp_muxword_mismatch_count [0:2] = '{default: 0};
    int           ssp_vlc_count [0:2] = '{default: 0};
    int           ssp_vlc_mismatch_count [0:2] = '{default: 0};
    int           decision_line = 0;
    int           decision_group = 0;
    int           rate_group = 0;
    int           flat_adjust_group = 0;
    int           flatness_source_group = 0;
    int           flatness_aligned_group = 0;
    int           flatness_aligned_print_count = 0;
    int           rate_qp_group = 0;
    int           vlc_input_group = 0;
    int           vlc_stable_group = 0;
    int           predict_input_group = 0;

`ifdef DSC_VCD_DUMP
    // make rtl-e2e-trace 传入；普通 make rtl-e2e 不启用，避免无谓的波形写入。
    initial begin
        $dumpfile("tests/verilator/generated/rtl_e2e_trace.vcd");
        $dumpvars(0, tb_dsc_e2e);
    end
`endif

`ifdef DSC_VLC_CAPTURE
    integer       vlc_capture_file;
    int           vlc_capture_count = 0;
    int           vlc_capture_gap = 0;

    initial begin
        vlc_capture_file = $fopen("tests/verilator/generated/vlc_input_trace.hex", "w");
        if (vlc_capture_file == 0)
            $fatal(1, "无法创建 VLC 输入 trace");
    end

    always @(posedge dsc_clk) begin : VlcInputCapture
        vlc_capture_gap++;
        if (async_reset_n &&
            dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_pd) begin
            $fwrite(vlc_capture_file, "%064x\n", {
                vlc_capture_gap[32:0],
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_last_pd,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_primary_qp_res,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_qlevel_y_res,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_qlevel_c_res,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_ich_selected_dec,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_flat_flags_aligned,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_size_dec[0],
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_size_dec[1],
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_size_dec[2],
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_size_dec[0],
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_size_dec[1],
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_size_dec[2],
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_index_ich[0],
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_index_ich[1],
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_index_ich[2],
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[0].res_y,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[1].res_y,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[2].res_y,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[0].res_co,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[1].res_co,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[2].res_co,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[0].res_cg,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[1].res_cg,
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[2].res_cg});
            vlc_capture_count++;
            vlc_capture_gap = 0;
            if (vlc_capture_count == 511) begin
                $fclose(vlc_capture_file);
                $display("VLC_CAPTURE groups=512");
                $finish;
            end
        end
    end
`endif

`ifdef DSC_LUM_FRAG_CAPTURE
    // 转储 RTL ssp0 (luma) VLC 输出片段，用于离线重建位流并与 C model 对比。
    integer       lum_frag_file;
    int           lum_frag_count = 0;
    int           lum_mw_file;
    int           lum_mw_count = 0;

    initial begin
        lum_frag_file = $fopen("tests/verilator/generated/rtl_lum_frag.hex", "w");
        if (lum_frag_file == 0)
            $fatal(1, "无法创建 luma fragment trace");
        lum_mw_file = $fopen("tests/verilator/generated/rtl_lum_muxword.hex", "w");
        if (lum_mw_file == 0)
            $fatal(1, "无法创建 luma muxword trace");
    end

    always @(posedge dsc_clk) begin : LumFragCapture
        if (async_reset_n &&
            dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_valid_vlc[0]) begin
            $fwrite(lum_frag_file, "frag=%0d size=%0d data=%04x last=%0b\n",
                    lum_frag_count,
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_size_vlc[0],
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_data_vlc[0],
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_last_vlc[0]);
            lum_frag_count++;
        end
        if (async_reset_n &&
            dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_valid_mw[0]) begin
            $fwrite(lum_mw_file, "word=%0d data=%012x\n",
                    lum_mw_count,
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_muxword[0][47:0]);
            lum_mw_count++;
        end
    end
`endif

`ifdef DSC_BP_CAPTURE
    // 转储真实顶层的 dsce_bpvector 输入事务，用于独立 replay 对比 RTL 与 function model。
    integer       bp_capture_file;
    int           bp_capture_count = 0;

    function automatic void bp_pixel_fwrite(integer fh, tDSC_PIXEL px);
        $fwrite(fh, "%012x", {px.cg[15:0], px.co[15:0], px.y[15:0]});
    endfunction

    initial begin
        bp_capture_file = $fopen("tests/verilator/generated/bp_input_trace.txt", "w");
        if (bp_capture_file == 0)
            $fatal(1, "无法创建 BP 输入 trace");
    end

    always @(posedge dsc_clk) begin : BpInputCapture
        if (async_reset_n &&
            dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_fd) begin
            $fwrite(bp_capture_file, "%0d", dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_last_fd);
            for (int bp_sample = 0; bp_sample < 3; bp_sample++) begin
                $fwrite(bp_capture_file, " ");
                bp_pixel_fwrite(bp_capture_file,
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_group_fd[bp_sample]);
            end
            for (int bp_prev = 0; bp_prev < 6; bp_prev++) begin
                $fwrite(bp_capture_file, " ");
                bp_pixel_fwrite(bp_capture_file,
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[bp_prev]);
            end
            for (int bp_rec = 0; bp_rec < 3; bp_rec++) begin
                $fwrite(bp_capture_file, " ");
                bp_pixel_fwrite(bp_capture_file,
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_recon_dec[bp_rec]);
            end
            $fwrite(bp_capture_file, "\n");
            bp_capture_count++;
        end
    end
`endif

    // 在下降沿观察下一次 VLC 采样前已稳定的组合信号，排除上升沿 NBA 调度影响。
`ifndef DSC_ICH_MODEL_SUBSTITUTE
    always @(negedge dsc_clk) begin : StableIchTrace
        if (async_reset_n && dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_pd) begin
            if (vlc_stable_group == 395 || vlc_stable_group == 504 ||
                vlc_stable_group == 540 || vlc_stable_group == 671) begin
                $display("ICH_STABLE group=%0d select=%0b index=%0d/%0d/%0d decision_hit=%03b ich_hit=%03b port_hit=%03b raw_hit=%03b mpp_tag=%0d cand_tag=%0d",
                         vlc_stable_group,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_ich_selected_dec,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_index_ich[0],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_index_ich[1],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_index_ich[2],
                         &dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_ich_hit,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.i_ich_hit,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_ich_hit,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.dsc_ich_hit,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mpp_y_inst.i_debug_output_group,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_output_group_count);
            end
            vlc_stable_group++;
        end
    end
`endif

    always #5 apb_clk = ~apb_clk;
    always #4 axi_clk = ~axi_clk;
    always #3 dsc_clk = ~dsc_clk;

    dsc_encoder #(
        .pSLICE_PROCESSOR_COUNT(kSPC),
        .pDEBUG_MESSAGES(0)
    ) dut (.*);

    task automatic apb_write32(input logic [11:0] address, input logic [31:0] data);
        @(negedge apb_clk);
        apb_select = 1'b1;
        apb_enable = 1'b0;
        apb_write = 1'b1;
        apb_strobe = 4'hf;
        apb_addr = address;
        apb_wdata = data;
        @(negedge apb_clk);
        apb_enable = 1'b1;
        do @(posedge apb_clk); while (!apb_ready);
        @(negedge apb_clk);
        apb_select = 1'b0;
        apb_enable = 1'b0;
        apb_write = 1'b0;
        apb_strobe = 4'h0;
    endtask

    task automatic pulse_frame;
        @(negedge axi_clk);
        axi_tframe_in = 1'b1;
        repeat (2) @(negedge axi_clk);
        axi_tframe_in = 1'b0;
    endtask

    // 8bpc 编码核心原生生成 48-bit muxword，首次对拍避免跨字宽重打包。
    always @(posedge axi_clk) begin : Scoreboard
        if (async_reset_n && axi_tvalid_out && axi_tready_out) begin
            if (output_count < 24)
                $display("TOP[%0d]=%012x", output_count/6, axi_tdata_out[47:0]);
            for (int byte_index = 0; byte_index < 6; byte_index++) begin
                if (output_count < kPAYLOAD_BYTES) begin
                    if (axi_tdata_out[byte_index*8 +: 8] !== expected_payload[output_count]) begin
                        if (mismatch_count < 8)
                            $display("MISMATCH byte=%0d expected=%02x actual=%02x word=%048x",
                                     output_count, expected_payload[output_count],
                                     axi_tdata_out[byte_index*8 +: 8], axi_tdata_out);
                        mismatch_count++;
                    end
                end else begin
                    excess_output_count++;
                end
                output_count++;
            end
        end
    end

    // bypass 前的 slice mux 是编码器原生 48-bit 码字流，用它区分编码错误和输出重打包错误。
    always @(posedge axi_clk) begin : MuxScoreboard
        if (async_reset_n && dut.dsce_engine_inst.i_axi_tvalid_mux) begin
            if (mux_valid_count < 12)
                $display("MUX_VALID[%0d] ready=%0b data=%012x bypass_ready=%b",
                         mux_valid_count, dut.dsce_engine_inst.i_axi_tready_mux,
                         dut.dsce_engine_inst.i_axi_tdata_mux[47:0],
                         dut.dsce_engine_inst.dsce_bypass_inst.i_tready_in);
            mux_valid_count++;
        end
        if (async_reset_n && dut.dsce_engine_inst.i_axi_tvalid_mux &&
            dut.dsce_engine_inst.i_axi_tready_mux) begin
            if (mux_output_count < 24)
                $display("MUX[%0d]=%012x", mux_output_count/6,
                         dut.dsce_engine_inst.i_axi_tdata_mux[47:0]);
            for (int byte_index = 0; byte_index < 6; byte_index++) begin
                if (mux_output_count < kPAYLOAD_BYTES &&
                    dut.dsce_engine_inst.i_axi_tdata_mux[byte_index*8 +: 8] !==
                    expected_payload[mux_output_count]) begin
                    if (mux_mismatch_count < 8)
                        $display("MUX_MISMATCH byte=%0d expected=%02x actual=%02x",
                                 mux_output_count, expected_payload[mux_output_count],
                                 dut.dsce_engine_inst.i_axi_tdata_mux[byte_index*8 +: 8]);
                    mux_mismatch_count++;
                end
                mux_output_count++;
            end
        end
    end

    always @(posedge axi_clk) begin : AXIStageCounters
        if (axi_tvalid_in && axi_tready_in)
            accepted_input_count++;
        if (dut.dsce_engine_inst.i_valid_part[0])
            partition_valid_count++;
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_csc)
            csc_valid_count++;
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_axi_write_ready)
            write_ready_count++;
    end

    always @(posedge dsc_clk) begin : DSCStageCounters
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_rc) begin
            if (rate_qp_group < 48)
                $display("RATE_QP group=%0d rc_qp=%0d rc_prev=%0d",
                         rate_qp_group,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_rc_primary_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_rc_prev_qp);
            rate_qp_group++;
        end
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_fd) begin
            if ((predict_input_group < 4) || (predict_input_group >= 1886 && predict_input_group < 1890) ||
                (predict_input_group >= 2045 && predict_input_group < 2050) ||
                (predict_input_group >= 2685 && predict_input_group < 2698)) begin
                $display("FD group=%0d t=%0d st_qp=%0d prim_qp=%0d prev_qp=%0d prim_prev=%0d orig_flat=%0b valid_next=%0b",
                         predict_input_group, $time,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_st_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_primary_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_rc_primary_qp_prev,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_adjust_inst.i_orig_is_flat,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_valid_pipe[2]);
            end
            if ((predict_input_group >= 37 && predict_input_group <= 40) ||
                (predict_input_group >= 384 && predict_input_group <= 386)) begin
                $display("MMAP_INPUT_Y group=%0d current=%0d,%0d,%0d right=%0d q=%0d",
                         predict_input_group,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_group_fd[0].y,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_group_fd[1].y,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_group_fd[2].y,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_right_pixel_dec.y,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_qlevel_y);
                $display("BP_RECON_FEEDBACK group=%0d y=%0d,%0d,%0d co=%0d,%0d,%0d cg=%0d,%0d,%0d",
                         predict_input_group,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_recon_dec[0].y,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_recon_dec[1].y,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_recon_dec[2].y,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_recon_dec[0].co,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_recon_dec[1].co,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_recon_dec[2].co,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_recon_dec[0].cg,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_recon_dec[1].cg,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_recon_dec[2].cg);
                $display("MMAP_INPUT_CO group=%0d,%0d,%0d prev=%0d,%0d,%0d,%0d,%0d,%0d right=%0d q=%0d",
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_group_fd[0].co,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_group_fd[1].co,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_group_fd[2].co,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[0].co,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[1].co,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[2].co,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[3].co,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[4].co,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[5].co,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_right_pixel_dec.co,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_qlevel_c);
                $display("MMAP_INPUT_CG group=%0d,%0d,%0d prev=%0d,%0d,%0d,%0d,%0d,%0d right=%0d q=%0d",
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_group_fd[0].cg,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_group_fd[1].cg,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_group_fd[2].cg,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[0].cg,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[1].cg,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[2].cg,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[3].cg,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[4].cg,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[5].cg,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_right_pixel_dec.cg,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_qlevel_c);
            end
            predict_input_group++;
            if ({dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_group_fd[2],
                 dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_group_fd[1],
                 dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_group_fd[0]} !==
                expected_flatness_pixels[flatness_source_group] && flatness_source_group < 48)
                $display("FLAT_SOURCE_PIXEL_MISMATCH group=%0d", flatness_source_group);
            if (flatness_source_group < 48 &&
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_flat_flags_fd !==
                expected_flatness_flags[flatness_source_group])
                $display("FLAT_SOURCE_MISMATCH group=%0d qp_expected=%0d qp_actual=%0d expected=%02x actual=%02x idx=%0d perform=%0b cand=%0d/%0d/%0d/%0d",
                         flatness_source_group, expected_flatness_qp[flatness_source_group],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_primary_qp,
                         expected_flatness_flags[flatness_source_group],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_flat_flags_fd,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_flatness_inst.dsce_flat_flags_inst.i_output_supergroup_index,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_flatness_inst.dsce_flat_flags_inst.i_perform_flatness_check,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_flatness_inst.dsce_flat_flags_inst.i_candidate_type[0],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_flatness_inst.dsce_flat_flags_inst.i_candidate_type[1],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_flatness_inst.dsce_flat_flags_inst.i_candidate_type[2],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_flatness_inst.dsce_flat_flags_inst.i_candidate_type[3]);
            flatness_source_group++;
        end
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_pd) begin
            if ((vlc_input_group < 4) || (vlc_input_group >= 1886 && vlc_input_group < 1889))
                $display("PD group=%0d t=%0d right=%0d/%0d/%0d recon2=%0d/%0d/%0d last=%0b ichsel=%0b",
                         vlc_input_group, $time,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_right_pixel_dec.y,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_right_pixel_dec.co,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_right_pixel_dec.cg,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_decision_inst.dsc_recon_group_out[2].y,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_decision_inst.dsc_recon_group_out[2].co,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_decision_inst.dsc_recon_group_out[2].cg,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_last_pd,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_decision_inst.dsc_ich_selected_out);
            if (vlc_input_group == 25 ||
                (vlc_input_group >= 37 && vlc_input_group <= 41) ||
                (vlc_input_group >= 60 && vlc_input_group <= 64) ||
                (vlc_input_group >= 384 && vlc_input_group <= 386) ||
                vlc_input_group == 395 || vlc_input_group == 504 || vlc_input_group == 540 ||
                vlc_input_group == 671) begin
                $display("DECISION_BOUNDARY group=%0d bp=%0b vector=%0d force=%0b ich_in=%0b qlevel=%0d/%0d mpp=%03b sizes=%0d/%0d/%0d",
                         vlc_input_group,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_use_bp_pd,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.i_bp_vector,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_force_mpp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_ich_selected,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_qlevel_y_res,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_qlevel_c_res,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_decision_inst.i_use_mpp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_size_dec[0],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_size_dec[1],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_size_dec[2]);
                for (int sample = 0; sample < 3; sample++)
                    $display("DECISION_SAMPLE sample=%0d predict_res=%0d/%0d/%0d quant=%0d/%0d/%0d req=%0d/%0d/%0d",
                             sample,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_decision_inst.i_predict_residual[sample].res_y,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_decision_inst.i_predict_residual[sample].res_co,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_decision_inst.i_predict_residual[sample].res_cg,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_decision_inst.i_quantized_residual[sample].res_y,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_decision_inst.i_quantized_residual[sample].res_co,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_decision_inst.i_quantized_residual[sample].res_cg,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_decision_inst.i_predict_size[sample*3+0],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_decision_inst.i_predict_size[sample*3+1],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_decision_inst.i_predict_size[sample*3+2]);
`ifndef DSC_ICH_MODEL_SUBSTITUTE
                if (vlc_input_group == 395 || vlc_input_group == 504 || vlc_input_group == 540 ||
                    vlc_input_group == 671)
                    $display("ICH_RTL_COST group=%0d mpp_tag=%0d flat=%0b bits=%0d/%0d log=%0d/%0d cost=%0d/%0d valid=%0b select=%0b ich_out=%0b hit=%03b raw_hit=%03b cand_tag=%0d index=%0d/%0d/%0d",
                             vlc_input_group,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mpp_y_inst.i_debug_output_group,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_ich_next_is_very_flat,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.i_bits_p_mode,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.i_bits_ich_mode,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.i_log_err_predict_mode,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.i_log_err_ich_mode,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.i_predict_mode_cost,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.i_ich_mode_cost,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_predict_valid_in,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_ich_select_out,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_ich_selected,
                             &dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_ich_hit,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.dsc_ich_hit,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_output_group_count,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.dsc_ich_index_out[0],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.dsc_ich_index_out[1],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.dsc_ich_index_out[2]);
`endif
            end
            if (vlc_input_group < 3456) begin
                if (!expected_group_ich[vlc_input_group] &&
                    {dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[0].res_y,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[1].res_y,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[2].res_y,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[0].res_co,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[1].res_co,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[2].res_co,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[0].res_cg,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[1].res_cg,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[2].res_cg} !==
                    expected_group_residual[vlc_input_group])
                begin
                    $display("VLC_INPUT_RESIDUAL_MISMATCH group=%0d", vlc_input_group);
                    if ($test$plusargs("STOP_FIRST_BOUNDARY"))
                        $fatal(1, "首个 VLC 输入残差差异");
                end
                if (!expected_group_ich[vlc_input_group] &&
                    {dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_size_dec[0],
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_size_dec[1],
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_size_dec[2]} !==
                    expected_group_predicted[vlc_input_group])
                begin
                    $display("VLC_INPUT_PREDICTED_MISMATCH group=%0d expected=%0d/%0d/%0d actual=%0d/%0d/%0d",
                             vlc_input_group,
                             expected_group_predicted[vlc_input_group][14:10],
                             expected_group_predicted[vlc_input_group][9:5],
                             expected_group_predicted[vlc_input_group][4:0],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_size_dec[0],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_size_dec[1],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_size_dec[2]);
                    if ($test$plusargs("STOP_FIRST_BOUNDARY"))
                        $fatal(1, "首个 VLC 输入 predicted-size 差异");
                end
                if ((vlc_input_group >= 2045 && vlc_input_group < 2051) ||
                    (vlc_input_group >= 2685 && vlc_input_group < 2698))
                    $display("VLC_INPUT_QP group=%0d t=%0d expected=%0d actual=%0d prim_qp=%0d",
                             vlc_input_group, $time, expected_group_qp[vlc_input_group],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_primary_qp_res,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_primary_qp);
                if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_primary_qp_res !==
                    expected_group_qp[vlc_input_group])
                begin
                    $display("VLC_INPUT_QP_MISMATCH group=%0d expected=%0d actual=%0d",
                             vlc_input_group, expected_group_qp[vlc_input_group],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_primary_qp_res);
                    if ($test$plusargs("STOP_FIRST_BOUNDARY"))
                        $fatal(1, "首个 VLC 输入 QP 差异");
                end
                if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_ich_selected_dec !==
                    expected_group_ich[vlc_input_group])
                begin
                    $display("VLC_INPUT_ICH_MISMATCH group=%0d expected=%0b actual=%0b",
                             vlc_input_group, expected_group_ich[vlc_input_group],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_ich_selected_dec);
                    if ($test$plusargs("STOP_FIRST_BOUNDARY"))
                        $fatal(1, "首个 VLC 输入 ICH 差异");
                end
                if (expected_group_ich[vlc_input_group] &&
                    {dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_index_ich[0],
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_index_ich[1],
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_index_ich[2]} !==
                    expected_group_ich_index[vlc_input_group]) begin
                    $display("VLC_INPUT_ICH_INDEX_MISMATCH group=%0d expected=%0d/%0d/%0d actual=%0d/%0d/%0d",
                             vlc_input_group,
                             expected_group_ich_index[vlc_input_group][14:10],
                             expected_group_ich_index[vlc_input_group][9:5],
                             expected_group_ich_index[vlc_input_group][4:0],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_index_ich[0],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_index_ich[1],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_index_ich[2]);
                    if ($test$plusargs("STOP_FIRST_BOUNDARY"))
                        $fatal(1, "首个 VLC 输入 ICH index 差异");
                end
                if (vlc_input_group >= 1494 && vlc_input_group <= 1498) begin
                    $display("ICH_DBG group=%0d qp=%0d valid=%08x hit_cur=%03b hit_reg=%03b idx_comb=%0d/%0d/%0d idx_reg=%0d/%0d/%0d",
                             vlc_input_group,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_primary_qp_res,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.dsc_ich_entry_valid_in,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.dsc_ich_hit_current,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.dsc_ich_hit,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_ich_index_out[0],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_ich_index_out[1],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_ich_index_out[2],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.dsc_ich_index_out[0],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.dsc_ich_index_out[1],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.dsc_ich_index_out[2]);
                    $display("ICH_DBG_K group=%0d s1=%08x s2_min=%0d/%0d/%0d s2_idx=%0d/%0d/%0d sad10=%0d/%0d/%0d sad17=%0d/%0d/%0d",
                             vlc_input_group,
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_suitable_check[1],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_min_sad_stage_2[0][0],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_min_sad_stage_2[1][0],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_min_sad_stage_2[2][0],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_min_index_stage_2[0][0],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_min_index_stage_2[1][0],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_min_index_stage_2[2][0],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_weighted_sad[0][10],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_weighted_sad[1][10],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_weighted_sad[2][10],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_weighted_sad[0][17],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_weighted_sad[1][17],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_weighted_sad[2][17]);
                end
            end
            vlc_input_group++;
            if (flatness_aligned_group < 3456 &&
                dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_flat_flags_aligned !==
                expected_flatness_flags[flatness_aligned_group]) begin
                if (flatness_aligned_print_count < 8)
                    $display("FLAT_ALIGNED_MISMATCH group=%0d expected=%02x actual=%02x",
                             flatness_aligned_group, expected_flatness_flags[flatness_aligned_group],
                             dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_flat_flags_aligned);
                flatness_aligned_print_count++;
            end
            flatness_aligned_group++;
        end
        if (dut.dsc_pps_update)
            dsc_pps_update_count++;
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_write_ready)
            dsc_write_ready_count++;
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_slb)
            slice_group_count++;
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_fd)
            flatness_valid_count++;
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_fd) begin
            if ((flat_adjust_group >= 28 && flat_adjust_group < 40) ||
                (flat_adjust_group >= 380 && flat_adjust_group < 390))
                $display("FLAT_ADJUST group=%0d last=%0b rc_qp=%0d out_qp=%0d saved_last=%0d orig_flat=%0b valid_pipe=%03b last_pipe=%03b",
                         flat_adjust_group,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_last_fd,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_rc_primary_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_primary_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_adjust_inst.i_last_used_qp_in_slice_line,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_adjust_inst.i_orig_is_flat,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_adjust_inst.i_valid_pipe,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_adjust_inst.i_last_pipe);
            flat_adjust_group++;
        end
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_flatness_inst.dsce_flat_flags_inst.i_stage_valid[3] &&
            dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_flatness_inst.dsce_flat_flags_inst.i_buffer_valid[0] &&
            dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_flatness_inst.dsce_flat_flags_inst.i_output_supergroup_index == 2'd3 &&
            flat_adjust_group < 80)
            $display("FLAT_CAND out_group=%0d types=%0d/%0d/%0d/%0d qp=%0d",
                     flat_adjust_group,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_flatness_inst.dsce_flat_flags_inst.i_candidate_type[0],
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_flatness_inst.dsce_flat_flags_inst.i_candidate_type[1],
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_flatness_inst.dsce_flat_flags_inst.i_candidate_type[2],
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_flatness_inst.dsce_flat_flags_inst.i_candidate_type[3],
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_primary_qp);
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_fd &&
            dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_flat_flags_fd != '0) begin
            flatness_flag_nonzero_count++;
            if (flatness_flag_print_count < 20) begin
                $display("FLAT_FLAG group=%0d value=%02x", flat_adjust_group,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_flat_flags_fd);
                flatness_flag_print_count++;
            end
        end
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_pd)
            predict_valid_count++;
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_pd) begin
            if ((decision_line == 0 && (decision_group < 12 || decision_group >= 28)) ||
                (decision_line == 1 && decision_group < 8))
                $display("DECISION line=%0d group=%0d qp=%0d ich=%0b force_mpp=%0b sizes=%0d/%0d/%0d",
                         decision_line, decision_group,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_primary_qp_res,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_ich_selected_dec,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_force_mpp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_size_dec[0],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_size_dec[1],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_size_dec[2]);
            if (decision_line == 1 && decision_group == 0)
                $display("RESIDUAL line=1 group=0 y=%0d/%0d/%0d co=%0d/%0d/%0d cg=%0d/%0d/%0d qlevel=%0d/%0d",
                         $signed(dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[0].res_y),
                         $signed(dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[1].res_y),
                         $signed(dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[2].res_y),
                         $signed(dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[0].res_co),
                         $signed(dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[1].res_co),
                         $signed(dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[2].res_co),
                         $signed(dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[0].res_cg),
                         $signed(dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[1].res_cg),
                         $signed(dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_dec[2].res_cg),
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_qlevel_y_res,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_qlevel_c_res);
            if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_last_pd) begin
                decision_line++;
                decision_group = 0;
            end else begin
                decision_group++;
            end
        end
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_valid_pipe[2]) begin
            if (((rate_group >= 2045) && (rate_group < 2049)) ||
                        ((rate_group >= 2685) && (rate_group < 2698)))
                $display("RATE_RAW group=%0d t=%0d st_qp=%0d prim_qp_reg=%0d valid_next=%0b valid_out=%0b",
                         rate_group, $time,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_st_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_rc_primary_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_valid_pipe[2],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.dsc_qp_valid_out);
            if (((rate_group >= 2045) && (rate_group < 2049)) ||
                        ((rate_group >= 2685) && (rate_group < 2698)))
                $display("RA_DBG group=%0d orig_flat=%0b last_used=%0d range14=%0d prim_qp=%0d prev_qp=%0d rc_prev_in=%0d rc_prim=%0d",
                         rate_group,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_adjust_inst.i_orig_is_flat,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_adjust_inst.i_last_used_qp_in_slice_line,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_adjust_inst.i_range_max_qp_14,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_primary_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_rc_prev_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_rc_primary_qp);
            if ((rate_group < 12) || ((rate_group >= 20) && (rate_group < 42)) ||
                ((rate_group >= 380) && (rate_group < 390)) ||
                ((rate_group >= 700) && (rate_group < 712)) ||
                ((rate_group >= 2044) && (rate_group < 2050)) ||
                ((rate_group >= 2685) && (rate_group < 2698)))
                $display("RATE group=%0d coded=%0d rc=%0d fullness=%0d target=%0d min=%0d max=%0d prev=%0d prev2=%0d current=%0d current_st=%0d inc=%0d/%0d next=%0d decisions=%02x edge=%0d factor=%0d v2=%0b cfgver=%0d",
                         rate_group,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_coded_group_size,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_rc_size_group,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_buffer_fullness_reg,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_rc_tgt_bits_group,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_min_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_max_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_prev_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_prev_2_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_current_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_current_qp_st,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_inc_qp[0],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_inc_qp[1],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_st_qp,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_sterm_decisions,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_rc_size_group_edge,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_rc_edge_factor,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_dsc_version_2_active,
                         dut.cfg_pps.dsc_version_minor);
            rate_group++;
        end
        for (int ssp = 0; ssp < 3; ssp++) begin
            if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_valid_vlc[ssp]) begin
                if ({dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_size_vlc[ssp],
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_data_vlc[ssp]} !==
                    (ssp == 0 ? expected_ssp0_vlc[ssp_vlc_count[ssp]] :
                     ssp == 1 ? expected_ssp1_vlc[ssp_vlc_count[ssp]] :
                                expected_ssp2_vlc[ssp_vlc_count[ssp]])) begin
                    if (ssp_vlc_mismatch_count[ssp] < 4)
                        $display("VLC_MISMATCH ssp=%0d fragment=%0d expected=%06x actual=%06x",
                                 ssp, ssp_vlc_count[ssp],
                                 (ssp == 0 ? expected_ssp0_vlc[ssp_vlc_count[ssp]] :
                                  ssp == 1 ? expected_ssp1_vlc[ssp_vlc_count[ssp]] :
                                             expected_ssp2_vlc[ssp_vlc_count[ssp]]),
                                 {dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_size_vlc[ssp],
                                  dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_data_vlc[ssp]});
                    ssp_vlc_mismatch_count[ssp]++;
                end
                ssp_vlc_count[ssp]++;
            end
            if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_valid_mw[ssp]) begin
                if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_muxword[ssp][47:0] !==
                    (ssp == 0 ? expected_ssp0_muxwords[ssp_muxword_count[ssp]] :
                     ssp == 1 ? expected_ssp1_muxwords[ssp_muxword_count[ssp]] :
                                expected_ssp2_muxwords[ssp_muxword_count[ssp]])) begin
                    if (ssp_muxword_mismatch_count[ssp] < 4)
                        $display("SSP_MISMATCH ssp=%0d word=%0d expected=%012x actual=%012x",
                                 ssp, ssp_muxword_count[ssp],
                                 (ssp == 0 ? expected_ssp0_muxwords[ssp_muxword_count[ssp]] :
                                  ssp == 1 ? expected_ssp1_muxwords[ssp_muxword_count[ssp]] :
                                             expected_ssp2_muxwords[ssp_muxword_count[ssp]]),
                                 dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_muxword[ssp][47:0]);
                    ssp_muxword_mismatch_count[ssp]++;
                end
                ssp_muxword_count[ssp]++;
            end
        end
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_linemem_inst.i_read_enable &&
            dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_linemem_inst.i_write_enable &&
            dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_linemem_inst.i_read_addr ==
            dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_linemem_inst.i_write_addr)
            linemem_collision_count++;
        if (dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_muxword_valid_sb) begin
            muxword_count++;
            if (pre_ram_output_count >= 96 && pre_ram_output_count < 132)
                $display("PRE_RAM word=%0d select=%0d fullness=%0d/%0d/%0d data=%012x",
                         pre_ram_output_count/6,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_stream_builder_inst.i_muxword_tx_select,
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_stream_builder_inst.i_fullness[0],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_stream_builder_inst.i_fullness[1],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_stream_builder_inst.i_fullness[2],
                         dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_muxword_sb[47:0]);
            for (int byte_index = 0; byte_index < 6; byte_index++) begin
                if (pre_ram_output_count < kPAYLOAD_BYTES &&
                    dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_muxword_sb[byte_index*8 +: 8] !==
                    expected_payload[pre_ram_output_count]) begin
                    if (pre_ram_mismatch_count < 8)
                        $display("PRE_RAM_MISMATCH byte=%0d expected=%02x actual=%02x",
                                 pre_ram_output_count, expected_payload[pre_ram_output_count],
                                 dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_muxword_sb[byte_index*8 +: 8]);
                    pre_ram_mismatch_count++;
                end
                pre_ram_output_count++;
            end
        end
    end

    initial begin : TestSequence
        int beat_index;
        int timeout;

        $readmemh("tests/verilator/generated/pps.hex", pps);
        $readmemh("tests/verilator/generated/pixels.hex", input_beats);
        $readmemh("tests/verilator/generated/expected_payload.hex", expected_payload);
        $readmemh("tests/verilator/generated/expected_ssp0_muxwords.hex", expected_ssp0_muxwords);
        $readmemh("tests/verilator/generated/expected_ssp1_muxwords.hex", expected_ssp1_muxwords);
        $readmemh("tests/verilator/generated/expected_ssp2_muxwords.hex", expected_ssp2_muxwords);
        $readmemh("tests/verilator/generated/expected_ssp0_vlc.hex", expected_ssp0_vlc);
        $readmemh("tests/verilator/generated/expected_ssp1_vlc.hex", expected_ssp1_vlc);
        $readmemh("tests/verilator/generated/expected_ssp2_vlc.hex", expected_ssp2_vlc);
        $readmemh("tests/verilator/generated/flatness_expected.hex", expected_flatness_flags);
        $readmemh("tests/verilator/generated/flatness_qp.hex", expected_flatness_qp);
        $readmemh("tests/verilator/generated/flatness_pixels.hex", expected_flatness_pixels);
        $readmemh("tests/verilator/generated/group_residual_expected.hex", expected_group_residual);
        $readmemh("tests/verilator/generated/group_predicted_expected.hex", expected_group_predicted);
        $readmemh("tests/verilator/generated/group_qp_expected.hex", expected_group_qp);
        $readmemh("tests/verilator/generated/group_ich_expected.hex", expected_group_ich);
        $readmemh("tests/verilator/generated/group_ich_index_expected.hex", expected_group_ich_index);
        for (int index = 0; index < kSPC*4+2; index++)
            bist_sram_in[index] = 12'h000;

        repeat (8) @(posedge apb_clk);
        async_reset_n = 1'b1;
        repeat (20) @(posedge apb_clk);

        // 配置单 slice processor、4 pixel/cycle 和原生 48-bit 输出。
        apb_write32(12'h008, 32'd4);
        apb_write32(12'h030, 32'd4);
        apb_write32(12'h040, 32'd7);
        apb_write32(12'h044, 32'd1);
        apb_write32(12'h048, 32'd1);
        apb_write32(12'h04c, 32'd1);
        apb_write32(12'h050, 32'd0);
        apb_write32(12'h060, 32'd36);
        apb_write32(12'h064, 32'd0);
        apb_write32(12'h068, 32'd144);

        // PPS RAM 初始写 bank 0，commit 后交给 AXI 域读取。
        apb_write32(12'h104, 32'd0);
        // APB 写为 posted write；切换索引寄存器后等待其落入 PPS 控制器。
        repeat (2) @(posedge apb_clk);
        for (int index = 0; index < 128; index++)
            apb_write32(12'h100, pps[index]);
        // 确保最后一个 PPS byte 已写入 SRAM 后再 commit。
        repeat (2) @(posedge apb_clk);
        apb_write32(12'h108, 32'd1);

        // frame 边沿触发 PPS 从 SRAM 传输到编码域。
        pulse_frame();
        repeat (180) @(posedge axi_clk);
        assert (dut.cfg_pps.pic_width == kWIDTH)
            else $fatal(1, "PPS pic_width 未加载：%0d", dut.cfg_pps.pic_width);
        assert (dut.cfg_pps.pic_height == kHEIGHT)
            else $fatal(1, "PPS pic_height 未加载：%0d", dut.cfg_pps.pic_height);
        assert (dut.cfg_pps.chunk_size == 16'd144)
            else $fatal(1, "PPS chunk_size 未加载：%0d", dut.cfg_pps.chunk_size);
        assert (dut.cfg_pps.dsc_version_major == 4'd1 && dut.cfg_pps.dsc_version_minor == 4'd2)
            else $fatal(1, "PPS DSC 版本未加载：%0d.%0d",
                        dut.cfg_pps.dsc_version_major, dut.cfg_pps.dsc_version_minor);
        $display("PPS bytes=%02x/%02x/%02x/%02x version=%0d.%0d bpc=%0d",
                 dut.dsce_pps_inst.i_pps[0], dut.dsce_pps_inst.i_pps[1],
                 dut.dsce_pps_inst.i_pps[2], dut.dsce_pps_inst.i_pps[3],
                 dut.cfg_pps.dsc_version_major, dut.cfg_pps.dsc_version_minor,
                 dut.cfg_pps.bits_per_component);

        // force_enable 避免依赖外部持续 VSYNC，再启动连续运行模式。
        apb_write32(12'h024, 32'd1);
        apb_write32(12'h000, 32'd4);
        timeout = 0;
        while (!dut.axi_encoder_enable && timeout < 200) begin
            @(posedge axi_clk);
            timeout++;
        end
        assert (dut.axi_encoder_enable) else $fatal(1, "编码器未启动");

        beat_index = 0;
        for (int line = 0; line < kHEIGHT; line++) begin
            // tline 是独立的行起始指示周期，RTL 在该周期清零 pack 状态。
            @(negedge axi_clk);
            axi_tline_in = 1'b1;
            axi_tvalid_in = 1'b0;
            @(negedge axi_clk);
            axi_tline_in = 1'b0;

            for (int column_beat = 0; column_beat < kWIDTH/4; column_beat++) begin
                axi_tdata_in = input_beats[beat_index];
                axi_tvalid_in = 1'b1;
                do @(posedge axi_clk); while (!axi_tready_in);
                @(negedge axi_clk);
                beat_index++;
            end
            axi_tvalid_in = 1'b0;
            axi_tdata_in = 192'h0;

            // slice buffer 在每行结束后写地址归零；等待读侧消费完本行，避免下一行覆盖。
            timeout = 0;
            while (!(dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_slb &&
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_last_slb) &&
                   timeout < 20000) begin
                @(posedge dsc_clk);
                timeout++;
            end
            assert (timeout < 20000) else $fatal(1, "slice buffer 行读取超时：line=%0d", line);
        end

        timeout = 0;
        while (mux_output_count < kPAYLOAD_BYTES && timeout < 200000) begin
            @(posedge axi_clk);
            timeout++;
        end
        if (mux_output_count < kPAYLOAD_BYTES) begin
        $display("PIPELINE input=%0d partition=%0d csc=%0d groups=%0d flat=%0d flat_flags=%0d predict=%0d muxwords=%0d",
                 accepted_input_count, partition_valid_count, csc_valid_count,
                 slice_group_count, flatness_valid_count, flatness_flag_nonzero_count,
                 predict_valid_count, muxword_count);
            $display("COMPARE pre_ram_bytes=%0d pre_ram_mismatches=%0d mux_bytes=%0d mux_mismatches=%0d",
                     pre_ram_output_count, pre_ram_mismatch_count,
                     mux_output_count, mux_mismatch_count);
            $display("CDC write_ready_cycles=%0d dsc_ready_cycles=%0d pps_update_cycles=%0d",
                     write_ready_count, dsc_write_ready_count, dsc_pps_update_count);
            $display("SUPPORT linemem_same_address_collisions=%0d", linemem_collision_count);
            $display("SSP words=%0d/%0d/%0d mismatches=%0d/%0d/%0d",
                     ssp_muxword_count[0], ssp_muxword_count[1], ssp_muxword_count[2],
                     ssp_muxword_mismatch_count[0], ssp_muxword_mismatch_count[1],
                     ssp_muxword_mismatch_count[2]);
            $display("VLC fragments=%0d/%0d/%0d mismatches=%0d/%0d/%0d",
                     ssp_vlc_count[0], ssp_vlc_count[1], ssp_vlc_count[2],
                     ssp_vlc_mismatch_count[0], ssp_vlc_mismatch_count[1],
                     ssp_vlc_mismatch_count[2]);
            $display("STATE axi_enable=%0b dsc_enable=%0b overflow=%0b slb_waddr=%0d slb_raddr=%0d read_state=%0d pipe_state=%0d width=%0d height=%0d fmt_waddr=%0d fmt_raddr=%0d",
                     dut.axi_encoder_enable, dut.dsc_encoder_enable,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_slice_buffer_overflow,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_axi_waddr,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_raddr,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_read_state,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_pipeline_state,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_slice_width,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_slice_buffer_inst.i_dsc_slice_height,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_dsc_waddr,
                     dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.dsce_format_buffer_inst.i_axi_raddr);
            $fatal(1, "输出超时：mux_got=%0d expected=%0d", mux_output_count, kPAYLOAD_BYTES);
        end
        repeat (20) @(posedge axi_clk);
        $display("RESULT mux_bytes=%0d mux_mismatches=%0d top_bytes=%0d top_mismatches=%0d excess=%0d",
                 mux_output_count, mux_mismatch_count, output_count, mismatch_count,
                 excess_output_count);
        if (mux_mismatch_count != 0 || mismatch_count != 0 ||
            output_count != kPAYLOAD_BYTES || excess_output_count != 0)
            $fatal(1, "端到端 payload 不匹配");

        $display("PASS: RTL payload matches C model (%0d bytes)", output_count);
        $finish;
    end

    initial begin
        #5000000 $fatal(1, "全局测试超时");
    end
endmodule
