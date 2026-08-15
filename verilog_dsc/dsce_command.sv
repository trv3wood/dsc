// ------------------------------------------------------------------------------------------------
//     COPYRIGHT © 2016-2022, TRILINEAR TECHNOLOGIES, INC.
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
//     DESCRIPTION : Top level command and control block for the DSC encoder. This block was
//                   added to the top level to provide fine tuned enable control.
// ------------------------------------------------------------------------------------------------

// ----------------------------------------------
//  includes
// ----------------------------------------------
import dsce_defs_pkg::*;


// ----------------------------------------------
//  module declaration
// ----------------------------------------------
module dsce_command
(
    // clock domains and resets
    input  logic                axi_clk,                    // AXI bus clock
    input  logic                axi_reset_n,                // AXI domain reset
    input  logic                dsc_clk,                    // encoder clock
    input  logic                dsc_reset_n,                // DSC domain reset

    // source input
    input  logic                axi_tframe_in,              // top of frame indicator

    // host interface config and pps management
    input  tDSCE_CONFIG         cfg_dsc_encoder,            // general encoder configuration
    output logic                axi_pps_refresh,            // refresh toggle flag
    input  logic                axi_pps_refresh_complete,   // refresh complete handshake

    // status inputs and outputs
    output tDSCE_CONTROL_STATUS cfg_dsc_encoder_status,     // status structure

    // control outputs
    output logic                apb_one_usec_tick,          // one microsecond timer
    output logic                axi_encoder_enable,         // encoder enable
    output logic                axi_pps_update,             // update flag for the AXI domain
    output logic                axi_new_frame,              // init the AXI function for new frame
    output logic                dsc_encoder_enable,         // encoder enable
    output logic                dsc_pps_update,             // update flag for the DSC domain
    output logic                dsc_new_frame               // init the DSC function for new frame
);
    // ------------------------------------------------------------------------------------------------------------
    //                                          internal definitions
    // ------------------------------------------------------------------------------------------------------------

    logic                       i_enable;
    logic [1:0]                 i_frame_detect;
    logic                       i_sync_force_enable;
    logic                       i_sync_enable;
    logic [1:0]                 i_sync_command_update;
    tDSCE_ENCODER_COMMAND       i_command;
    logic                       i_command_update;
    logic                       i_refresh_pending;
    logic                       i_update_toggle;
    logic [1:0]                 i_sync_update;
    logic                       i_encoder_active;
    logic [3:0]                 i_reset_count;
    logic                       i_end_of_frame_toggle;
    logic                       i_encoder_timeout;
    logic                       i_rate_error;
    logic                       i_new_frame_toggle;
    logic [1:0]                 i_sync_new_frame;
    logic                       i_free_run;

    logic [9:0]                 i_clock_divider;
    logic [7:0]                 i_timeout_count;

    enum { eCMD_BYPASS,
           eCMD_RESET,
           eCMD_RESET_DELAY,
           eCMD_FRAME_WAIT_TOP,
           eCMD_FRAME_PPS,
           eCMD_FRAME_START,
           eCMD_FRAME_END
    }  i_cmd_state;

    // ------------------------------------------------------------------------------------------------------------
    //                                          process assignments
    // ------------------------------------------------------------------------------------------------------------

    always_comb begin : SigMap
        cfg_dsc_encoder_status.encoder_active = i_encoder_active;
        cfg_dsc_encoder_status.end_of_frame = i_end_of_frame_toggle;
        cfg_dsc_encoder_status.encoder_timeout = i_encoder_timeout;
        cfg_dsc_encoder_status.rate_error = i_rate_error;
    end : SigMap


    // --------------------------------------------------------------------------
    //  AXI domain logic
    // --------------------------------------------------------------------------

    always_ff@(posedge axi_clk or negedge axi_reset_n) begin : AXIDomain
        if (axi_reset_n == 1'b0) begin
            axi_encoder_enable <= 1'b0;
            axi_pps_refresh <= 1'b0;
            axi_pps_update <= 1'b0;
            axi_new_frame <= 1'b0;

            i_cmd_state <= eCMD_BYPASS;
            i_frame_detect <= 2'b00;
            i_command_update <= 1'b0;
            i_command <= eENCODER_COMMAND_OFF;
            i_enable <= 1'b0;
            i_refresh_pending <= 1'b0;
            i_update_toggle <= 1'b0;
            i_encoder_active <= 1'b0;
            i_reset_count <= 4'hf;
            i_end_of_frame_toggle <= 1'b0;
            i_rate_error <= 1'b0;
            i_free_run <= 1'b0;
            i_new_frame_toggle <= 1'b0;

        end else begin

            // detect the input frame flag (vsync)
            i_frame_detect <= {i_frame_detect[0], axi_tframe_in};

            // temporary tie off for future implementation (revision 2.6)
            i_rate_error <= 1'b0;

            // change the enable at the input vertical sync or when forced on
            if (i_sync_command_update[0] != i_sync_command_update[1]) begin
                i_command <= cfg_dsc_encoder.encode_command;
                i_command_update <= 1'b1;
            end else begin
                i_command_update <= 1'b0;
            end // if

            // parameter set update
            axi_pps_update <= 1'b0;
            axi_pps_refresh <= 1'b0;

            if (i_refresh_pending == 1'b0) begin
                if (i_frame_detect == 2'b01) begin
                    i_refresh_pending <= 1'b1;
                    axi_pps_refresh <= 1'b1;
                end // if
            end else begin
                if (axi_pps_refresh_complete == 1'b1) begin
                    i_refresh_pending <= 1'b0;
                    axi_pps_update <= 1'b1;
                    i_update_toggle <= ~i_update_toggle;
                end // if
            end // if

            // default reset states
            axi_new_frame <= 1'b0;

            // command state controller
            case (i_cmd_state)
                // ------------------------------------------------------------------
                //  When the encoder is off, the input and output is connected
                //  in a bypass mode to assist in DP integrated systems
                // ------------------------------------------------------------------
                eCMD_BYPASS: begin
                    axi_encoder_enable <= 1'b0;
                    i_encoder_active <= 1'b0;
                    i_free_run <= 1'b0;

                    if (i_command_update == 1'b1) begin
                        case (i_command)
                            eENCODER_COMMAND_OFF:   begin i_cmd_state <= eCMD_BYPASS;          i_encoder_active <= 1'b0;  i_free_run <= 1'b0;  end
                            eENCODER_COMMAND_RESET: begin i_cmd_state <= eCMD_RESET;           i_encoder_active <= 1'b0;  i_free_run <= 1'b0;  end
                            eENCODER_COMMAND_FRAME: begin i_cmd_state <= eCMD_FRAME_WAIT_TOP;  i_encoder_active <= 1'b1;  i_free_run <= 1'b0;  end
                            eENCODER_COMMAND_RUN:   begin i_cmd_state <= eCMD_FRAME_WAIT_TOP;  i_encoder_active <= 1'b1;  i_free_run <= 1'b1;  end
                            default: ;
                        endcase
                    end // if
                end // eCMD_BYPASS

                // ------------------------------------------------------------------
                //  Issue a soft reset to the encoder logic and set a count
                //  to hold in the reset state for a short time.
                // ------------------------------------------------------------------
                eCMD_RESET:  begin
                    i_encoder_active <= 1'b0;
                    i_cmd_state <= eCMD_RESET_DELAY;
                    i_reset_count <= 4'hf;
                end // eCMD_RESET

                // ------------------------------------------------------------------
                //  Hold the soft reset for a time and return to the BYPASS state
                //  once the reset period has expired.
                // ------------------------------------------------------------------
                eCMD_RESET_DELAY:  begin
                    i_encoder_active <= 1'b0;
                    if (i_reset_count == 4'h0) begin
                        i_cmd_state <= eCMD_BYPASS;
                    end // if

                    i_reset_count <= i_reset_count - 4'd1;
                end // eCMD_RESET_DELAY

                // ------------------------------------------------------------------
                //  Before we enable the encoder, wait for the top of the next
                //  frame.  This prevents the encoding of partial frames.
                // ------------------------------------------------------------------
                eCMD_FRAME_WAIT_TOP:  begin
                    i_encoder_active <= 1'b1;

                    if (i_command_update == 1'b1 & i_command == eENCODER_COMMAND_RESET) begin
                        axi_encoder_enable <= 1'b0;
                        i_encoder_active <= 1'b0;
                        i_cmd_state <= eCMD_RESET;
                    end else if (i_frame_detect == 2'b10 || i_sync_force_enable == 1'b1) begin
                        axi_encoder_enable <= 1'b0;
                        i_cmd_state <= eCMD_FRAME_PPS;
                    end // if
                end // eCMD_FRAME_WAIT_TOP

                // ------------------------------------------------------------------
                //  Lock in the PPS values to encode the current frame.  These
                //  values can be changed for the next frame once the current
                //  frame has started processing.
                // ------------------------------------------------------------------
                eCMD_FRAME_PPS:  begin
                    i_encoder_active <= 1'b1;
                    axi_encoder_enable <= 1'b0;

                    if (i_refresh_pending == 1'b0) begin
                        i_cmd_state <= eCMD_FRAME_START;
                        axi_new_frame <= 1'b1;
                        i_new_frame_toggle <= ~i_new_frame_toggle;
                    end // if
                end // eCMD_FRAME_PPS

                // ------------------------------------------------------------------
                //  Begin encoding the frame after the PPS is locked.
                // ------------------------------------------------------------------
                eCMD_FRAME_START:  begin
                    axi_encoder_enable <= 1'b1;
                    i_encoder_active <= 1'b1;

                    if (i_command_update == 1'b1 & i_command == eENCODER_COMMAND_RESET) begin
                        axi_encoder_enable <= 1'b0;
                        i_encoder_active <= 1'b0;
                        i_cmd_state <= eCMD_BYPASS;
                    end else begin
                        if (i_frame_detect == 2'b10) begin
                            i_cmd_state <= eCMD_FRAME_END;
                        end // if
                    end // if
                end // eCMD_FRAME_START

                // ------------------------------------------------------------------
                //  Wait for the end of the frame.  If we are in single frame mode
                //  return to the BYPASS state.  Otherwise, lock in the next PPS
                //  and encode the next frame.
                // ------------------------------------------------------------------
                eCMD_FRAME_END:  begin
                    axi_encoder_enable <= 1'b1;
                    i_encoder_active <= 1'b1;

                    if (i_command_update == 1'b1 && i_command == eENCODER_COMMAND_RESET) begin
                        axi_encoder_enable <= 1'b0;
                        i_encoder_active <= 1'b0;
                        i_cmd_state <= eCMD_BYPASS;
                    end else begin
                        i_end_of_frame_toggle <= ~i_end_of_frame_toggle;
                        axi_encoder_enable <= 1'b0;
                        i_encoder_active <= 1'b0;

                        if (i_free_run == 1'b0) begin
                            i_cmd_state <= eCMD_BYPASS;
                        end else begin
                            i_cmd_state <= eCMD_FRAME_PPS;
                        end // if

                    end // if
                end // eCMD_FRAME_END

                // ------------------------------------------------------------------
                //  Default state is for synthesis only.  Not a functional state.
                // ------------------------------------------------------------------
                default:  begin
                    axi_encoder_enable <= 1'b0;

                    i_cmd_state <= eCMD_BYPASS;
                    i_encoder_active <= 1'b0;
                    i_end_of_frame_toggle <= 1'b0;
                end // default
            endcase
        end // if
    end : AXIDomain


    // --------------------------------------------------------------------------
    //  AXITimer
    // --------------------------------------------------------------------------
    always_ff@(posedge axi_clk or negedge axi_reset_n) begin : AXITimer
        if (axi_reset_n == 1'b0) begin
            apb_one_usec_tick <= 1'b0;

            i_clock_divider <= 10'd0;
            i_timeout_count <= 8'd0;
            i_encoder_timeout <= 1'b0;


        end else begin
            apb_one_usec_tick <= 1'b0;

            // ----- 1 usec clock tick generator ----- //
            if (cfg_dsc_encoder.clock_divider == 10'd0) begin
                apb_one_usec_tick <= 1'b0;
            end else if (i_clock_divider == cfg_dsc_encoder.clock_divider) begin
                apb_one_usec_tick <= 1'b1;
            end // if

            // ----- clock divide counter ----- //
            if (i_clock_divider[9:1] == 9'd0 || cfg_dsc_encoder.clock_divider == 10'd0) begin
                i_clock_divider <= cfg_dsc_encoder.clock_divider;
            end else begin
                i_clock_divider <= i_clock_divider - 10'd1;
            end // if

            // ----- timeout counter ----- //
            if (i_cmd_state != eCMD_FRAME_END) begin
                i_timeout_count <= cfg_dsc_encoder.timeout_count;
            end else if (apb_one_usec_tick == 1'b1) begin
                if (i_timeout_count == 8'h01) begin
                    i_timeout_count <= cfg_dsc_encoder.timeout_count;
                end else begin
                    i_timeout_count <= i_timeout_count - 8'd1;
                end // if
            end // if

            // ----- timeout flag ----- //
            if (i_cmd_state == eCMD_RESET) begin
                i_encoder_timeout <= 1'b0;
            end else if (apb_one_usec_tick == 1'b1 && i_timeout_count == 8'd1) begin
                i_encoder_timeout <= 1'b1;
            end // if
        end // if
    end : AXITimer


    // --------------------------------------------------------------------------
    //  DSC domain
    // --------------------------------------------------------------------------

    always_ff@(posedge dsc_clk or negedge dsc_reset_n) begin : DSCDomain
        if (dsc_reset_n == 1'b0) begin
            dsc_encoder_enable <= 1'b0;
            dsc_pps_update <= 1'b0;
            dsc_new_frame <= 1'b0;
        end else begin

            dsc_encoder_enable <= i_sync_enable;
            dsc_pps_update <= (i_sync_update[0] != i_sync_update[1]) ? 1'b1 : 1'b0;
            dsc_new_frame <= (i_sync_new_frame[0] != i_sync_new_frame[1]) ? 1'b1 : 1'b0;
        end // if
    end : DSCDomain


    // ------------------------------------------------------------------------------------------------------------
    //                                          sync stages
    // ------------------------------------------------------------------------------------------------------------
    gprim_sync2_stage sync_command_inst   (.sync_clk (axi_clk), .reset_n (axi_reset_n), .async_in (cfg_dsc_encoder.encode_command_update), .sync_out (i_sync_command_update));
    gprim_sync_stage  sync_force_inst     (.sync_clk (axi_clk), .reset_n (axi_reset_n), .async_in (cfg_dsc_encoder.force_enable),          .sync_out (i_sync_force_enable));
    gprim_sync_stage  sync_enable_inst    (.sync_clk (dsc_clk), .reset_n (dsc_reset_n), .async_in (axi_encoder_enable),                    .sync_out (i_sync_enable));
    gprim_sync2_stage sync_update_inst    (.sync_clk (dsc_clk), .reset_n (dsc_reset_n), .async_in (i_update_toggle),                       .sync_out (i_sync_update));
    gprim_sync2_stage sync_new_frame_inst (.sync_clk (dsc_clk), .reset_n (dsc_reset_n), .async_in (i_new_frame_toggle),                    .sync_out (i_sync_new_frame));

endmodule : dsce_command


