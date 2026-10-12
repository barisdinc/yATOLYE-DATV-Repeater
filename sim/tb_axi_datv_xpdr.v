// yATOLYE DATV Repeater - axi_datv_xpdr testbench
//
// Exercises the register interface, bypass, gain, saturation, power
// detector, squelch, force mute, the beacon NCO / mixer and the sum of the
// repeater and beacon paths. Run with sim/run.sh (Vivado xsim).

`timescale 1ns/100ps

module tb;

  reg clk = 0, aclk = 0, rst = 1, aresetn = 0;
  always #4 clk = ~clk;     // 125 MHz l_clk
  always #5 aclk = ~aclk;   // 100 MHz axi

  reg         rx_valid = 0;
  reg  [15:0] rx_i = 0, rx_q = 0;
  reg  [15:0] tin_i = 16'h1230, tin_q = 16'h4560;
  wire [15:0] tout_i, tout_q;

  reg         awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
  reg  [15:0] awaddr = 0, araddr = 0;
  reg  [31:0] wdata = 0;
  wire        awready, wready, bvalid, arready, rvalid;
  wire [1:0]  bresp, rresp;
  wire [31:0] rdata;

  integer errors = 0;

  axi_datv_xpdr dut (
    .clk(clk), .rst(rst),
    .rx_valid(rx_valid), .rx_data_i(rx_i), .rx_data_q(rx_q),
    .tx_valid(rx_valid), .tx_in_data_i(tin_i), .tx_in_data_q(tin_q),
    .tx_out_data_i(tout_i), .tx_out_data_q(tout_q),
    .s_axi_aclk(aclk), .s_axi_aresetn(aresetn),
    .s_axi_awvalid(awvalid), .s_axi_awaddr(awaddr), .s_axi_awprot(3'd0), .s_axi_awready(awready),
    .s_axi_wvalid(wvalid), .s_axi_wdata(wdata), .s_axi_wstrb(4'hf), .s_axi_wready(wready),
    .s_axi_bvalid(bvalid), .s_axi_bresp(bresp), .s_axi_bready(bready),
    .s_axi_arvalid(arvalid), .s_axi_araddr(araddr), .s_axi_arprot(3'd0), .s_axi_arready(arready),
    .s_axi_rvalid(rvalid), .s_axi_rresp(rresp), .s_axi_rdata(rdata), .s_axi_rready(rready));

  task axi_wr(input [15:0] a, input [31:0] d);
    begin
      @(posedge aclk);
      awaddr <= a; wdata <= d; awvalid <= 1; wvalid <= 1;
      @(posedge aclk);
      while (!(awready && wready)) @(posedge aclk);
      awvalid <= 0; wvalid <= 0;
      while (!bvalid) @(posedge aclk);
      @(posedge aclk);
    end
  endtask

  task axi_rd(input [15:0] a, output [31:0] d);
    begin
      @(posedge aclk);
      araddr <= a; arvalid <= 1;
      @(posedge aclk);
      while (!arready) @(posedge aclk);
      arvalid <= 0;
      while (!rvalid) @(posedge aclk);
      d = rdata;
      @(posedge aclk);
    end
  endtask

  task check(input [255:0] name, input [31:0] got, input [31:0] exp);
    begin
      if (got !== exp) begin
        $display("FAIL %0s: got %h exp %h", name, got, exp);
        errors = errors + 1;
      end else
        $display("ok   %0s: %h", name, got);
    end
  endtask

  // stream constant samples: valid every 2nd clock (1R1T-like)
  reg run = 0;
  reg [11:0] smp_i = 0, smp_q = 0;
  always @(posedge clk) begin
    if (run) begin
      rx_valid <= ~rx_valid;
      rx_i <= {{4{smp_i[11]}}, smp_i};
      rx_q <= {{4{smp_q[11]}}, smp_q};
    end else
      rx_valid <= 0;
  end

  task settle; begin repeat (400) @(posedge clk); end endtask

  reg [31:0] r, r2;

  // sample the output on 64 consecutive valid samples, check the magnitude
  // and the phase step
  task measure(input real step_deg, input real mag, input [255:0] name);
    integer k;
    real pi, ph, ph0, d, m, maxe, maxm;
    begin
      pi = 3.14159265358979; maxe = 0; maxm = 0;
      @(negedge clk); while (!rx_valid) @(negedge clk);
      for (k = 0; k < 64; k = k + 1) begin
        @(negedge clk); while (!rx_valid) @(negedge clk);
        m = $sqrt($itor($signed(tout_i)) ** 2 + $itor($signed(tout_q)) ** 2);
        ph = $atan2($itor($signed(tout_q)), $itor($signed(tout_i))) * 180.0 / pi;
        if (k > 0) begin
          d = ph - ph0 - step_deg;
          while (d > 180.0) d = d - 360.0;
          while (d < -180.0) d = d + 360.0;
          if (d < 0) d = -d;
          if (d > maxe) maxe = d;
        end
        if ((m - mag) > maxm) maxm = m - mag;
        if ((mag - m) > maxm) maxm = mag - m;
        ph0 = ph;
      end
      if (maxe < 0.1 && maxm < 8.0)
        $display("ok   %0s: max phase err %f deg, max mag err %f", name, maxe, maxm);
      else begin
        $display("FAIL %0s: max phase err %f deg, max mag err %f", name, maxe, maxm);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    repeat (10) @(posedge aclk);
    aresetn = 1; rst = 0;
    repeat (10) @(posedge aclk);

    axi_rd(16'h000c, r); check("magic", r, 32'h44415456);
    axi_rd(16'h0044, r); check("gain default", r, 32'h1000);
    axi_wr(16'h0008, 32'hdeadbeef);
    axi_rd(16'h0008, r); check("scratch", r, 32'hdeadbeef);

    // disabled: bypass
    run = 1; smp_i = 12'd100; smp_q = -12'sd200;
    settle;
    check("bypass i", tout_i, 16'h1230);
    check("bypass q", tout_q, 16'h4560);

    // enable, unity gain, no squelch: x<<4
    axi_wr(16'h0040, 32'h1);
    settle;
    check("unity i", tout_i, 16'd1600);
    check("unity q", tout_q, 16'hf380);

    // gain x2 (0x2000)
    axi_wr(16'h0044, 32'h2000);
    settle;
    check("gain2 i", tout_i, 16'd3200);
    check("gain2 q", tout_q, 16'he700);

    // saturation: 2000 * 16 * 2 = 64000 > 32767
    smp_i = 12'd2000; smp_q = -12'sd2000;
    settle;
    check("sat i", tout_i, 16'h7fff);
    check("sat q", tout_q, 16'h8000);
    axi_rd(16'h0088, r);
    if (r == 0) begin $display("FAIL sat count zero"); errors = errors + 1; end
    else $display("ok   sat count %0d", r);

    // power: avg_shift 4, i=100,q=-200 -> 10000+40000 = 50000
    axi_wr(16'h0044, 32'h1000);
    axi_wr(16'h0050, 32'd4);
    smp_i = 12'd100; smp_q = -12'sd200;
    repeat (2000) @(posedge clk);
    axi_rd(16'h0084, r);
    if (r > 49000 && r <= 50000) $display("ok   power %0d", r);
    else begin $display("FAIL power %0d", r); errors = errors + 1; end

    // squelch: threshold above signal -> muted after hang (hang=100 samples)
    axi_wr(16'h004c, 32'd100);
    axi_wr(16'h0048, 32'd60000);
    axi_wr(16'h0040, 32'h3);
    repeat (50) @(posedge clk);
    repeat (1000) @(posedge clk);
    check("squelch muted i", tout_i, 16'd0);
    axi_rd(16'h0080, r); check("status muted", r, 32'h1);

    // threshold below signal -> open
    axi_wr(16'h0048, 32'd40000);
    settle;
    check("squelch open i", tout_i, 16'd1600);
    axi_rd(16'h0080, r); check("status open", r, 32'h3);

    // signal drops -> stays open during hang, then mutes
    smp_i = 12'd1; smp_q = 12'd1;
    repeat (20) @(posedge clk);
    // power decays with tau 16 samples; still within hang -> output follows input
    repeat (60) @(posedge clk);
    check("hang open i", tout_i, 16'd16);
    repeat (600) @(posedge clk);
    check("after hang i", tout_i, 16'd0);

    // force mute
    smp_i = 12'd100; smp_q = -12'sd200;
    axi_wr(16'h0040, 32'h5);
    settle;
    check("force mute", tout_i, 16'd0);

    // disable -> bypass again
    axi_wr(16'h0040, 32'h0);
    settle;
    check("bypass again", tout_i, 16'h1230);

    // beacon only: DC input rotated by the NCO at fs/16 (+22.5 deg/sample)
    tin_i = 16'd16000; tin_q = 16'd0;
    axi_wr(16'h0054, 32'h10000000);
    axi_rd(16'h0054, r); check("beacon freq", r, 32'h10000000);
    axi_wr(16'h0040, 32'h8);
    settle;
    axi_rd(16'h0080, r); check("status beacon", r[2], 1);
    measure(22.5, 16000.0, "beacon +fs/16");

    // negative frequency, -fs/10 (-36 deg/sample), arbitrary input phase
    tin_i = -16'sd9000; tin_q = 16'sd12000;
    axi_wr(16'h0054, -32'sd429496730);
    settle;
    measure(-36.0, 15000.0, "beacon -fs/10");

    // beacon + repeater: rx 100/-200 -> 1600/-3200 added to the beacon
    tin_i = 16'd0; tin_q = 16'd0;
    axi_wr(16'h0040, 32'h1);    // beacon off resets the NCO phase
    axi_wr(16'h0054, 32'h0);
    settle;
    axi_wr(16'h0040, 32'h9);
    settle;
    check("sum zero beacon i", tout_i, 16'd1600);
    check("sum zero beacon q", tout_q, 16'hf380);
    tin_i = 16'd1000; tin_q = -16'sd500;   // phase 0: passes unchanged
    settle;
    check("sum i", tout_i, 16'd2600);
    check("sum q (1 lsb)", tout_q, 16'hf18d);

    // squelch closed: only the beacon remains
    axi_wr(16'h0048, 32'd60000);
    axi_wr(16'h0040, 32'hb);
    repeat (1500) @(posedge clk);
    check("beacon, squelch closed i", tout_i, 16'd1000);
    check("beacon, squelch closed q (1 lsb)", tout_q, 16'hfe0d);

    // sum saturation
    axi_wr(16'h0040, 32'h9);
    smp_i = 12'd1500; smp_q = -12'sd1500;   // 24000 / -24000
    tin_i = 16'd20000; tin_q = -16'sd20000;
    axi_rd(16'h0088, r2);
    settle;
    check("sum sat i", tout_i, 16'h7fff);
    check("sum sat q", tout_q, 16'h8000);
    axi_rd(16'h0088, r);
    if (r - r2 > 100) $display("ok   sum sat count +%0d", r - r2);
    else begin $display("FAIL sum sat count +%0d", r - r2); errors = errors + 1; end

    // both off: bypass
    axi_wr(16'h0040, 32'h0);
    settle;
    check("bypass final i", tout_i, 16'd20000);

    if (errors == 0) $display("ALL TESTS PASSED");
    else $display("%0d TESTS FAILED", errors);
    $finish;
  end

endmodule
