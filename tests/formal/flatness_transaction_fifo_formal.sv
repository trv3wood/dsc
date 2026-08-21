// SPDX-License-Identifier: MIT

// 该模型逐拍复现 dsce_slice.sv 中 FlatnessTransactionFifo 的计数控制。
// payload 不影响上下溢，因此这里只保留事务、指针和计数状态。
module flatness_transaction_fifo_formal;
    (* gclk *) logic clk;

    (* anyseq *) logic push;
    (* anyseq *) logic pop;
    (* anyseq *) logic start_of_slice;

    logic [2:0] write_ptr = 3'd0;
    logic [2:0] read_ptr = 3'd0;
    logic [3:0] fifo_count = 4'd0;

    // outstanding_count 表示预测流水中尚未返回的合法事务。
    // slice 边界不会让已经进入流水的事务凭空消失。
    logic [3:0] outstanding_count = 4'd0;
    logic       crossed_with_outstanding = 1'b0;

    always_ff @(posedge clk) begin
        // 环境只产生容量范围内的事务，也不会返回不存在的事务。
        assume (!push || outstanding_count < 4'd8);
        assume (!pop || outstanding_count != 4'd0);
        // slice 起始拍只用于边界控制，避免靠同拍传输构造平凡轨迹。
        assume (!start_of_slice || (!push && !pop));

        case ({push, pop})
            2'b10: outstanding_count <= outstanding_count + 4'd1;
            2'b01: outstanding_count <= outstanding_count - 4'd1;
            default: outstanding_count <= outstanding_count;
        endcase

        if (start_of_slice && outstanding_count != 4'd0)
            crossed_with_outstanding <= 1'b1;

        if (push)
            write_ptr <= write_ptr + 3'd1;
        if (pop)
            read_ptr <= read_ptr + 3'd1;

        case ({push, pop})
            2'b10: fifo_count <= fifo_count + 4'd1;
            2'b01: fifo_count <= fifo_count - 4'd1;
            default: fifo_count <= fifo_count;
        endcase

`ifdef SAFE_FLUSH
        assert (!push || fifo_count < 4'd8);
        assert (!pop || fifo_count != 4'd0);
        assert (fifo_count == outstanding_count);
`else
        // 目标轨迹：带未完成事务跨过边界，随后按顺序安全返回。
        cover (crossed_with_outstanding && pop && fifo_count != 4'd0);
`endif
    end
endmodule
