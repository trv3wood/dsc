`timescale 1ns/1ps

import dsce_defs_pkg::*;

module tb_dsc_vlc_replay;
    localparam int kGROUPS = 512;

    typedef struct packed {
        logic [32:0] pad;
        logic last;
        logic [4:0] primary_qp;
        logic [4:0] qlevel_y;
        logic [4:0] qlevel_c;
        logic ich_selected;
        tDSC_FLAT_FLAGS flatness;
        logic [2:0][4:0] residual_size;
        logic [2:0][4:0] vlc_size;
        logic [2:0][4:0] ich_index;
        logic [2:0][2:0][16:0] residual;
    } trace_entry_t;

    logic dsc_clk = 1'b0;
    logic dsc_reset_n = 1'b0;
    logic dsc_pps_update = 1'b0;
    logic dsc_start_of_slice = 1'b0;
    logic dsc_predict_valid_in = 1'b0;
    tDSC_PPS cfg_pps = kDSC_PPS_INIT;
    trace_entry_t trace [0:kGROUPS-1];
    trace_entry_t current = '0;
    tDSC_RESIDUAL residual_drive [2:0][2:0];

    logic rtl_unit_valid [2:0];
    logic [5:0] rtl_coded_size [2:0];
    logic [5:0] rtl_rc_size [2:0];
    logic rtl_valid [2:0];
    logic rtl_last [2:0];
    logic [4:0] rtl_size [2:0];
    logic [15:0] rtl_data [2:0];
    logic model_unit_valid [2:0];
    logic [5:0] model_coded_size [2:0];
    logic [5:0] model_rc_size [2:0];
    logic model_valid [2:0];
    logic model_last [2:0];
    logic [4:0] model_size [2:0];
    logic [15:0] model_data [2:0];

    logic [20:0] expected_0 [0:16383];
    logic [20:0] expected_1 [0:16383];
    logic [20:0] expected_2 [0:16383];
    int rtl_count [2:0] = '{default: 0};
    int model_count [2:0] = '{default: 0};
    int rtl_mismatches [2:0] = '{default: 0};
    int model_mismatches [2:0] = '{default: 0};
    int size_mismatches = 0;
    bit expected_bits_0[$];
    bit expected_bits_1[$];
    bit expected_bits_2[$];
    int rtl_bit_count [2:0] = '{default: 0};
    int model_bit_count [2:0] = '{default: 0};
    int rtl_bit_mismatches [2:0] = '{default: 0};
    int model_bit_mismatches [2:0] = '{default: 0};

    function automatic logic [20:0] expected_fragment(input int unit, input int index);
        case (unit)
            1: expected_fragment = expected_1[index];
            2: expected_fragment = expected_2[index];
            default: expected_fragment = expected_0[index];
        endcase
    endfunction

    function automatic int expected_fragment_count(input int unit);
        return unit == 0 ? 9230 : 6675;
    endfunction

    always #3 dsc_clk = ~dsc_clk;

    always_comb begin : ResidualAdapter
        for (int unit = 0; unit < 3; unit++)
            for (int sample = 0; sample < 3; sample++)
                residual_drive[unit][sample] =
                    tDSC_RESIDUAL'(current.residual[2-unit][2-sample]);
    end

    generate for (genvar unit = 0; unit < 3; unit++) begin : gen_units
        dsce_vlc #(.pCOLOR_SELECT(unit)) rtl (
            .dsc_clk, .dsc_reset_n, .dsc_pps_update, .cfg_pps,
            .dsc_start_of_slice, .dsc_predict_valid_in,
            .dsc_predict_last_in(current.last),
            .dsc_residual_in(residual_drive[unit]),
            .dsc_residual_size_in(current.residual_size[2-unit]),
            .dsc_vlc_size_in(current.vlc_size[2-unit]),
            .dsc_primary_qp_in(current.primary_qp),
            .dsc_qlevel_y_in(current.qlevel_y),
            .dsc_qlevel_c_in(current.qlevel_c),
            .dsc_ich_selected_in(current.ich_selected),
            .dsc_ich_index_in(current.ich_index[2-unit]),
            .dsc_flatness_in(current.flatness),
            .dsc_unit_size_valid(rtl_unit_valid[unit]),
            .dsc_coded_unit_size(rtl_coded_size[unit]),
            .dsc_rc_size_unit(rtl_rc_size[unit]),
            .dsc_vlc_valid_out(rtl_valid[unit]),
            .dsc_vlc_last_out(rtl_last[unit]),
            .dsc_vlc_size_out(rtl_size[unit]),
            .dsc_vlc_data_out(rtl_data[unit]));

        dsce_vlc_function_model #(.pCOLOR_SELECT(unit)) model (
            .dsc_clk, .dsc_reset_n, .dsc_pps_update, .cfg_pps,
            .dsc_start_of_slice, .dsc_predict_valid_in,
            .dsc_predict_last_in(current.last),
            .dsc_residual_in(residual_drive[unit]),
            .dsc_residual_size_in(current.residual_size[2-unit]),
            .dsc_vlc_size_in(current.vlc_size[2-unit]),
            .dsc_primary_qp_in(current.primary_qp),
            .dsc_qlevel_y_in(current.qlevel_y),
            .dsc_qlevel_c_in(current.qlevel_c),
            .dsc_ich_selected_in(current.ich_selected),
            .dsc_ich_index_in(current.ich_index[2-unit]),
            .dsc_flatness_in(current.flatness),
            .dsc_unit_size_valid(model_unit_valid[unit]),
            .dsc_coded_unit_size(model_coded_size[unit]),
            .dsc_rc_size_unit(model_rc_size[unit]),
            .dsc_vlc_valid_out(model_valid[unit]),
            .dsc_vlc_last_out(model_last[unit]),
            .dsc_vlc_size_out(model_size[unit]),
            .dsc_vlc_data_out(model_data[unit]));
    end endgenerate

    always @(posedge dsc_clk) begin : Scoreboard
        for (int unit = 0; unit < 3; unit++) begin
            if (rtl_valid[unit]) begin
                if (unit == 0 && rtl_count[unit] >= 62 && rtl_count[unit] < 76)
                    $display("RTL_SCHED fragment=%0d size=%0d data=%04x expected=%06x bit_count=%0d",
                             rtl_count[unit], rtl_size[unit], rtl_data[unit],
                             expected_fragment(unit, rtl_count[unit]), rtl_bit_count[unit]);
                for (int bit_index = int'(rtl_size[unit]) - 1; bit_index >= 0; bit_index--) begin
                    bit expected_bit;
                    case (unit)
                        1: expected_bit = expected_bits_1[rtl_bit_count[unit]];
                        2: expected_bit = expected_bits_2[rtl_bit_count[unit]];
                        default: expected_bit = expected_bits_0[rtl_bit_count[unit]];
                    endcase
                    if (rtl_data[unit][bit_index] !== expected_bit) begin
                        if (rtl_bit_mismatches[unit] < 2)
                            $display("RTL_BIT_MISMATCH unit=%0d bit=%0d fragment=%0d fragment_bit=%0d expected=%0b actual=%0b",
                                     unit, rtl_bit_count[unit],
                                     rtl_count[unit], bit_index,
                                     expected_bit, rtl_data[unit][bit_index]);
                        rtl_bit_mismatches[unit]++;
                    end
                    rtl_bit_count[unit]++;
                end
                if ({rtl_size[unit], rtl_data[unit]} !== expected_fragment(unit, rtl_count[unit])) begin
                    if (rtl_mismatches[unit] < 2)
                        $display("RTL_MISMATCH unit=%0d fragment=%0d expected=%06x actual=%06x",
                                 unit, rtl_count[unit], expected_fragment(unit, rtl_count[unit]),
                                 {rtl_size[unit], rtl_data[unit]});
                    rtl_mismatches[unit]++;
                end
                rtl_count[unit]++;
            end
            if (model_valid[unit]) begin
                for (int bit_index = int'(model_size[unit]) - 1; bit_index >= 0; bit_index--) begin
                    bit expected_bit;
                    case (unit)
                        1: expected_bit = expected_bits_1[model_bit_count[unit]];
                        2: expected_bit = expected_bits_2[model_bit_count[unit]];
                        default: expected_bit = expected_bits_0[model_bit_count[unit]];
                    endcase
                    if (model_data[unit][bit_index] !== expected_bit) begin
                        if (model_bit_mismatches[unit] < 2)
                            $display("MODEL_BIT_MISMATCH unit=%0d bit=%0d fragment=%0d fragment_bit=%0d expected=%0b actual=%0b",
                                     unit, model_bit_count[unit],
                                     model_count[unit], bit_index,
                                     expected_bit, model_data[unit][bit_index]);
                        model_bit_mismatches[unit]++;
                    end
                    model_bit_count[unit]++;
                end
                if ({model_size[unit], model_data[unit]} !== expected_fragment(unit, model_count[unit])) begin
                    if (model_mismatches[unit] < 2)
                        $display("MODEL_MISMATCH unit=%0d fragment=%0d expected=%06x actual=%06x",
                                 unit, model_count[unit], expected_fragment(unit, model_count[unit]),
                                 {model_size[unit], model_data[unit]});
                    model_mismatches[unit]++;
                end
                model_count[unit]++;
            end
            if (rtl_unit_valid[unit] && model_unit_valid[unit] &&
                ({rtl_coded_size[unit], rtl_rc_size[unit]} !==
                 {model_coded_size[unit], model_rc_size[unit]}))
                size_mismatches++;
        end
    end

    initial begin : TestSequence
        $readmemh("tests/verilator/generated/vlc_input_trace.hex", trace);
        $readmemh("tests/verilator/generated/expected_ssp0_vlc.hex", expected_0);
        $readmemh("tests/verilator/generated/expected_ssp1_vlc.hex", expected_1);
        $readmemh("tests/verilator/generated/expected_ssp2_vlc.hex", expected_2);
        for (int fragment = 0; fragment < expected_fragment_count(0); fragment++) begin
            for (int bit_index = int'(expected_0[fragment][20:16]) - 1; bit_index >= 0; bit_index--)
                expected_bits_0.push_back(expected_0[fragment][bit_index]);
        end
        for (int fragment = 0; fragment < expected_fragment_count(1); fragment++) begin
            for (int bit_index = int'(expected_1[fragment][20:16]) - 1; bit_index >= 0; bit_index--)
                expected_bits_1.push_back(expected_1[fragment][bit_index]);
        end
        for (int fragment = 0; fragment < expected_fragment_count(2); fragment++) begin
            for (int bit_index = int'(expected_2[fragment][20:16]) - 1; bit_index >= 0; bit_index--)
                expected_bits_2.push_back(expected_2[fragment][bit_index]);
        end
        repeat (4) @(posedge dsc_clk);
        dsc_reset_n = 1'b1;
        cfg_pps.bits_per_component = 4'd8;
        cfg_pps.convert_rgb = 1'b1;
        cfg_pps.flatness_min_qp = 5'd3;
        cfg_pps.flatness_max_qp = 5'd12;
        @(negedge dsc_clk);
        dsc_pps_update = 1'b1;
        dsc_start_of_slice = 1'b1;
        @(negedge dsc_clk);
        dsc_pps_update = 1'b0;
        dsc_start_of_slice = 1'b0;

        for (int group_index = 0; group_index < kGROUPS; group_index++) begin
            if (group_index != 0)
                repeat (int'(trace[group_index].pad) - 1) @(negedge dsc_clk);
            current = trace[group_index];
            dsc_predict_valid_in = 1'b1;
            @(negedge dsc_clk);
            dsc_predict_valid_in = 1'b0;
        end
        // luma 每组可能产生多于四个 fragment，留足时间排空内部调度器。
        repeat (512) @(negedge dsc_clk);
        $display("VLC_REPLAY rtl_fragments=%0d/%0d/%0d rtl_mismatches=%0d/%0d/%0d",
                 rtl_count[0], rtl_count[1], rtl_count[2],
                 rtl_mismatches[0], rtl_mismatches[1], rtl_mismatches[2]);
        $display("VLC_REPLAY model_fragments=%0d/%0d/%0d model_mismatches=%0d/%0d/%0d size_mismatches=%0d",
                 model_count[0], model_count[1], model_count[2],
                 model_mismatches[0], model_mismatches[1], model_mismatches[2], size_mismatches);
        $display("VLC_REPLAY_BITS rtl=%0d/%0d/%0d mismatches=%0d/%0d/%0d model=%0d/%0d/%0d mismatches=%0d/%0d/%0d",
                 rtl_bit_count[0], rtl_bit_count[1], rtl_bit_count[2],
                 rtl_bit_mismatches[0], rtl_bit_mismatches[1], rtl_bit_mismatches[2],
                 model_bit_count[0], model_bit_count[1], model_bit_count[2],
                 model_bit_mismatches[0], model_bit_mismatches[1], model_bit_mismatches[2]);
        $finish;
    end
endmodule
