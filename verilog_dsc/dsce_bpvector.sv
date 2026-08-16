// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2023, TRILINEAR TECHNOLOGIES, INC.
//
//     THE SOURCE CODE CONTAINED HEREIN IS PROVIDED ON AN "AS IS" BASIS.
//     TRILINEAR TECHNOLOGIES, INC. DISCLAIMS ANY AND ALL WARRANTIES,
//     WHETHER EXPRESS, IMPLIED, OR STATUTORY, INCLUDING ANY IMPLIED
//     WARRANTIES OF MERCHANTABILITY OR OF FITNESS FOR A PARTICULAR PURPOSE.
//     IN NO EVENT SHALL TRILINEAR TECHNOLOGIES, INC. BE LIABLE FOR ANY
//     INCIDENTAL, PUNITIVE, OR CONSEQUENTIAL DAMAGES OF ANY KIND WHATSOEVER
//     ARISING FROM THE USE OF THIS SOURCE CODE.
// ------------------------------------------------------------------------------------------------
//     DESCRIPTION : Block prediction vector search and prediction.
//                   Ported to match the reference model's BlockPredSearch and the verified
//                   bpvector function model: the previous line reconstruction is kept in an
//                   array indexed by absolute pixel position; the SAD is computed over a
//                   9-position window (x-6..x+2) with midpoint substitution at positions <=
//                   candidate; the best of candidates 2..9 (offsets 3..10) is selected with
//                   fallback to offset 1; use_bp requires line>0, bpCount>=3 and
//                   lastEdgeCount<3; the prediction reads the current line reconstruction at
//                   offset selected+1.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;

// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_bpvector
(
    // clock and control interface
    input  logic                        dsc_clk,                // DSC processing clock
    input  logic                        dsc_reset_n,            // DSC domain reset
    input  tDSCE_CONFIG                 cfg_dsc_encoder,        // general encoder configuration
    input  logic                        dsc_pps_update,         // update pps parameters flag
    input  tDSC_PPS                     cfg_pps,                // parameter set output array

    // input path, current group, previous line group
    input  logic                        dsc_valid_in,           // valid data in
    input  logic                        dsc_last_in,            // last group in a slice line
    input  tDSC_PIXEL                   dsc_group_in [2:0],     // source group input
    input  tDSC_PIXEL                   dsc_prev_line_in [5:0], // group from the previous line
    input  tDSC_PIXEL                   dsc_recon_group_in [2:0], // 上一组重建像素反馈

    // pipelined output path
    output logic                        dsc_valid_out,          // valid predicted pixels out
    output logic                        dsc_last_out,           // last group flag output
    output logic                        dsc_use_bp,             // block prediction select
    output logic [3:0]                  dsc_bpvector,           // selected block vector
    output tDSC_PIXEL                   dsc_predict_out [2:0],  // BP prediction
    output tDSC_RESIDUAL_PIXEL          dsc_residual_out [2:0]  // BP residuals
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------
    localparam int kBP_MAX_PIXELS = 4096;

    tDSC_PIXEL          i_prev_arr [kBP_MAX_PIXELS]; // previous line pixels by absolute position
    logic               i_prev_line_valid;
    logic               i_prev_line_last;
    tDSC_PIXEL          i_recon_buf [11:0];          // current line reconstruction history, [0] = x-1

    logic [7:0]         i_bpsad [8:0];               // candidate SAD: 0=offset1, 1..8=offsets 3..10
    logic [3:0]         i_sel_vector;

    logic [10:0]        i_bpcount;                   // consecutive BP selections
    logic [10:0]        i_last_edge_count;           // consecutive non-edge pixels
    logic [15:0]        i_hpos;                      // next group pixel position (x+3)
    logic [15:0]        i_cur_x;                     // current group pixel position x
    logic               i_line_gt0;                  // not the first line
    logic               i_edge_flag;

    logic [2:0]         i_valid_pipe;
    logic [2:0]         i_last_pipe;

    int rx;

    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    // 6-bit modified absolute difference shifted by the component quantization offset
    function automatic logic [5:0] bp_mad (
        input logic [15:0] ref_cpnt,
        input logic [15:0] pred_cpnt,
        input logic [3:0]  shift
    );
        logic signed [16:0] signed_diff;
        logic [15:0] abs_diff;
        logic [15:0] shifted;

        signed_diff = $signed({1'b0, ref_cpnt}) - $signed({1'b0, pred_cpnt});
        abs_diff = (signed_diff[16] == 1'b1) ? (~signed_diff[15:0] + 16'd1) : signed_diff[15:0];
        shifted = abs_diff >> shift;
        bp_mad = (shifted > 6'h3f) ? 6'h3f : shifted[5:0];
    endfunction : bp_mad

    // SAD: candidates 0 (offset 1) and 2..9 (offsets 3..10) over previous[x-6..x+2],
    //   prediction = previous[p-1-c] for p > c else midpoint; 窗口从 max(0,x-6) 开始
    always_comb begin : BpSadCompute
        logic [15:0] mid_y, mid_c;
        logic [3:0] y_shift, c_shift;

        y_shift = cfg_pps.bits_per_component - 4'd7;
        c_shift = cfg_pps.bits_per_component + (cfg_pps.convert_rgb ? 4'd1 : 4'd0) - 4'd7;
        mid_y = 16'h0001 << (cfg_pps.bits_per_component - 4'd1);
        mid_c = 16'h0001 << cfg_pps.bits_per_component;

        for (int ci = 0; ci < 9; ci++) begin
            logic [15:0] total;
            int candidate = (ci == 0) ? 0 : ci + 1;
            total = 16'd0;
            for (int pos = 0; pos < 9; pos++) begin
                logic [15:0] pred_y, pred_co, pred_cg;
                int abs_pos;
                logic use_mid;

                abs_pos = i_cur_x - 6 + pos;
                if (abs_pos >= 0) begin
                    use_mid = (abs_pos <= candidate);
                    if (use_mid) begin
                        pred_y = mid_y;
                        pred_co = mid_c;
                        pred_cg = mid_c;
                    end else begin
                        pred_y = i_prev_arr[abs_pos - 1 - candidate].y;
                        pred_co = i_prev_arr[abs_pos - 1 - candidate].co;
                        pred_cg = i_prev_arr[abs_pos - 1 - candidate].cg;
                    end
                    total = total + bp_mad(i_prev_arr[abs_pos].y,  pred_y,  y_shift);
                    total = total + bp_mad(i_prev_arr[abs_pos].co, pred_co, c_shift);
                    total = total + bp_mad(i_prev_arr[abs_pos].cg, pred_cg, c_shift);
                end
            end
            i_bpsad[ci] = total[10:3];
        end
    end : BpSadCompute


    // -------------------------------------------------------
    //  candidate selection: i_bpsad[0] 为 MAP 基线，扫描候选 2..9（i_bpsad[1..8]）
    //  平局保留较小索引，与 reference model 的严格小于语义一致
    // -------------------------------------------------------
    always_comb begin : CandidateSelect
        logic [8:0] min_sad;
        min_sad = i_bpsad[0];
        i_sel_vector = 4'd0;
        for (int ci = 1; ci < 9; ci++) begin
            if (min_sad > i_bpsad[ci]) begin
                min_sad = i_bpsad[ci];
                i_sel_vector = ci[3:0];
            end
        end
    end : CandidateSelect


    // -------------------------------------------------------
    //  edge detection: previous line adjacent diffs over 3 pixels
    // -------------------------------------------------------
    always_comb begin : EdgeDetect
        logic [15:0] edge_threshold;
        edge_threshold = 16'd32 << (cfg_pps.bits_per_component - 4'd8);
        i_edge_flag = 1'b0;
        for (int sample = 0; sample < 3; sample++) begin
            for (int comp = 0; comp < 3; comp++) begin
                logic [15:0] a, b;
                case (comp)
                    0: begin a = i_prev_arr[i_cur_x + sample].y;  b = i_prev_arr[i_cur_x + sample - 1].y;  end
                    1: begin a = i_prev_arr[i_cur_x + sample].co; b = i_prev_arr[i_cur_x + sample - 1].co; end
                    default: begin a = i_prev_arr[i_cur_x + sample].cg; b = i_prev_arr[i_cur_x + sample - 1].cg; end
                endcase
                if (bp_mad(a, b, 4'd0) > edge_threshold[5:0])
                    i_edge_flag = 1'b1;
            end
        end
    end : EdgeDetect


    // -------------------------------------------------------
    //  Previous line array + horizontal position tracking
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : PrevLineBuffer
        if (dsc_reset_n == 1'b0) begin
            i_prev_arr <= '{default: kDSC_PIXEL_INIT};
            i_prev_line_valid <= 1'b0;
            i_prev_line_last <= 1'b0;
            i_hpos <= 16'd0;
            i_cur_x <= 16'd0;
            i_line_gt0 <= 1'b0;
        end else if (dsc_pps_update == 1'b1) begin
            i_prev_arr <= '{default: kDSC_PIXEL_INIT};
            i_prev_line_valid <= 1'b0;
            i_prev_line_last <= 1'b0;
            i_hpos <= 16'd0;
            i_cur_x <= 16'd0;
            i_line_gt0 <= 1'b0;
        end else begin
            if (dsc_valid_in == 1'b1) begin
                // 当前组的 x = 更新前的 i_hpos
                i_cur_x <= i_hpos;
                i_prev_arr[i_hpos]   <= dsc_prev_line_in[2];
                i_prev_arr[i_hpos+1] <= dsc_prev_line_in[3];
                i_prev_arr[i_hpos+2] <= dsc_prev_line_in[4];
                if (dsc_last_in == 1'b1) begin
                    i_hpos <= 16'd0;
                    i_line_gt0 <= 1'b1;
                end else begin
                    i_hpos <= i_hpos + 16'd3;
                end
            end // if
            i_prev_line_valid <= dsc_valid_in;
            i_prev_line_last <= dsc_last_in;
        end // if
    end : PrevLineBuffer


    // -------------------------------------------------------
    //  Current line reconstruction buffer: i_recon_buf[m] = current_recon[x-1-m]
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : ReconBuffer
        if (dsc_reset_n == 1'b0) begin
            i_recon_buf <= '{default: kDSC_PIXEL_INIT};
        end else if (dsc_valid_in == 1'b1) begin
            i_recon_buf[0] <= dsc_recon_group_in[2];
            i_recon_buf[1] <= dsc_recon_group_in[1];
            i_recon_buf[2] <= dsc_recon_group_in[0];
            i_recon_buf[11:3] <= i_recon_buf[8:0];
        end // if
    end : ReconBuffer


    // -------------------------------------------------------
    //  decision output stage (valid aligned with MPP: 4 cycles)
    // -------------------------------------------------------
    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : DecisionStage
        if (dsc_reset_n == 1'b0) begin
            dsc_valid_out <= 1'b0;
            dsc_last_out <= 1'b0;
            dsc_bpvector <= 4'd0;
            dsc_use_bp <= 1'b0;
            dsc_residual_out <= '{default:kDSC_RESIDUAL_PIXEL_INIT};
            dsc_predict_out <= '{default:kDSC_PIXEL_INIT};

            i_bpcount <= 11'd0;
            i_last_edge_count <= 11'd10;
            i_valid_pipe <= 3'b000;
            i_last_pipe <= 3'b000;

        end else begin

            i_valid_pipe <= {i_valid_pipe[1:0], dsc_valid_in};
            i_last_pipe  <= {i_last_pipe[1:0],  dsc_valid_in && dsc_last_in};
            dsc_valid_out <= i_valid_pipe[2];
            dsc_last_out <= i_last_pipe[2];

            if (i_prev_line_valid == 1'b1) begin
                logic use_bp;
                logic [10:0] next_bpcount;
                logic [10:0] next_edge;

                // 下一拍 bpcount：先按当前组更新，行尾清零在 use_bp 之后（function model 顺序）
                if (cfg_pps.block_pred_enable == 1'b1 && i_cur_x + 16'd2 >= 16'd9)
                    next_bpcount = (i_sel_vector != 4'd0) ? i_bpcount + 11'd1 : 11'd0;
                else
                    next_bpcount = i_bpcount;

                next_edge = (i_edge_flag == 1'b1) ? 11'd0 : i_last_edge_count + 11'd3;

                // use_bp 依据更新后的 bpcount 与 edge count（function model 顺序）
                use_bp = i_line_gt0 && (next_bpcount >= 11'd3) && (next_edge < 11'd3);

                i_bpcount <= (i_prev_line_last == 1'b1) ? 11'd0 : next_bpcount;
                i_last_edge_count <= (i_prev_line_last == 1'b1) ? 11'd10 : next_edge;

                // dsc_bpvector = function model 的 selected（0=MAP，或候选 2..9）
                dsc_bpvector <= (i_sel_vector == 4'd0) ? 4'd0 : i_sel_vector + 4'd1;
                dsc_use_bp <= use_bp;
                for (rx = 0; rx < 3; rx++) begin : ResidualLoop
                    if (use_bp == 1'b1 && i_sel_vector != 4'd0) begin
                        // prediction = current_recon[x+rx-1-c], c = i_sel_vector+1
                        // i_recon_buf[c-rx] = i_recon_buf[i_sel_vector+1-rx]
                        dsc_predict_out[rx] <= i_recon_buf[i_sel_vector + 1 - rx];
                        dsc_residual_out[rx].res_y  <= dsce_compute_residual(i_recon_buf[i_sel_vector + 1 - rx].y,  dsc_group_in[rx].y);
                        dsc_residual_out[rx].res_co <= dsce_compute_residual(i_recon_buf[i_sel_vector + 1 - rx].co, dsc_group_in[rx].co);
                        dsc_residual_out[rx].res_cg <= dsce_compute_residual(i_recon_buf[i_sel_vector + 1 - rx].cg, dsc_group_in[rx].cg);
                    end else begin
                        dsc_predict_out[rx] <= kDSC_PIXEL_INIT;
                        dsc_residual_out[rx].res_y  <= dsce_compute_residual(16'd0, dsc_group_in[rx].y);
                        dsc_residual_out[rx].res_co <= dsce_compute_residual(16'd0, dsc_group_in[rx].co);
                        dsc_residual_out[rx].res_cg <= dsce_compute_residual(16'd0, dsc_group_in[rx].cg);
                    end
                end
            end
        end // if
    end : DecisionStage

endmodule : dsce_bpvector
