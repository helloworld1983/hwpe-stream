/*
 * hwpe_stream_strbgen.sv
 * Francesco Conti <f.conti@unibo.it>
 *
 * Copyright (C) 2014-2018 ETH Zurich, University of Bologna
 * Copyright and related rights are licensed under the Solderpad Hardware
 * License, Version 0.51 (the "License"); you may not use this file except in
 * compliance with the License.  You may obtain a copy of the License at
 * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
 * or agreed to in writing, software, hardware and materials distributed under
 * this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 */

import hwpe_stream_package::*;

module hwpe_stream_strbgen
#(
  parameter int unsigned DATA_WIDTH = 32
)
(
  // global signals
  input  logic                   clk_i,
  input  logic                   rst_ni,
  input  logic                   test_mode_i,
  // local clear
  input  logic                   clear_i,
  // control channel
  input  ctrl_addressgen_t       ctrl_i,
  // interfaces
  hwpe_stream_intf_stream.sink   push_i,
  hwpe_stream_intf_stream.source pop_o
);

  logic [7:0] cnt;

  always_ff @(posedge clk_i or negedge rst_ni)
  begin
    if(~rst_ni) begin
      cnt <= '0;
    end
    else if(clear_i) begin
      cnt <= '0;
    end
    else if(push_i.valid & push_i.ready) begin
      if(cnt < ctrl_i.line_length-8'h1) begin
        cnt <= cnt + 8'h1;
      end
      else begin
        cnt <= '0;
      end
    end
  end

  logic [DATA_WIDTH/8-1:0] decoded_remainder;
  always_comb
  begin
    decoded_remainder = '0;
    for(int i=0; i<DATA_WIDTH/8; i++) begin
      if(i<ctrl_i.line_length_remainder)
        decoded_remainder[i] = 1'b1;
    end
  end

  assign pop_o.valid = push_i.valid;
  assign pop_o.data  = push_i.data;
  assign pop_o.strb  = ((cnt == ctrl_i.line_length-8'h1) && (ctrl_i.line_length_remainder != '0)) ? push_i.strb & decoded_remainder : push_i.strb;

  assign push_i.ready = pop_o.ready;

endmodule // hwpe_stream_strbgen
