// ------------------------------------------------------------------------------------------------
//  COPYRIGHT © 2015-2023, TRILINEAR TECHNOLOGIES, INC.
//
//  THE SOURCE CODE CONTAINED HEREIN IS PROVIDED ON AN "AS IS" BASIS.
//  TRILINEAR TECHNOLOGIES, INC. DISCLAIMS ANY AND ALL WARRANTIES,
//  WHETHER EXPRESS, IMPLIED, OR STATUTORY, INCLUDING ANY IMPLIED
//  WARRANTIES OF MERCHANTABILITY OR OF FITNESS FOR A PARTICULAR PURPOSE.
//  IN NO EVENT SHALL TRILINEAR TECHNOLOGIES, INC. BE LIABLE FOR ANY
//  INCIDENTAL, PUNITIVE, OR CONSEQUENTIAL DAMAGES OF ANY KIND WHATSOEVER
//  ARISING FROM THE USE OF THIS SOURCE CODE.
//
//  THIS DISCLAIMER OF WARRANTY EXTENDS TO THE USER OF THIS SOURCE CODE
//  AND USER'S CUSTOMERS, EMPLOYEES, AGENTS, TRANSFEREES, SUCCESSORS,
//  AND ASSIGNS.
//
//  THIS IS NOT A GRANT OF PATENT RIGHTS
// ------------------------------------------------------------------------------------------------
//  DESCRIPTION : Package file for the Display Stream Compression encoder.
// ------------------------------------------------------------------------------------------------

package dsce_defs_pkg;

    // ------------------------------------------------------------------------------------------------------------------
    //  global constants
    // ------------------------------------------------------------------------------------------------------------------

    // encoder commands
    typedef enum logic [3:0] {
        eENCODER_COMMAND_OFF       = 4'd0,
        eENCODER_COMMAND_RESET     = 4'd1,
        eENCODER_COMMAND_RESET_ALL = 4'd2,
        eENCODER_COMMAND_FRAME     = 4'd3,
        eENCODER_COMMAND_RUN       = 4'd4
    } tDSCE_ENCODER_COMMAND;

    // bits per component index field
    localparam int   kBPC_Y = 0;
    localparam int   kBPC_C = 1;
    localparam logic kBPC_Y_FLAG = 1'b0;
    localparam logic kBPC_C_FLAG = 1'b1;

    // useful constants when working with parameterized logic
    localparam logic [31:0] kDSCE_ZERO  = 32'd0;
    localparam logic [31:0] kDSCE_ONE   = 32'd1;
    localparam logic [31:0] kDSCE_MAX_VALUE  = 32'hffff_ffff;

    // ------------------------------------------------------------------------------------------------------------------
    //  internal register set
    // ------------------------------------------------------------------------------------------------------------------

    typedef struct packed {
        logic                   follow_vsync;
        tDSCE_ENCODER_COMMAND   encode_command;
        logic                   encode_command_update;
        logic [7:0]             timeout_count;
        logic [2:0]             pixels_per_cycle;
        logic [2:0]             slice_width_alignment;
        logic                   force_enable;
        logic                   qp_override_enable;
        logic [4:0]             qp_override;
        logic [4:0]             slices_per_line;
        logic [7:0]             slices_per_processor;
        logic [3:0]             slice_processor_count;
        logic [9:0]             clock_divider;
        logic [2:0]             output_mode;
        logic [7:0]             max_bits_per_group;
        logic                   chunk_trailing_bits_flag;
        logic [11:0]            chunk_size;
        logic [13:0]            slice_buffer_depth;
    } tDSCE_CONFIG;


    localparam tDSCE_CONFIG kDSCE_CONFIG_INIT = '{
        follow_vsync                : 1'b0,
        encode_command              : eENCODER_COMMAND_OFF,
        encode_command_update       : 1'b0,
        timeout_count               : 8'd0,
        pixels_per_cycle            : 3'd4,
        slice_width_alignment       : 3'h0,
        force_enable                : 1'b0,
        qp_override_enable          : 1'b0,
        qp_override                 : 5'd0,
        slices_per_line             : 5'd0,
        slices_per_processor        : 7'd0,
        slice_processor_count       : 4'd0,
        clock_divider               : 10'd0,
        output_mode                 : 3'd7,
        max_bits_per_group          : 8'd0,
        chunk_trailing_bits_flag    : 1'b0,
        chunk_size                  : 12'd0,
        slice_buffer_depth          : 14'd0
    };

    // encoder status
    typedef struct packed {
        logic           encoder_active;
        logic           end_of_frame;
        logic           encoder_timeout;
        logic           rate_error;
    } tDSCE_CONTROL_STATUS;

    // slice processing status
    typedef struct packed {
        logic           slice_overflow;
    } tDSCE_SLICE_STATUS;

    // interrupt controller
    typedef struct packed {
        logic [6:0]     enable;
        logic           clear;
        logic [7:0]     int_frame_count;
        logic           clear_frame_count;
    } tDSCE_INTERRUPT_CONFIG;

    localparam tDSCE_INTERRUPT_CONFIG kDSCE_INTERRUPT_CONFIG_INIT = '{
        enable            : 7'h00,
        clear             : 1'b0,
        int_frame_count   : 8'h00,
        clear_frame_count : 1'b0
    };

    typedef struct packed {
        logic [7:0]     encoded_frame_count;
        logic [6:0]     cause;
        logic [6:0]     state;
    } tDSCE_INTERRUPT_STATUS;

    //  internal timer
    typedef struct packed {
        logic           autoreload;
        logic [23:0]    reload_value;
        logic           timer_enable;
        logic           interrupt_enable;
    } tDSCE_TIMERS_CONFIG;

    localparam tDSCE_TIMERS_CONFIG kDSCE_TIMERS_CONFIG_INIT = '{
        autoreload          : 1'b0,
        reload_value        : 24'd0,
        timer_enable        : 1'b0,
        interrupt_enable    : 1'b0
    };

    typedef struct packed {
        logic           timer_interrupt;
        logic [23:0]    timer_value;
    } tDSCE_TIMERS_STATUS;

    localparam tDSCE_TIMERS_STATUS kDSCE_TIMERS_STATUS_INIT = '{
        timer_interrupt     : 1'b0,
        timer_value         : 24'h000000
    };


    // ------------------------------------------------------------------------------------------------------------------
    //  picture parameter set and related sub-fields
    // ------------------------------------------------------------------------------------------------------------------

    // picture_parameter_set
    typedef struct packed {
        logic [3:0]             dsc_version_major;
        logic [3:0]             dsc_version_minor;
        logic [7:0]             pps_identifier;
        logic [3:0]             bits_per_component;
        logic [3:0]             linebuf_depth;
        logic                   block_pred_enable;
        logic                   convert_rgb;
        logic                   simple_422;
        logic                   vbr_enable;
        logic [9:0]             bits_per_pixel;
        logic [15:0]            pic_height;
        logic [15:0]            pic_width;
        logic [15:0]            slice_height;
        logic [15:0]            slice_width;
        logic [15:0]            chunk_size;
        logic [9:0]             initial_xmit_delay;
        logic [15:0]            initial_dec_delay;
        logic [5:0]             initial_scale_value;
        logic [15:0]            scale_increment_interval;
        logic [11:0]            scale_decrement_interval;
        logic [4:0]             first_line_bpg_offset;
        logic [15:0]            nfl_bpg_offset;
        logic [15:0]            slice_bpg_offset;
        logic [15:0]            initial_offset;
        logic [15:0]            final_offset;
        logic [4:0]             flatness_min_qp;
        logic [4:0]             flatness_max_qp;
        logic                   native_420;
        logic                   native_422;
        logic [4:0]             second_line_bpg_offset;
        logic [15:0]            nsl_bpg_offset;
        logic [15:0]            second_line_offset_adj;
    } tDSC_PPS;

    localparam tDSC_PPS kDSC_PPS_INIT = '{
        dsc_version_major        : 4'd0,
        dsc_version_minor        : 4'd0,
        pps_identifier           : 8'h00,
        bits_per_component       : 4'd0,
        linebuf_depth            : 4'd0,
        block_pred_enable        : 1'b0,
        convert_rgb              : 1'b0,
        simple_422               : 1'b0,
        vbr_enable               : 1'b0,
        bits_per_pixel           : 10'd0,
        pic_height               : 16'h0000,
        pic_width                : 16'h0000,
        slice_height             : 16'h0000,
        slice_width              : 16'h0000,
        chunk_size               : 16'h0000,
        initial_xmit_delay       : 10'd0,
        initial_dec_delay        : 16'h0000,
        initial_scale_value      : 6'd0,
        scale_increment_interval : 16'h0000,
        scale_decrement_interval : 12'h000,
        first_line_bpg_offset    : 5'd0,
        nfl_bpg_offset           : 16'h0000,
        slice_bpg_offset         : 16'h0000,
        initial_offset           : 16'h0000,
        final_offset             : 16'h0000,
        flatness_min_qp          : 5'd0,
        flatness_max_qp          : 5'd0,
        native_420               : 1'b0,
        native_422               : 1'b0,
        second_line_bpg_offset   : 5'd0,
        nsl_bpg_offset           : 16'h0000,
        second_line_offset_adj   : 16'h0000
    };

    // rc_parameter_set field
    typedef struct packed {
        logic [14:0] [15:0] rc_range_parameters;
        logic [13:0] [7:0]  rc_buf_thresh;
        logic [3:0]         rc_tgt_offset_hi;
        logic [3:0]         rc_tgt_offset_lo;
        logic [2:0]         rc_reserved_2;
        logic [4:0]         rc_quant_incr_limit1;
        logic [2:0]         rc_reserved_1;
        logic [4:0]         rc_quant_incr_limit0;
        logic [3:0]         rc_reserved_0;
        logic [3:0]         rc_edge_factor;
        logic [15:0]        rc_model_size;
    } tDSC_RCPS;

    localparam tDSC_RCPS kDSC_RCPS_INIT = '{
        rc_model_size        : 16'h0000,
        rc_edge_factor       : 4'd0,
        rc_reserved_0        : 4'h0,
        rc_quant_incr_limit0 : 5'd0,
        rc_reserved_1        : 3'h0,
        rc_quant_incr_limit1 : 5'd0,
        rc_reserved_2        : 3'h0,
        rc_tgt_offset_hi     : 4'd0,
        rc_tgt_offset_lo     : 4'd0,
        rc_buf_thresh        : '{default: 8'h00},
        rc_range_parameters  : '{default: 16'h0000}
    };

    typedef struct packed {
        logic [5:0]     range_bpg_offset;
        logic [4:0]     range_max_qp;
        logic [4:0]     range_min_qp;
    } tDSC_RC_RANGE_PARAMETERS;

    // color space conversion parameters
    typedef struct packed {
        logic           convert_rgb;
        logic [3:0]     bits_per_component;
        logic           native_420;
        logic           native_422;
        logic           simple_422;
    } tDSC_CSC_PARAMETERS;

    // ------------------------------------------------------------------------------------------------------------------
    //  internal data structures
    // ------------------------------------------------------------------------------------------------------------------

    // pixel data types
    typedef struct packed {
        logic [15:0]    r;
        logic [15:0]    g;
        logic [15:0]    b;
    } tSTD_PIXEL;

    localparam tSTD_PIXEL kSTD_PIXEL_INIT = '{
        r : 16'h0000,
        g : 16'h0000,
        b : 16'h0000
    };

    // one component of the pixel
    typedef logic [15:0] tDSC_COMPONENT;
    localparam tDSC_COMPONENT kDSC_COMPONENT_INIT = 16'h0000;

    typedef struct packed {
        tDSC_COMPONENT  y;
        tDSC_COMPONENT  co;
        tDSC_COMPONENT  cg;
    } tDSC_PIXEL;

    localparam tDSC_PIXEL kDSC_PIXEL_INIT = '{
        y  : kDSC_COMPONENT_INIT,
        co : kDSC_COMPONENT_INIT,
        cg : kDSC_COMPONENT_INIT
    };

    // one component of the residual
    typedef logic signed [16:0] tDSC_RESIDUAL;
    localparam tDSC_RESIDUAL kDSC_RESIDUAL_INIT = 17'sd0;
    localparam tDSC_RESIDUAL kDSC_RESIDUAL_ZERO = 17'sd0;

    // residual values
    typedef struct packed {
        tDSC_RESIDUAL res_y;
        tDSC_RESIDUAL res_co;
        tDSC_RESIDUAL res_cg;
    } tDSC_RESIDUAL_PIXEL;

    localparam tDSC_RESIDUAL_PIXEL kDSC_RESIDUAL_PIXEL_INIT = '{
        res_y  : kDSC_RESIDUAL_INIT,
        res_co : kDSC_RESIDUAL_INIT,
        res_cg : kDSC_RESIDUAL_INIT
    };

    // ICH table index values
    typedef logic [4:0] tDSC_ICH_INDEX;
    localparam tDSC_ICH_INDEX kDSC_ICH_INDEX_INIT = 5'h00;

    typedef enum {
        kDSC_COLOR_DEFAULT,
        kDSC_COLOR_422,
        kDSC_COLOR_420
    } tDSC_COLOR_MODE;

    // ----------------------------------------------
    //  quantization level
    // ----------------------------------------------
    typedef logic [4:0] tDSC_QLEVEL;
    localparam tDSC_QLEVEL kDSC_QLEVEL_ZERO = 5'h00;
    localparam tDSC_QLEVEL kDSC_SOMEWHAT_FLAT_QP_DELTA = 5'h04;

    // ----------------------------------------------
    //  flatness flags and codes
    // ----------------------------------------------
    typedef struct packed {
        // for VLC bitstream coding
        logic           next_flatness_flag;
        logic           send_flatness;
        logic   [1:0]   first_flat;
        logic           flatness_type;
        // for rate control
        logic   [1:0]   group_flatness_type;
        // for ICH
        logic           next_is_very_flat;
    } tDSC_FLAT_FLAGS;

    localparam tDSC_FLAT_FLAGS kDSC_FLAT_FLAGS_INIT = '{
        next_flatness_flag  : 1'b0,
        send_flatness       : 1'b0,
        first_flat          : 2'd0,
        flatness_type       : 1'b0,
        group_flatness_type : 2'b00,
        next_is_very_flat   : 1'b0
    };

    // group flatness type
    localparam kDSC_NOT_FLAT      = 2'b00;
    localparam kDSC_SOMEWHAT_FLAT = 2'b10;
    localparam kDSC_VERY_FLAT     = 2'b11;

    // ------------------------------------------------------------------------------------------------------------------
    //  common functions
    // ------------------------------------------------------------------------------------------------------------------

    // ----------------------------------------------
    //  perform a twos comp on the residual
    // ----------------------------------------------
    function automatic logic [16:0] dsce_twos_comp_residual (
        input tDSC_RESIDUAL val
    );
        dsce_twos_comp_residual = (~val) + 17'sd1;
    endfunction : dsce_twos_comp_residual


    // ----------------------------------------------
    //  calculate the absolute component difference
    // ----------------------------------------------
    function automatic logic [15:0] dsce_abs_diff (
        input [15:0] cpnt_a,
        input [15:0] cpnt_b
    );
        logic signed [16:0] signed_diff;
        logic        [15:0] abs_diff;

        signed_diff = $signed({1'b0, cpnt_a}) - $signed({1'b0, cpnt_b});
        abs_diff = (signed_diff[16] == 1'b1) ? (~signed_diff[15:0] + 16'd1) : signed_diff[15:0];

        return(abs_diff);
    endfunction : dsce_abs_diff


    // ----------------------------------------------
    //  calculate the absolute difference of two
    //  pixels using each component
    // ----------------------------------------------
    function automatic tDSC_PIXEL dsce_abs_diff_pixel (
        input tDSC_PIXEL pixel_a,
        input tDSC_PIXEL pixel_b
    );
        tDSC_PIXEL diff_pixel;

        diff_pixel.y  = dsce_abs_diff(pixel_a.y, pixel_b.y);
        diff_pixel.co = dsce_abs_diff(pixel_a.co, pixel_b.co);
        diff_pixel.cg = dsce_abs_diff(pixel_a.cg, pixel_b.cg);

        return(diff_pixel);
    endfunction : dsce_abs_diff_pixel


    // ----------------------------------------------
    //  compute the weighted SAD from the pixel diff
    // ----------------------------------------------
    function automatic logic [16:0] dsce_weighted_sad_from_diff (
        input tDSC_PIXEL diff_pixel
    );
        logic [16:0] weighted_sad;

        weighted_sad = {1'b0, diff_pixel.y, 1'b0} +         // lumaWeight * Y_diff +
                       {2'b00, diff_pixel.co} +             // Co_diff +
                       {2'b00, diff_pixel.cg};              // Cg_diff

        return(weighted_sad);
    endfunction : dsce_weighted_sad_from_diff


    // ----------------------------------------------
    //  determine when to select the MPP sample
    // ----------------------------------------------
    function automatic logic dsce_mpp_select (
        input tDSC_RESIDUAL residual,
        input logic [4:0]   bitdepth,
        input tDSC_QLEVEL   qlevel
    );
        tDSC_RESIDUAL         i_qlevel_round;
        tDSC_RESIDUAL         i_residual_round;
        logic                 i_mpp_select;

        // create a comparison mask (base 16, +1 for sign bit, +1 for >= comparison)
        // qlevel is unused to model the comparison to the quantized values

        case (qlevel)
            5'd2:    i_qlevel_round = 17'sh00001;
            5'd3:    i_qlevel_round = 17'sh00003;
            5'd4:    i_qlevel_round = 17'sh00007;
            5'd5:    i_qlevel_round = 17'sh0000f;
            5'd6:    i_qlevel_round = 17'sh0001f;
            5'd7:    i_qlevel_round = 17'sh0003f;
            5'd8:    i_qlevel_round = 17'sh0007f;
            5'd9:    i_qlevel_round = 17'sh000ff;
            5'd10:   i_qlevel_round = 17'sh001ff;
            5'd11:   i_qlevel_round = 17'sh003ff;
            5'd12:   i_qlevel_round = 17'sh007ff;
            default: i_qlevel_round = 17'sh00000;
        endcase

        if (residual[16] == 1'b1) begin
            i_residual_round = -((i_qlevel_round - residual) >> qlevel);
        end else begin
            i_residual_round = (residual + i_qlevel_round) >> qlevel;
        end // if

        i_mpp_select = ({1'b0, dsce_residual_size(i_residual_round)} >= (bitdepth-qlevel)) ? 1'b1 : 1'b0;

        return (i_mpp_select);
    endfunction : dsce_mpp_select


    // ----------------------------------------------
    //  compute the residual between the predicted
    //  sample and the actual sample
    // ----------------------------------------------
    function automatic tDSC_RESIDUAL dsce_compute_residual (
        input logic [15:0] predict,
        input logic [15:0] orig_sample
    );
        dsce_compute_residual = $signed({1'b0, orig_sample}) - $signed({1'b0, predict});
    endfunction : dsce_compute_residual


    // ----------------------------------------------
    //  QP to qLevel map
    // ----------------------------------------------
    function automatic tDSC_QLEVEL dsce_qp_to_qlevel (
        input logic       y_or_c,
        input logic [3:0] bits_per_component,
        input tDSC_QLEVEL primaryQP
    );
        tDSC_QLEVEL mapped_qlevel;

        case (primaryQP)
            5'd0    :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd0  : 5'd0;
            5'd1    :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd0  : 5'd1;
            5'd2    :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd0  : 5'd2;
            5'd3    :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd1  : 5'd2;
            5'd4    :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd1  : 5'd3;
            5'd5    :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd2  : 5'd3;
            5'd6    :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd2  : 5'd4;
            5'd7    :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd3  : 5'd4;
            5'd8    :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd3  : 5'd5;
            5'd9    :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd4  : 5'd5;
            5'd10   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd4  : 5'd6;
            5'd11   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd5  : 5'd6;
            5'd12   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd5  : 5'd7;
            5'd13   :   mapped_qlevel = (bits_per_component == 4'd8) ? (y_or_c == kBPC_Y_FLAG) ? 5'd5 : 5'd8 : (y_or_c == kBPC_Y_FLAG) ? 5'd6 : 5'd7;
            5'd14   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd6  : 5'd8;
            5'd15   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd7  : 5'd8;
            5'd16   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd7  : 5'd9;
            5'd17   :   mapped_qlevel = (bits_per_component == 4'd10) ? (y_or_c == kBPC_Y_FLAG) ? 5'd7 : 5'd10 : (y_or_c == kBPC_Y_FLAG) ? 5'd8 : 5'd9;
            5'd18   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd8  : 5'd10;
            5'd19   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd9  : 5'd10;
            5'd20   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd9  : 5'd11;
            5'd21   :   mapped_qlevel = (bits_per_component == 4'd12) ? (y_or_c == kBPC_Y_FLAG) ? 5'd9 : 5'd12 : (y_or_c == kBPC_Y_FLAG) ? 5'd10 : 5'd11;
            5'd22   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd10 : 5'd12;
            5'd23   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd11 : 5'd12;
            5'd24   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd11 : 5'd13;
            5'd25   :   mapped_qlevel = (bits_per_component == 4'd14) ? (y_or_c == kBPC_Y_FLAG) ? 5'd11 : 5'd14 : (y_or_c == kBPC_Y_FLAG) ? 5'd12 : 5'd13;
            5'd26   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd12 : 5'd14;
            5'd27   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd13 : 5'd14;
            5'd28   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd13 : 5'd15;
            5'd29   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd13 : 5'd16;
            5'd30   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd14 : 5'd16;
            5'd31   :   mapped_qlevel = (y_or_c == kBPC_Y_FLAG) ? 5'd15 : 5'd16;
            default :   mapped_qlevel = 5'd0;
        endcase

        return (mapped_qlevel);
    endfunction : dsce_qp_to_qlevel


    // ----------------------------------------------
    //  map the qlevel value to the quant divisor
    // ----------------------------------------------
    function automatic logic [15:0] dsce_quant_divisor (
        input tDSC_QLEVEL qlevel
    );
        dsce_quant_divisor = 16'h0001 << qlevel;
    endfunction : dsce_quant_divisor


    // ----------------------------------------------
    //  determine the size of the residual
    // ----------------------------------------------
    function automatic logic [3:0] dsce_residual_size (
        input tDSC_RESIDUAL res_in
    );
        logic [15:0] res;

        res = (res_in[16] == 1'b1) ? ~res_in[15:0] : res_in[15:0];

        // binary decision tree
        if (res[15:8] == 8'h00) begin
            if (res[7:4] == 4'h0) begin
                case (res[3:0])
                    4'h0:                    dsce_residual_size = {3'b000, res_in[16]};
                    4'h1:                    dsce_residual_size = 4'd2;
                    4'h2, 4'h3:              dsce_residual_size = 4'd3;
                    4'h4, 4'h5, 4'h6, 4'h7:  dsce_residual_size = 4'd4;
                    default:                 dsce_residual_size = 4'd5;
                endcase
            end else begin
                case (res[7:4])
                    4'h1:                    dsce_residual_size = 4'd6;
                    4'h2, 4'h3:              dsce_residual_size = 4'd7;
                    4'h4, 4'h5, 4'h6, 4'h7:  dsce_residual_size = 4'd8;
                    default:                 dsce_residual_size = 4'd9;
                endcase
            end // if
        end else begin
            if (res[15:12] == 4'h0) begin
                case (res[11:8])
                    4'h1:                    dsce_residual_size = 4'd10;
                    4'h2, 4'h3:              dsce_residual_size = 4'd11;
                    4'h4, 4'h5, 4'h6, 4'h7:  dsce_residual_size = 4'd12;
                    default:                 dsce_residual_size = 4'd13;
                endcase
            end else begin
                case (res[15:12])
                    4'h1:                    dsce_residual_size = 4'd14;
                    4'h2, 4'h3:              dsce_residual_size = 4'd15;
                    4'h4, 4'h5, 4'h6, 4'h7:  dsce_residual_size = 4'd15;
                    default:                 dsce_residual_size = 4'd15;
                endcase
            end // if
        end // if
    endfunction : dsce_residual_size


    // ----------------------------------------------
    //  quantization - with range checking
    // ----------------------------------------------
    function automatic tDSC_RESIDUAL dsce_quantization_with_range_check (
        input tDSC_RESIDUAL res,
        input tDSC_QLEVEL   qlevel,
        input logic [4:0]   max_residual_size
    );
        tDSC_RESIDUAL round;
        tDSC_RESIDUAL quantized_residual;
        tDSC_RESIDUAL final_residual;
        tDSC_RESIDUAL residual_mask;

        // extra residual size bit for the sign bit
        residual_mask = 17'sh1ffff << (max_residual_size-1);

        round = 17'h07fff >> (5'd16 - qlevel);
        quantized_residual = (res[16] == 1'b0) ? $signed(res + round) >>> qlevel : - ($signed(round - res) >> qlevel);

        if (quantized_residual[16] == 1'b0) begin
            if ((quantized_residual & residual_mask) != 17'sd0) begin
                final_residual = ~residual_mask;
            end else begin
                final_residual = quantized_residual;
            end // if
        end else begin
            if ((quantized_residual & residual_mask) != residual_mask) begin
                final_residual = residual_mask;
            end else begin
                final_residual = quantized_residual;
            end // if
        end // if

        return (final_residual);
    endfunction : dsce_quantization_with_range_check


    // ----------------------------------------------
    //  simple quantization
    // ----------------------------------------------
    function automatic tDSC_RESIDUAL dsce_quantization (
        input tDSC_RESIDUAL res,
        input tDSC_QLEVEL   qlevel
    );
        tDSC_RESIDUAL round;
        tDSC_RESIDUAL quantized_residual;

        round = 17'h07fff >> (5'd16 - qlevel);
        quantized_residual = (res[16] == 1'b0) ? $signed(res + round) >>> qlevel : - ($signed(round - res) >> qlevel);

        return (quantized_residual);
    endfunction : dsce_quantization


    // ----------------------------------------------
    //  inverse quantization
    // ----------------------------------------------
    function automatic tDSC_RESIDUAL dsce_invquantization (
        input tDSC_RESIDUAL res,
        input tDSC_QLEVEL qlevel
    );
        dsce_invquantization = res <<< qlevel;
    endfunction : dsce_invquantization


    // ----------------------------------------------
    //  recon the pixel from the quant residual
    // ----------------------------------------------
    function automatic tDSC_COMPONENT dsce_recon (
        input tDSC_COMPONENT    predict,
        input tDSC_RESIDUAL     residual,
        input tDSC_QLEVEL       qlevel
    );
        tDSC_RESIDUAL        inv_quant_residual;
        logic signed [17:0]  recon_cpnt;
        tDSC_COMPONENT       final_recon;

        inv_quant_residual = dsce_invquantization(residual, qlevel);
        recon_cpnt = {2'b00, predict} + {inv_quant_residual[16], inv_quant_residual};

        case (recon_cpnt[17:16])
            2'b10, 2'b11:   final_recon = kDSC_COMPONENT_INIT;
            2'b01:          final_recon = 16'hffff;
            default:        final_recon = recon_cpnt;
        endcase

        return (final_recon);
    endfunction : dsce_recon


    // ----------------------------------------------
    //  right shift a pixel structure
    // ----------------------------------------------
    function automatic tDSC_PIXEL dsce_shift_pixel (
        input tDSC_PIXEL    src_pixel,
        input logic [3:0]   shift_amount
    );
        tDSC_PIXEL  shifted_pixel;

        shifted_pixel.y  = src_pixel.y  >> shift_amount;
        shifted_pixel.co = src_pixel.co >> shift_amount;
        shifted_pixel.cg = src_pixel.cg >> shift_amount;

        return (shifted_pixel);
    endfunction : dsce_shift_pixel


    // ----------------------------------------------
    //  implementation of the spec ceil_log2
    // ----------------------------------------------
    function automatic logic [3:0] dsce_ceil_log2 (
        input logic [15:0]  component_in
    );
        logic [3:0] result;

        //assert (component_in[15:9] == 7'd0) else $error("component out of range [8:0], 0x%04x", component_in);

        case (component_in[8:0]) inside
            [9'h100:9'h1ff] : result = 4'd9;
            [9'h080:9'h0ff] : result = 4'd8;
            [9'h040:9'h07f] : result = 4'd7;
            [9'h020:9'h03f] : result = 4'd6;
            [9'h010:9'h01f] : result = 4'd5;
            [9'h008:9'h00f] : result = 4'd4;
            [9'h004:9'h007] : result = 4'd3;
            [9'h002:9'h003] : result = 4'd2;
            [9'h001:9'h001] : result = 4'd1;
            default         : result = 4'd0;
        endcase

        return (result);
    endfunction : dsce_ceil_log2


    // ----------------------------------------------
    //  clamp the predicted size
    // ----------------------------------------------
    function automatic logic [4:0] dsce_clamp_size (
        input logic signed [5:0] new_size,
        input logic [4:0]        max_size
    );
        logic       compare;
        logic [4:0] clamped_size;

        compare = (new_size[4:0] > max_size) ? 1'b1 : 1'b0;

        case ({new_size[5], compare})
            2'b01:          clamped_size = max_size;
            2'b10, 2'b11:   clamped_size = 5'd0;
            default:        clamped_size = new_size[4:0];
        endcase

        return (clamped_size);
    endfunction : dsce_clamp_size


    // ------------------------------------------------------------------------------------------------------------
    //                                           flatness support functions
    // ------------------------------------------------------------------------------------------------------------
    function automatic tDSC_QLEVEL dsce_get_very_flat_qp (
        input logic [3:0] bpc
    );
        tDSC_QLEVEL very_flat_qp;

        case (bpc)
            4'd10:    very_flat_qp = 5'd5;
            4'd12:    very_flat_qp = 5'd9;
            4'd14:    very_flat_qp = 5'd13;
            4'd0:     very_flat_qp = 5'd17;
            default:  very_flat_qp = 5'd1;
        endcase

        return (very_flat_qp);
    endfunction : dsce_get_very_flat_qp


    function automatic tDSC_QLEVEL dsce_get_somewhat_flat_threshold (
        input logic [3:0] bpc
    );
        tDSC_QLEVEL somewhat_flat_threshold;

        case (bpc)
            4'd10:    somewhat_flat_threshold = 5'd11;
            4'd12:    somewhat_flat_threshold = 5'd15;
            4'd14:    somewhat_flat_threshold = 5'd19;
            4'd0:     somewhat_flat_threshold = 5'd23;
            default:  somewhat_flat_threshold = 5'd7;
        endcase

        return (somewhat_flat_threshold);
    endfunction : dsce_get_somewhat_flat_threshold


    function automatic tDSC_QLEVEL dsce_adjust_qp_somewhat_flat (
        input tDSC_QLEVEL current_qp
    );
        tDSC_QLEVEL flat_qp;

        if (current_qp < kDSC_SOMEWHAT_FLAT_QP_DELTA) begin
            flat_qp = kDSC_QLEVEL_ZERO;
        end else begin
            flat_qp = current_qp - kDSC_SOMEWHAT_FLAT_QP_DELTA;
        end // if

        return (flat_qp);
    endfunction : dsce_adjust_qp_somewhat_flat


    // ------------------------------------------------------------------------------------------------------------
    //                                              MIN/MAX functions
    // ------------------------------------------------------------------------------------------------------------
    function automatic logic [15:0] dsce_min_3 (
        input logic [15:0] s0,
        input logic [15:0] s1,
        input logic [15:0] s2
    );
        logic a, b, c;

        a = (s0 < s1) ? 1'b1 : 1'b0;
        b = (s0 < s2) ? 1'b1 : 1'b0;
        c = (s1 < s2) ? 1'b1 : 1'b0;

        case ({a,b,c})
            3'b110, 3'b111:  dsce_min_3 = s0;
            3'b001, 3'b011:  dsce_min_3 = s1;
            default:         dsce_min_3 = s2;
        endcase
    endfunction : dsce_min_3


    function automatic logic [15:0] dsce_max_3 (
        input logic [15:0] s0,
        input logic [15:0] s1,
        input logic [15:0] s2
    );
        logic a, b, c;

        a = (s0 < s1) ? 1'b1 : 1'b0;
        b = (s0 < s2) ? 1'b1 : 1'b0;
        c = (s1 < s2) ? 1'b1 : 1'b0;

        case ({a,b,c})
            3'b001, 3'b000:  dsce_max_3 = s0;
            3'b110, 3'b100:  dsce_max_3 = s1;
            default:         dsce_max_3 = s2;
        endcase
    endfunction : dsce_max_3


    function automatic logic [15:0] dsce_min_2 (
        input logic [15:0] s0,
        input logic [15:0] s1
    );
        dsce_min_2 = (s0 < s1) ? s0 : s1;
    endfunction : dsce_min_2


    function automatic logic [15:0] dsce_max_2 (
        input logic [15:0] s0,
        input logic [15:0] s1
    );
        dsce_max_2 = (s0 > s1) ? s0 : s1;
    endfunction : dsce_max_2


    task automatic dsce_min_sad4 (
        input  tDSC_ICH_INDEX   index [3:0],
        input  logic [16:0]     sad [3:0],
        output tDSC_ICH_INDEX   min_index,
        output logic [16:0]     min_sad
    );
        logic [5:0]  compare_flags;

        compare_flags[5] = (sad[0] > sad[1]) ? 1'b1 : 1'b0;
        compare_flags[4] = (sad[0] > sad[2]) ? 1'b1 : 1'b0;
        compare_flags[3] = (sad[0] > sad[3]) ? 1'b1 : 1'b0;
        compare_flags[2] = (sad[1] > sad[2]) ? 1'b1 : 1'b0;
        compare_flags[1] = (sad[1] > sad[3]) ? 1'b1 : 1'b0;
        compare_flags[0] = (sad[2] > sad[3]) ? 1'b1 : 1'b0;

        if (compare_flags[5:3] == 3'b000) begin
            min_index = index[0];
            min_sad = sad[0];
        end else begin
            case (compare_flags[2:0])
                3'b001, 3'b000 : begin
                    min_index = index[1];
                    min_sad = sad[1];
                end // select 1

                3'b010, 3'b100, 3'b110 : begin
                    min_index = index[2];
                    min_sad = sad[2];
                end // select 2

                default: begin
                    min_index = index[3];
                    min_sad = sad[3];
                end // select 3
            endcase
        end // if
    endtask : dsce_min_sad4

endpackage : dsce_defs_pkg

