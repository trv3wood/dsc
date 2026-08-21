`timescale 1ns/1ps

// 仅供显式调试构建使用；不进入 rtl.f，也不修改标准 e2e testbench。
// monitor 绑定到 multi TB，冻结 slice0 在首个 ICH 分歧附近的事务窗口。
module dsc_ich_window_monitor;
    integer trace_file;
    int source_tx = 0;
    int predict_tx = 0;
    int mmap_watch = 0;

    initial begin
        trace_file = $fopen("/tmp/dsc_ich_window_trace.log", "w");
        if (trace_file == 0)
            $fatal(1, "无法创建 ICH 窗口 trace");
    end

    always @(posedge tb_dsc_e2e_multi.dsc_clk) begin : CaptureWindow
        if (tb_dsc_e2e_multi.async_reset_n) begin
            if (tb_dsc_e2e_multi.dut.dsce_engine_inst.gen_slice[0].dsce_slice_inst.i_valid_fd) begin
                if (source_tx >= 170 && source_tx <= 205) begin
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
                if (source_tx == 189)
                    mmap_watch = 1;
                source_tx++;
            end

            // 只冻结 tx189 进入后的四拍，检查 MMAP 内部是否被后续输入覆盖。
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
                if (predict_tx <= 200) begin
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
                if (predict_tx >= 170 && predict_tx <= 205) begin
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
