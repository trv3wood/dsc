// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2016-2023, TRILINEAR TECHNOLOGIES, INC.
//     CONFIDENTIAL AND PROPRIETARY
//
//     THE SOURCE CODE CONTAINED HEREIN IS PROVIDED ON AN "AS IS" BASIS.
//     TRILINEAR TECHNOLOGIES, INC. DISCLAIMS ANY AND ALL WARRANTIES,
//     WHETHER EXPRESS, IMPLIED, OR STATUTORY, INCLUDING ANY IMPLIED
//     WARRANTIES OF MERCHANTABILITY OR OF FITNESS FOR A PARTICULAR PURPOSE.
//     IN NO EVENT SHALL TRILINEAR TECHNOLOGIES, INC. BE LIABLE FOR ANY
//     INCIDENTAL, PUNITIVE, OR CONSEQUENTIAL DAMAGES OF ANY KIND WHATSOEVER
//     ARISING FROM THE USE OF THIS SOURCE CODE.
//
//     THIS DISCLAIMER OF WARRANTY EXTENDS TO THE USER OF THIS SOURCE CODE
//     AND USER'S CUSTOMERS, EMPLOYEES, AGENTS, TRANSFEREES, SUCCESSORS,
//     AND ASSIGNS.
//
//     THIS IS NOT A GRANT OF PATENT RIGHTS
// ------------------------------------------------------------------------------------------------
//     DESCRIPTION : Top level RTL descritpion for the hardware slice processor.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  entity declaration
// ----------------------------------------------
module dsce_slice
#(
    parameter int pSPC                      = 4,        // hardware slice processor count
    parameter int pMAX_SLICE_LINE_SIZE      = 4096,     // maximum slice line size
    parameter int pINCLUDE_BLOCK_PREDICTION = 1,        // includes support for block prediction
    parameter int pDEBUG_MESSAGES           = 1         // display debug messages
)
(
    // clock and control interface
    input  logic                axi_clk,                // AXI input and output clock
    input  logic                axi_reset_n,            // AXI domain reset
    input  logic                axi_pps_update,         // update flag
    input  logic                axi_encoder_enable,     // encoder enable
    input  tDSCE_CONFIG         cfg_dsc_encoder,        // general encoder configuration
    input  tDSC_PPS             cfg_pps,                // parameter set output array
    input  tDSC_RCPS            cfg_rcps,               // rate control parameter set
    output tDSCE_SLICE_STATUS   cfg_slice_status,       // slice status

    // streaming input data path
    input  logic                axi_valid_in,           // valid data in
    output logic                axi_ready_in,           // ready to accept
    input  logic                axi_frame_in,           // frame reset input
    input  logic                axi_last_in,            // last pixel in a line
    input  tSTD_PIXEL           axi_data_in [3:0],      // streaming input

    // apb programming interface
    input  logic                apb_clk,                // APB host domain
    input  logic                apb_reset_n,            // APB domain reset

    // internal data path for encoding
    input  logic                dsc_clk,                // encoding clock
    input  logic                dsc_reset_n,            // encoder domain reset
    input  logic                dsc_encoder_enable,     // encoder enable
    input  logic                dsc_pps_update,         // update flag

    // output to the slice mux
    output logic                axi_last_out,           // last flag output
    output logic                axi_tvalid_out,         // data ready flag output
    input  logic                axi_tready_out,         // data accept from the slice mux
    output logic [63:0]         axi_muxword_out,        // mux word for inclusion in the slice stream

    // memory BIST interface
    input  logic [11:0]         bist_sram_in  [3:0],    // BIST input, 3 SRAMs
    output logic [11:0]         bist_sram_out [3:0]     // BIST output, 3 SRAMs
);

    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    logic                       i_start_of_slice_slb;
    logic                       i_valid_slb;
    logic                       i_last_slb;
    tDSC_PIXEL                  i_group_slb [2:0];
    logic                       i_slice_buffer_overflow;

    logic                       i_valid_csc;
    logic                       i_last_csc;
    tDSC_PIXEL                  i_data_csc [3:0];

    tDSC_PIXEL                  i_prev_line_mmap [5:0];
    tDSC_PIXEL                  i_prev_line_ich [6:0];

    logic                       i_valid_rc, i_valid_rc_next;
    tDSC_QLEVEL                 i_qlevel_y, i_qlevel_y_res;
    tDSC_QLEVEL                 i_qlevel_c, i_qlevel_c_res;
    logic                       i_force_mpp;

    tDSC_QLEVEL                 i_rc_primary_qp, i_rc_primary_qp_next, i_rc_primary_qp_prev, i_rc_prev_qp;
    tDSC_QLEVEL                 i_primary_qp, i_primary_qp_res, i_prev_qp;

    logic                       i_valid_fd;
    logic                       i_last_fd;
    tDSC_PIXEL                  i_group_fd [2:0];
    tDSC_FLAT_FLAGS             i_vlc_flat_flags_fd;
    logic                       i_valid_fd_raw;
    logic                       i_last_fd_raw;
    tDSC_PIXEL                  i_group_fd_raw [2:0];
    tDSC_FLAT_FLAGS             i_vlc_flat_flags_fd_raw;
    logic                       i_fd_pop;
    logic [3:0]                 i_fd_write_ptr;
    logic [3:0]                 i_fd_read_ptr;
    logic [4:0]                 i_fd_count;
    logic [1:0]                 i_fd_cooldown;
    logic                       i_fd_last_fifo [15:0];
    tDSC_PIXEL                  i_fd_group_fifo [15:0][2:0];
    tDSC_FLAT_FLAGS             i_fd_flags_fifo [15:0];
    tDSC_FLAT_FLAGS             i_vlc_flat_flags_fifo [7:0];
    tDSC_FLAT_FLAGS             i_vlc_flat_flags_aligned;
    logic [2:0]                 i_flat_flags_write_ptr;
    logic [2:0]                 i_flat_flags_read_ptr;
    logic [3:0]                 i_flat_flags_count;
    logic                       i_ich_next_is_very_flat;

    logic                       i_valid_pd;
    logic                       i_last_pd;
    logic                       i_use_bp_pd;
    tDSC_PIXEL                  i_predict_mmap [2:0];
    tDSC_PIXEL                  i_predict_mpp [2:0];
    tDSC_PIXEL                  i_predict_bp [2:0];
    tDSC_RESIDUAL_PIXEL         i_residual_mmap [2:0];
    tDSC_RESIDUAL_PIXEL         i_residual_mpp [2:0];
    tDSC_RESIDUAL_PIXEL         i_residual_bp [2:0];

    logic                       i_ich_selected_dec;
    logic [2:0]                 i_mpp_dec;
    tDSC_PIXEL                  i_predict_dec [2:0];
    tDSC_RESIDUAL_PIXEL         i_residual_dec [2:0];
    logic [4:0]                 i_residual_size_dec [2:0];
    logic [4:0]                 i_vlc_size_dec [2:0];
    tDSC_PIXEL                  i_recon_dec [2:0];
    tDSC_PIXEL                  i_right_pixel_dec;

    logic                       i_ich_selected;
    tDSC_PIXEL                  i_ich_group [2:0];
    tDSC_ICH_INDEX              i_index_ich [2:0];

    logic [7:0]                 i_coded_group_size;
    logic [7:0]                 i_rc_size_group;

    // ------------------------------------------------------------------------------------------------------------
    //                                             processes
    // ------------------------------------------------------------------------------------------------------------

    always_comb begin : SignalMap
        cfg_slice_status.slice_overflow = i_slice_buffer_overflow;
    end : SignalMap

    // 用 valid 事务对齐 flatness 与 prediction，不依赖 group 间的固定空拍数。
    assign i_vlc_flat_flags_aligned = i_vlc_flat_flags_fifo[i_flat_flags_read_ptr];

    // flatness 的行尾 lookahead 会突发吐出尾部 group；预测/重建反馈环每个
    // group 需要四周期。这里保持事务顺序并恢复该边界节拍。
    assign i_fd_pop = (i_fd_count != 0) && (i_fd_cooldown == 0);

    always_ff @(posedge dsc_clk or negedge dsc_reset_n) begin : FlatnessOutputScheduler
        if (!dsc_reset_n) begin
            i_valid_fd <= 1'b0;
            i_last_fd <= 1'b0;
            i_group_fd <= '{default: kDSC_PIXEL_INIT};
            i_vlc_flat_flags_fd <= kDSC_FLAT_FLAGS_INIT;
            i_fd_write_ptr <= 4'd0;
            i_fd_read_ptr <= 4'd0;
            i_fd_count <= 5'd0;
            i_fd_cooldown <= 2'd0;
            i_fd_last_fifo <= '{default: 1'b0};
            i_fd_group_fifo <= '{default: '{default: kDSC_PIXEL_INIT}};
            i_fd_flags_fifo <= '{default: kDSC_FLAT_FLAGS_INIT};
        end else begin
            i_valid_fd <= 1'b0;
            i_last_fd <= 1'b0;

            if (i_fd_cooldown != 0)
                i_fd_cooldown <= i_fd_cooldown - 1'b1;

            if (i_valid_fd_raw) begin
                i_fd_last_fifo[i_fd_write_ptr] <= i_last_fd_raw;
                i_fd_group_fifo[i_fd_write_ptr] <= i_group_fd_raw;
                i_fd_flags_fifo[i_fd_write_ptr] <= i_vlc_flat_flags_fd_raw;
                i_fd_write_ptr <= i_fd_write_ptr + 1'b1;
            end

            if (i_fd_pop) begin
                i_valid_fd <= 1'b1;
                i_last_fd <= i_fd_last_fifo[i_fd_read_ptr];
                i_group_fd <= i_fd_group_fifo[i_fd_read_ptr];
                i_vlc_flat_flags_fd <= i_fd_flags_fifo[i_fd_read_ptr];
                i_fd_read_ptr <= i_fd_read_ptr + 1'b1;
                i_fd_cooldown <= 2'd3;
            end

            case ({i_valid_fd_raw, i_fd_pop})
                2'b10: i_fd_count <= i_fd_count + 1'b1;
                2'b01: i_fd_count <= i_fd_count - 1'b1;
                default: i_fd_count <= i_fd_count;
            endcase

            assert (!i_valid_fd_raw || i_fd_count < 5'd16)
                else $error("Flatness output scheduler overflow");
        end
    end

    always_ff @(posedge dsc_clk or negedge dsc_reset_n) begin : FlatnessTransactionFifo
        if (!dsc_reset_n) begin
            i_vlc_flat_flags_fifo <= '{default: kDSC_FLAT_FLAGS_INIT};
            i_flat_flags_write_ptr <= 3'd0;
            i_flat_flags_read_ptr <= 3'd0;
            i_flat_flags_count <= 4'd0;
        end else if (i_start_of_slice_slb) begin
            i_flat_flags_write_ptr <= 3'd0;
            i_flat_flags_read_ptr <= 3'd0;
            i_flat_flags_count <= 4'd0;
        end else begin
            if (i_valid_fd) begin
                i_vlc_flat_flags_fifo[i_flat_flags_write_ptr] <= i_vlc_flat_flags_fd;
                i_flat_flags_write_ptr <= i_flat_flags_write_ptr + 3'd1;
            end
            if (i_valid_pd)
                i_flat_flags_read_ptr <= i_flat_flags_read_ptr + 3'd1;

            case ({i_valid_fd, i_valid_pd})
                2'b10: i_flat_flags_count <= i_flat_flags_count + 4'd1;
                2'b01: i_flat_flags_count <= i_flat_flags_count - 4'd1;
                default: i_flat_flags_count <= i_flat_flags_count;
            endcase

            assert (!i_valid_fd || i_flat_flags_count < 4'd8)
                else $error("Flatness transaction FIFO overflow");
            assert (!i_valid_pd || i_flat_flags_count != 4'd0)
                else $error("Flatness transaction FIFO underflow");
        end
    end


    // ------------------------------------------------------------------------------------------------------------
    //                                             components
    // ------------------------------------------------------------------------------------------------------------

    // ---------------------------------------------
    //  color space conversion
    // ---------------------------------------------
    dsce_convert  dsce_convert_inst
    (
        // clock and control interface
        .axi_clk                    (axi_clk),
        .axi_reset_n                (axi_reset_n),
        .axi_update_pps             (axi_pps_update),
        .cfg_pps                    (cfg_pps),
        // input data path
        .axi_valid_in               (axi_valid_in),
        .axi_last_in                (axi_last_in),
        .axi_data_in                (axi_data_in),
        // output data path
        .axi_valid_out              (i_valid_csc),
        .axi_last_out               (i_last_csc),
        .axi_data_out               (i_data_csc)
    );


    // ---------------------------------------------
    //  slice processor buffer
    // ---------------------------------------------
    dsce_slice_buffer
    #(
        .pMAX_SLICE_LINE_SIZE       (pMAX_SLICE_LINE_SIZE)
    )  dsce_slice_buffer_inst
    (
        // clock and control interface
        .axi_clk                    (axi_clk),
        .axi_reset_n                (axi_reset_n),
        .axi_overflow               (i_slice_buffer_overflow),
        .cfg_ready_depth            (cfg_dsc_encoder.slice_buffer_depth),
        .cfg_pps                    (cfg_pps),
        // streaming input data path
        .axi_tvalid_in              (i_valid_csc),
        .axi_tready_in              (axi_ready_in),
        .axi_tlast_in               (i_last_csc),
        .axi_tdata_in               (i_data_csc),
        // internal data path for encoding
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .dsc_pps_update             (dsc_pps_update),
        // output path (not AXI4-S compliant)
        .dsc_start_of_slice         (i_start_of_slice_slb),
        .dsc_valid_out              (i_valid_slb),
        .dsc_last_out               (i_last_slb),
        .dsc_data_out               (i_group_slb),
        // memory BIST interface
        .bist_sram_in               (bist_sram_in[3]),
        .bist_sram_out              (bist_sram_out[3])
    );


    assign bist_sram_out[2] = 12'h000;


    // ---------------------------------------------
    //  flatness determination
    // ---------------------------------------------
    dsce_flatness  dsce_flatness_inst
    (
        // clock and control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .dsc_pps_update             (dsc_pps_update),
        .cfg_pps                    (cfg_pps),
        .cfg_rc_range_max_qp_14     (cfg_rcps.rc_range_parameters[14][9:5]),
        // quantization level
        .dsc_primary_qp             (i_primary_qp),
        // source pixel path
        .dsc_start_of_slice         (i_start_of_slice_slb),
        .dsc_source_valid_in        (i_valid_slb),
        .dsc_source_last_in         (i_last_slb),
        .dsc_source_group_in        (i_group_slb),
        // output data path
        .dsc_group_valid_out        (i_valid_fd_raw),
        .dsc_group_last_out         (i_last_fd_raw),
        .dsc_group_out              (i_group_fd_raw),
        .dsc_vlc_flat_flags_out     (i_vlc_flat_flags_fd_raw),
        .dsc_ich_next_is_very_flat  (i_ich_next_is_very_flat)
    );


    // ---------------------------------------------
    //  prediction block
    // ---------------------------------------------
    dsce_predict
    #(
        .pINCLUDE_BLOCK_PREDICTION  (pINCLUDE_BLOCK_PREDICTION)
    )  dsce_predict_inst
    (
        // clock and control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .cfg_dsc_encoder            (cfg_dsc_encoder),
        .dsc_pps_update             (dsc_pps_update),
        .cfg_pps                    (cfg_pps),
        // input data path
        .dsc_start_of_slice         (i_start_of_slice_slb),
        .dsc_group_valid_in         (i_valid_fd),
        .dsc_group_last_in          (i_last_fd),
        .dsc_group_in               (i_group_fd),
        .dsc_right_in               (i_right_pixel_dec),
        .dsc_recon_group_in         (i_recon_dec),
        // entropy feedback and rate control
        .dsc_line_prev_in           (i_prev_line_mmap),
        .dsc_qlevel_y               (i_qlevel_y),
        .dsc_qlevel_c               (i_qlevel_c),
        // residual output
        .dsc_group_valid_out        (i_valid_pd),
        .dsc_last_out               (i_last_pd),
        .dsc_use_bp_out             (i_use_bp_pd),
        .dsc_predict_bp_out         (i_predict_bp),
        .dsc_predict_mmap_out       (i_predict_mmap),
        .dsc_predict_mpp_out        (i_predict_mpp),
        .dsc_residual_bp_out        (i_residual_bp),
        .dsc_residual_mmap_out      (i_residual_mmap),
        .dsc_residual_mpp_out       (i_residual_mpp)
    );


    // ---------------------------------------------
    //  indexed color history table
    // ---------------------------------------------
`ifdef DSC_ICH_MODEL_SUBSTITUTE
    dsce_ich_function_model dsce_ich_inst
`else
    dsce_ich dsce_ich_inst
`endif
    (
        // clock and control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .cfg_dsc_encoder            (cfg_dsc_encoder),
        .cfg_pps                    (cfg_pps),
        .dsc_pps_update             (dsc_pps_update),
        // control signal and previous line input
        .dsc_start_of_slice         (i_start_of_slice_slb),
        .dsc_start_of_slice_line    (1'b0),
        .dsc_line_prev_in           (i_prev_line_ich),
        // original pixel data path
        .dsc_group_valid_in         (i_valid_fd),
        .dsc_group_last_in          (i_last_fd),
        .dsc_group_in               (i_group_fd),
        .dsc_primary_qp             (i_primary_qp),
        .dsc_qlevel_y_in            (i_qlevel_y),
        .dsc_qlevel_c_in            (i_qlevel_c),
        .dsc_force_mpp_in           (i_force_mpp),
        // ICH 的严格代价判据必须使用与预测/VLC 同一事务的 flatness 标志。
        // 独立 ICH flatness 流水在气泡周期会与 i_valid_pd 脱节。
        // 行末强制 VERY_FLAT 只用于码控的 flat QP，C model 的 IchDecision 对行末组
        // 因 IsOrigFlatHIndex 的 hPos+1>=sliceWidth 提前返回非 flat，故同样排除。
        .dsc_ich_next_is_very_flat  ((i_vlc_flat_flags_aligned.group_flatness_type == kDSC_VERY_FLAT) && !i_last_pd),
        .dsc_vlc_size_in            (i_vlc_size_dec),
        // predict pixel input
        .dsc_predict_valid_in       (i_valid_pd),
        .dsc_predict_last_in        (i_last_pd),
        .dsc_predict_in             (i_predict_dec),
        .dsc_quant_residual_in      (i_residual_dec),
        .dsc_residual_size_in       (i_residual_size_dec),
        .dsc_qlevel_y_res           (i_qlevel_y_res),
        .dsc_qlevel_c_res           (i_qlevel_c_res),
        // ich lookup output
        .dsc_ich_valid_out          (),
        .dsc_ich_select_out         (i_ich_selected),
        .dsc_ich_index_out          (i_index_ich),
        .dsc_ich_group_out          (i_ich_group)
    );


    // ---------------------------------------------
    //  prediction decisions, ICH decisions
    // ---------------------------------------------
    dsce_decision  dsce_decision_inst
    (
        // clock and control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .cfg_dsc_encoder            (cfg_dsc_encoder),
        .dsc_pps_update             (dsc_pps_update),
        .cfg_pps                    (cfg_pps),
        // control inputs
        .dsc_valid_in               (i_valid_pd),
        .dsc_last_in                (i_last_pd),
        .dsc_qlevel_y_res_in        (i_qlevel_y_res),
        .dsc_qlevel_c_res_in        (i_qlevel_c_res),
        .dsc_force_mpp_in           (i_force_mpp),
        // predicted / ICH path in
        .dsc_use_bp_in              (i_use_bp_pd),
        .dsc_bp_predict_in          (i_predict_bp),
        .dsc_mmap_predict_in        (i_predict_mmap),
        .dsc_mpp_predict_in         (i_predict_mpp),
        .dsc_bp_residual_in         (i_residual_bp),
        .dsc_mmap_residual_in       (i_residual_mmap),
        .dsc_mpp_residual_in        (i_residual_mpp),
        .dsc_ich_selected_in        (i_ich_selected),
        .dsc_ich_group_in           (i_ich_group),
        // residual decisions
        .dsc_ich_selected_out       (i_ich_selected_dec),
        .dsc_mpp_out                (i_mpp_dec),
        .dsc_predict_out            (i_predict_dec),
        .dsc_quant_residual_out     (i_residual_dec),
        .dsc_recon_group_out        (i_recon_dec),
        .dsc_right_pixel_out        (i_right_pixel_dec),
        // VLC parameters
        .dsc_residual_size_out      (i_residual_size_dec),
        .dsc_vlc_size_out           (i_vlc_size_dec)
    );


    // ---------------------------------------------
    //  line buffer
    // ---------------------------------------------
    dsce_linemem
    #(
        .pMAX_SLICE_LINE_SIZE       (pMAX_SLICE_LINE_SIZE)
    )  dsce_linemem_inst
    (
        // clock and control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .dsc_pps_update             (dsc_pps_update),
        .cfg_pps                    (cfg_pps),
        .dsc_start_of_slice         (i_start_of_slice_slb),
        // line write interface
        .dsc_recon_valid_in         (i_valid_pd),
        .dsc_recon_last_in          (i_last_pd),
        .dsc_recon_in               (i_recon_dec),
        // previous line read interface
        .dsc_input_valid_in         (i_valid_fd),
        .dsc_input_last_in          (i_last_fd),
        .dsc_mmap_pixels_out        (i_prev_line_mmap),
        .dsc_ich_pixels_out         (i_prev_line_ich),
        // memory BIST interface
        .bist_sram_in               (bist_sram_in[0]),
        .bist_sram_out              (bist_sram_out[0])
    );


    // ---------------------------------------------
    //  rate control adjustments
    // ---------------------------------------------
    dsce_rate_adjust  dsce_rate_adjust_inst
    (
        // processing clock domain
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .dsc_pps_update             (dsc_pps_update),
        .cfg_pps                    (cfg_pps),
        .cfg_rc_range_max_qp_14     (cfg_rcps.rc_range_parameters[14][10:6]),
        // group input path
        .dsc_start_of_slice         (i_start_of_slice_slb),
        .dsc_group_valid_in         (i_valid_fd),
        .dsc_group_last_in          (i_last_fd),
        // rate control qp input
        .dsc_rc_primary_qp_in       (i_rc_primary_qp),
        .dsc_rc_qp_valid_in         (i_valid_rc_next),
        .dsc_rc_primary_qp_next_in  (i_rc_primary_qp_next),
        .dsc_rc_primary_qp_prev_in  (i_rc_primary_qp_prev),
        .dsc_rc_prev_qp_in          (i_rc_prev_qp),
        // rate control modified qp out
        .dsc_primary_qp_out         (i_primary_qp),
        .dsc_prev_qp_out            (i_prev_qp)
    );


    // ---------------------------------------------
    //  rate control
    // ---------------------------------------------
    dsce_rate  dsce_rate_inst
    (
        // clock and control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .cfg_dsc_encoder            (cfg_dsc_encoder),
        .dsc_pps_update             (dsc_pps_update),
        .cfg_pps                    (cfg_pps),
        .cfg_rcps                   (cfg_rcps),
        // input data path
        .dsc_start_of_slice         (i_start_of_slice_slb),
        .dsc_group_valid_in         (i_valid_pd),
        .dsc_last_in                (i_last_pd),
        .dsc_coded_group_size       (i_coded_group_size),
        .dsc_rc_size_group          (i_rc_size_group),
        .dsc_flat_qp_in             (i_primary_qp),
        .dsc_flat_prev_qp_in        (i_prev_qp),
        .dsc_use_mpp                (i_mpp_dec),
        .dsc_ich_selected           (i_ich_selected_dec),
        .dsc_vlc_size               (i_vlc_size_dec),
        // DSC 1.2 的行末强制 QP 调整发生在 RateControl 之后，不应清除
        // 当前行已建立的 bit-save 状态。
        .dsc_flatness_flag          ((i_vlc_flat_flags_aligned.group_flatness_type != 2'd0) && !i_last_pd),
        // primary quant level
        .dsc_qp_valid_out           (i_valid_rc),
        .dsc_qp_valid_next          (i_valid_rc_next),
        .dsc_primary_qp             (i_rc_primary_qp),
        .dsc_primary_qp_prev        (i_rc_primary_qp_prev),
        .dsc_primary_qp_next        (i_rc_primary_qp_next),
        .dsc_prev_qp                (i_rc_prev_qp),
        .dsc_force_mpp              (i_force_mpp)
    );


    // ---------------------------------------------
    //  quantization level mapping
    // ---------------------------------------------
    dsce_qlevel  dsce_qlevel_inst
    (
        // clock and control interface
        .apb_clk                    (apb_clk),
        .apb_reset_n                (apb_reset_n),
        .cfg_bits_per_component     (cfg_pps.bits_per_component),
        .cfg_convert_rgb            (cfg_pps.convert_rgb),
        .cfg_dsc_version_minor      (cfg_pps.dsc_version_minor),
        // lookup path
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .dsc_pps_update             (dsc_pps_update),
        .dsc_qp_valid_in            (i_valid_fd),
        .dsc_primary_qp             (i_primary_qp),
        .dsc_primary_qp_res         (i_primary_qp_res),
        .dsc_qlevel_y               (i_qlevel_y),
        .dsc_qlevel_c               (i_qlevel_c),
        .dsc_qlevel_y_res           (i_qlevel_y_res),
        .dsc_qlevel_c_res           (i_qlevel_c_res)
    );


    // ---------------------------------------------
    //  output formatting
    // ---------------------------------------------
    dsce_format
    #(
        .pDEBUG_MESSAGES            (pDEBUG_MESSAGES)
    )  dsce_format_inst
    (
        // clock and control interface
        .dsc_clk                    (dsc_clk),
        .dsc_reset_n                (dsc_reset_n),
        .cfg_dsc_encoder            (cfg_dsc_encoder),
        .dsc_pps_update             (dsc_pps_update),
        .cfg_pps                    (cfg_pps),
        .cfg_rcps                   (cfg_rcps),
        // prediction residuals
        .dsc_start_of_slice         (i_start_of_slice_slb),
        .dsc_predict_valid_in       (i_valid_pd),
        .dsc_predict_last_in        (i_last_pd),
        .dsc_primary_qp_in          (i_primary_qp_res),
        .dsc_qlevel_y_in            (i_qlevel_y_res),
        .dsc_qlevel_c_in            (i_qlevel_c_res),
        .dsc_flatness_in            (i_vlc_flat_flags_aligned),
        // residual input
        .dsc_ich_selected_in        (i_ich_selected_dec),
        .dsc_ich_index_in           (i_index_ich),
        .dsc_residual_in            (i_residual_dec),
        .dsc_residual_size_in       (i_residual_size_dec),
        .dsc_vlc_size_in            (i_vlc_size_dec),
        // rate control outputs
        .dsc_coded_group_size       (i_coded_group_size),
        .dsc_rc_size_group          (i_rc_size_group),
        // output to the slice mux
        .axi_clk                    (axi_clk),
        .axi_reset_n                (axi_reset_n),
        .axi_last_out               (axi_last_out),
        .axi_tvalid_out             (axi_tvalid_out),
        .axi_tready_out             (axi_tready_out),
        .axi_muxword_out            (axi_muxword_out),
        // memory BIST interface
        .bist_sram_in               (bist_sram_in[1]),
        .bist_sram_out              (bist_sram_out[1])
    );

endmodule : dsce_slice
