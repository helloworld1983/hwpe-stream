/*
 * hwpe_stream_source.sv
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

module hwpe_stream_source
#(
  // Stream interface params
  parameter int unsigned DATA_WIDTH = 32,
  parameter int unsigned NB_TCDM_PORTS = DATA_WIDTH/32
)
(
  input logic clk_i,
  input logic rst_ni,
  input logic test_mode_i,
  input logic clear_i,

  hwpe_stream_intf_tcdm.master   tcdm [NB_TCDM_PORTS-1:0],
  hwpe_stream_intf_stream.source stream,

  // control plane
  input  ctrl_sourcesink_t   ctrl_i,
  output flags_sourcesink_t  flags_o
);

  state_sourcesink_t cs, ns;

  logic done;
  logic address_gen_en;
  logic address_gen_clr;

  logic [31:0]                gen_addr;
  logic [NB_TCDM_PORTS*4-1:0] gen_strb;

  logic tcdm_int_req;
  logic tcdm_int_gnt;
  logic [NB_TCDM_PORTS-1:0] tcdm_split_gnt;

  logic valid_int;
  logic [DATA_WIDTH -1:0] data_packed;
  logic [DATA_WIDTH -1:0] data_int;

  hwpe_stream_intf_stream #(
    .DATA_WIDTH ( 32 )
  ) split_streams [NB_TCDM_PORTS-1:0] (
    .clk ( clk_i )
  );

  hwpe_stream_intf_stream #(
    .DATA_WIDTH ( DATA_WIDTH )
  ) misaligned_stream (
    .clk ( clk_i )
  );

  hwpe_stream_merge #(
    .DATA_WIDTH_IN ( 32            ),
    .NB_IN_STREAMS ( NB_TCDM_PORTS )
  ) i_stream_merge (
    .clk_i    ( clk_i              ),
    .rst_ni   ( rst_ni             ),
    .clear_i  ( clear_i            ),
    .stream_i ( split_streams      ),
    .stream_o ( misaligned_stream  )
  );

  hwpe_stream_addressgen #(
    .STEP         ( NB_TCDM_PORTS*4            ),
    .REALIGN_TYPE ( HWPE_STREAM_REALIGN_SOURCE )
  ) i_addressgen (
    .clk_i          ( clk_i                    ),
    .rst_ni         ( rst_ni                   ),
    .test_mode_i    ( test_mode_i              ),
    .enable_i       ( address_gen_en           ),
    .clear_i        ( address_gen_clr          ),
    .gen_addr_o     ( gen_addr                 ),
    .gen_strb_o     ( gen_strb                 ),
    .ctrl_i         ( ctrl_i.addressgen_ctrl   ),
    .flags_o        ( flags_o.addressgen_flags )
  );

  hwpe_stream_source_realign #(
    .DATA_WIDTH ( DATA_WIDTH )
  ) i_realign (
    .clk_i      ( clk_i                                  ),
    .rst_ni     ( rst_ni                                 ),
    .test_mode_i( test_mode_i                            ),
    .clear_i    ( clear_i                                ),
    .ctrl_i     ( flags_o.addressgen_flags.realign_flags ),
    .strb_i     ( gen_strb                               ),
    .stream_i   ( misaligned_stream                      ),
    .stream_o   ( stream                                 )
  );

  // tcdm ports binding
  generate
    for(genvar ii=0; ii<NB_TCDM_PORTS; ii++) begin: tcdm_binding
      assign tcdm[ii].req  = tcdm_int_req;
      assign tcdm[ii].add  = gen_addr + ii*4;
      assign tcdm[ii].wen  = 1'b1;
      assign tcdm[ii].be   = 4'h0;
      assign tcdm[ii].data = '0; 
      assign tcdm_split_gnt[ii] = tcdm[ii].gnt;
      assign split_streams[ii].data  = tcdm[ii].r_data;
      assign split_streams[ii].valid = tcdm[ii].r_valid; // (clear_i) ? 1'b1 : tcdm[ii].r_valid;
    end
  endgenerate

  always_comb
  begin
    tcdm_int_gnt = 1'b1;
    for(int i=0; i<NB_TCDM_PORTS; i++)
      tcdm_int_gnt &= tcdm_split_gnt[i];
  end

  // finite-state machine
  always_ff @(posedge clk_i, negedge rst_ni)
  begin : fsm_seq
    if(rst_ni == 1'b0) begin
      cs <= STREAM_IDLE;
    end
    else if(clear_i == 1'b1) begin
      cs <= STREAM_IDLE;
    end
    else begin
      cs <= ns;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni)
  begin : done_source_ff
    if(rst_ni == 1'b0)
      flags_o.done <= 1'b0;
    else if(clear_i == 1'b0)
      flags_o.done <= 1'b0;
    else
      flags_o.done <= done;
  end

  always_comb
  begin : fsm_comb
    tcdm_int_req  = 1'b0;
    flags_o.ready_start = 1'b0;
    done = 1'b0;
    ns         = cs;
    address_gen_en  = 1'b0;
    address_gen_clr = clear_i;
    case(cs)
      STREAM_IDLE: begin
        flags_o.ready_start = 1'b1;
        if(ctrl_i.req_start) begin
          ns = STREAM_WORKING;
        end
        else begin
          ns = STREAM_IDLE;
        end
        address_gen_en = 1'b0;
      end //~STREAM_IDLE
      STREAM_WORKING: begin
        if(stream.ready) begin
          tcdm_int_req = 1'b1;
          if(tcdm_int_gnt)
            address_gen_en = 1'b1;
          else
            address_gen_en = 1'b0;
        end
        else begin
          tcdm_int_req = 1'b0;
          address_gen_en = 1'b0;
        end
        if(tcdm_int_gnt) begin
          if(flags_o.addressgen_flags.in_progress == 1'b1) begin
            ns = STREAM_WORKING;
          end
          else begin
            done = 1'b1;
            ns   = STREAM_IDLE;
            address_gen_clr = 1'b1;
          end
        end
        else begin
          ns = STREAM_WORKING;
        end
      end//~SOURCE
      default: begin
        ns = STREAM_IDLE;
        address_gen_en = 1'b0;
      end
    endcase
  end

endmodule
