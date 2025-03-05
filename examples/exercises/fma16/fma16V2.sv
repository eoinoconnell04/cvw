// Eoin O'Connell
// Feb 18 2025
// eoconnell@hmc.edu

module fma16 (
    input  logic [15:0] x, y, z,
    input  logic        mul, add, negp, negz,
    input  logic [1:0]  roundmode,
    output logic [15:0] result,
    output logic [3:0]  flags
);

    logic [21:0] Pm, Mm; 
    logic [4:0] Pe, Me;
    logic [5:0] Acnt;   // how many bits?
    logic [10:0] Am, Sm;
    logic [4:0] Mcnt;   // how many bits?

    Pm = {1'b1, x[9:0]} * {1'b1, y[9:0]};
    Pe = x[14:10] + y[14:10] + - 5'd15;

    Acnt = (Pe - z[14:10]);

    Am = {1'b1, z[9:0]} >> Acnt;

    Sm = Pm + Am;

    leading_zero_detector lzd(.Sm(Sm), .Mcnt(Mcnt));

    Mm = Sm << Mcnt;

    Me = Pe - Mcnt;

    logic Ps, As, InvA;

    sign sign_logic (
        .Xs(x[15]), 
        .Ys(y[15]), 
        .Zs(z[15]), 
        .sub(add),   // 'sub' is determined by the 'add' input
        .As(As), 
        .InvA(InvA), 
        .Ps(Ps)
    );

    result = {Ps, Me, Mm[19:10]};


endmodule

module leading_zero_detector (
    input  logic [21:0] Sm,
    output logic [4:0] Mcnt
);
    logic [3:0] high, mid, low;
    
    always_comb begin
        high = |Sm[21:16] ? 4'd0 :
               |Sm[15:12] ? 4'd4 :
               |Sm[11:8]  ? 4'd8 :
               |Sm[7:4]   ? 4'd12 :
               |Sm[3:0]   ? 4'd16 : 4'd22;

        mid = |Sm[high+3:high] ? high :
              |Sm[high-1:high-4] ? high - 4 :
              |Sm[high-5:high-8] ? high - 8 : high - 12;

        low = |Sm[mid+1:mid] ? mid :
              |Sm[mid-1:mid-2] ? mid - 2 :
              |Sm[mid-3:mid-4] ? mid - 4 : mid - 6;

        Mcnt = low;
    end

endmodule

module sign(
    input logic Xs, Ys, Zs, sub,
    output logic As, InvA, Ps
);

    assign Ps = Xs ^ Ys;
    assign As = Zs ^ sub;
    assign InvA = Ps ^ As;


endmodule
