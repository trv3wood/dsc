`timescale 1ns/1ps

// 仅供显式调试构建使用；不进入 rtl.f，也不修改标准 e2e testbench。
// monitor 绑定到 multi TB，按 accepted transaction 冻结 slice0 的调试窗口。
module dsc_ich_window_monitor;
    integer trace_file;
    int source_tx = 0;
    int predict_tx = 0;
    int mmap_watch = 0;
    int trace_tx_begin = 170;
    int trace_tx_end = 205;
    int mmap_watch_tx = 189;
    int wave_tx_begin = 0;
    int wave_tx_end = 0;
    bit wave_enabled = 0;
    string trace_path = "/tmp/dsc_ich_window_trace.log";

    initial begin
        void'($value$plusargs("trace_tx_begin=%d", trace_tx_begin));
        void'($value$plusargs("trace_tx_end=%d", trace_tx_end));
        void'($value$plusargs("mmap_watch_tx=%d", mmap_watch_tx));
        void'($value$plusargs("transaction_trace=%s", trace_path));
        wave_enabled = $value$plusargs("wave_tx_begin=%d", wave_tx_begin);
        void'($value$plusargs("wave_tx_end=%d", wave_tx_end));
        if (trace_tx_end < trace_tx_begin)
            $fatal(1, "trace 事务窗口非法: %0d..%0d", trace_tx_begin, trace_tx_end);
        trace_file = $fopen(trace_path, "w");
        if (trace_file == 0)
            $fatal(1, "无法创建事务 trace: %s", trace_path);
        $fwrite(trace_file,
            "META schema=dsc-transaction-v1 slice=0 tx_begin=%0d tx_end=%0d mmap_watch=%0d\n",
            trace_tx_begin, trace_tx_end, mmap_watch_tx);
    end

    initial begin
        #1;
        if (wave_enabled)
            $dumpoff;
    end

    always @(posedge tb_dsc_e2e_multi.dsc_clk) begin : CaptureWindow
        if (tb_dsc_e2e_multi.async_reset_n) begin
            if (tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_fd) begin
                if (wave_enabled && source_tx == wave_tx_begin)
                    $dumpon;
                if (wave_enabled && source_tx == wave_tx_end + 2)
                    $dumpoff;
                if (source_tx >= trace_tx_begin && source_tx <= trace_tx_end) begin
                    $fwrite(trace_file,
                        "SRC tx=%0d qp=%0d px=%012x/%012x/%012x entv=%08x hitcur=%03b combidx=%0d/%0d/%0d\n",
                        source_tx,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_primary_qp,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_group_fd[0],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_group_fd[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_group_fd[2],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.i_ich_entry_valid,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.i_ich_hit_current,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_ich_index_out[0],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_ich_index_out[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_candidate_inst.i_ich_index_out[2]);
                    $fwrite(trace_file,
                        "MMAP tx=%0d prev=%012x/%012x/%012x/%012x/%012x/%012x right=%012x\n",
                        source_tx,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[0],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[2],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[3],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[4],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_prev_line_mmap[5],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_right_pixel_dec);
                end
                if (source_tx == mmap_watch_tx)
                    mmap_watch = 1;
                source_tx++;
            end

            // 只冻结目标事务进入后的六拍，检查 MMAP 内部是否被后续输入覆盖。
            if (mmap_watch > 0 && mmap_watch <= 6) begin
                $fwrite(trace_file,
                    "MMAP_CO_CYCLE n=%0d state=%0d first=%0b/%0b in=%0d/%0d/%0d right=%0d blend=%0d/%0d/%0d/%0d calc0=%0d/%0d/%0d pipe=%0d/%0d qres=%0d/%0d calc1=%0d/%0d/%0d out=%0d/%0d/%0d res=%0d/%0d/%0d\n",
                    mmap_watch,
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_mmap_state,
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_first_line,
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_first_group,
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_group_in[0],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_group_in[1],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_group_in[2],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_right_sample,
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_blend[0],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_blend[1],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_blend[2],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_blend[3],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_predict_calculation_stage_0[0],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_predict_calculation_stage_0[1],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_predict_calculation_stage_0[2],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_predict_pipeline[0],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_predict_pipeline[1],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_quantized_residual[0],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_quantized_residual[1],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_predict_calculation_stage_1[0],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_predict_calculation_stage_1[1],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.i_predict_calculation_stage_1[2],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.dsc_predict_out[0],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.dsc_predict_out[1],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.dsc_predict_out[2],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.dsc_residual_out[0],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.dsc_residual_out[1],
                    tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_predict_inst.dsce_mmap_co_inst.dsc_residual_out[2]);
                mmap_watch++;
            end

            if (tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_pd) begin
                if (predict_tx >= trace_tx_begin && predict_tx <= trace_tx_end) begin
                    $fwrite(trace_file,
                        "ICH_INPUT tx=%0d cfg=%0d/%0b/%0d/%03b sos=%0b last=%0b group=%012x/%012x/%012x flat=%0b vlc=%0d/%0d/%0d ql=%0d/%0d force=%0b pvalid=%0b predict=%012x/%012x/%012x residual=%0d/%0d/%0d hit=%03b index=%0d/%0d/%0d pixel=%012x/%012x/%012x\n",
                        predict_tx,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.cfg_bits_per_component,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.cfg_convert_rgb,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.cfg_dsc_version_minor,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.cfg_slice_alignment,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_start_of_slice,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_group_last_in,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_group_in[0],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_group_in[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_group_in[2],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_ich_next_is_very_flat,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_vlc_size_in[0],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_vlc_size_in[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_vlc_size_in[2],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_qlevel_y_in,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_qlevel_c_in,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_force_mpp_in,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_predict_valid_in,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_predict_group_in[0],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_predict_group_in[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_predict_group_in[2],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_residual_size_in[0],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_residual_size_in[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_residual_size_in[2],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_ich_hit,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_ich_index_in[0],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_ich_index_in[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_ich_index_in[2],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_ich_pixel_in[0],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_ich_pixel_in[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.dsc_ich_pixel_in[2]);
                    $fwrite(trace_file,
                        "RATE tx=%0d coded=%0d rc=%0d feedback=%0d current=%0d current_st=%0d st=%0d out=%0d next=%0d validpipe=%03b fullness=%0d offset=%0d bpg=%0d frac=%0d target=%0d ixd=%0b/%0b/%0d nextixd=%0d chunk=%0d endchunk=%0b adj=%0d minmax=%0d/%0d flat=%0b\n",
                        predict_tx,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_coded_group_size,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_rc_size_group,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_rate_feedback_qp,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_current_qp,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_current_qp_st,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_st_qp,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_rc_primary_qp,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_rc_primary_qp_next,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_valid_pipe,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_buffer_fullness_reg,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_fullness_offset,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_bits_per_group,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_bits_per_group_frac,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_rc_tgt_bits_group,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_ixd_active,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_ixd_end,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_ixd_pixel_count,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_next_ixd_pixel_count,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_chunk_pixel_count,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_end_of_chunk,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_adjustment_bits,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_min_qp,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_rate_inst.i_max_qp,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_vlc_flat_flags_aligned.group_flatness_type);
                    $fwrite(trace_file,
                        "VLC_RATE tx=%0d units=%0d/%0d/%0d rc=%0d/%0d/%0d previch=%0b/%0b/%0b pred=%0d/%0d/%0d adjpred=%0d/%0d/%0d prefix=%0d/%0d/%0d residual=%0d/%0d/%0d flat=%0d/%0d/%0d\n",
                        predict_tx,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_coded_unit_size_vlc[0],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_coded_unit_size_vlc[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_coded_unit_size_vlc[2],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_rcsg_vlc[0],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_rcsg_vlc[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.i_rcsg_vlc[2],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[0].dsce_vlc_inst.i_prev_ich,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[1].dsce_vlc_inst.i_prev_ich,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[2].dsce_vlc_inst.i_prev_ich,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[0].dsce_vlc_inst.i_predicted_size,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[1].dsce_vlc_inst.i_predicted_size,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[2].dsce_vlc_inst.i_predicted_size,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[0].dsce_vlc_inst.i_adj_predicted_size,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[1].dsce_vlc_inst.i_adj_predicted_size,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[2].dsce_vlc_inst.i_adj_predicted_size,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[0].dsce_vlc_inst.i_prefix_size,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[1].dsce_vlc_inst.i_prefix_size,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[2].dsce_vlc_inst.i_prefix_size,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[0].dsce_vlc_inst.i_coded_residual_size,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[1].dsce_vlc_inst.i_coded_residual_size,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[2].dsce_vlc_inst.i_coded_residual_size,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[0].dsce_vlc_inst.i_flatness_size,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[1].dsce_vlc_inst.i_flatness_size,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_format_inst.gen_vlc[2].dsce_vlc_inst.i_flatness_size);
                end
                if (predict_tx <= trace_tx_end) begin
                    $fwrite(trace_file,
                        "UPD tx=%0d sel=%0b last=%0b recon=%012x/%012x/%012x valid=%08x table=",
                        predict_tx,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsc_ich_select_out,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_last_pd,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.i_recon_group[0],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.i_recon_group[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.i_recon_group[2],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_history_inst.i_ich_entry_valid);
                    for (int hx = 0; hx < 25; hx++) begin
                        $fwrite(trace_file, "%012x",
                            tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_history_inst.i_ich_entry_buffer[hx]);
                        if (hx != 24)
                            $fwrite(trace_file, ",");
                    end
                    $fwrite(trace_file, "\n");
                end
                if (predict_tx >= trace_tx_begin && predict_tx <= trace_tx_end) begin
                    $fwrite(trace_file,
                        "PRED tx=%0d qp=%0d ql=%0d/%0d mpp=%03b usebp=%0b raw1=%013x/%013x/%013x hit=%03b idx=%0d/%0d/%0d sel=%0b cost=%0d/%0d log=%0d/%0d prev=%012x/%012x/%012x\n",
                        predict_tx,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_primary_qp_res,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_qlevel_y_res,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_qlevel_c_res,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_mpp_dec,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_use_bp_pd,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_mmap[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_bp[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_residual_mpp[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.i_ich_hit,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.i_ich_index[0],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.i_ich_index[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.i_ich_index[2],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsc_ich_select_out,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.i_predict_mode_cost,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.i_ich_mode_cost,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.i_log_err_predict_mode,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.i_log_err_ich_mode,
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.i_prev_group_in[0],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.i_prev_group_in[1],
                        tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.dsce_ich_inst.dsce_ich_decision_inst.i_prev_group_in[2]);
                end
                predict_tx++;
            end
        end
    end
endmodule

bind tb_dsc_e2e_multi dsc_ich_window_monitor dsc_ich_window_monitor_inst();
