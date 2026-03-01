module add #(
    parameter P_CH  = 4,
    parameter A_BIT = 8
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  in1_valid,
    output logic                  in1_ready,
    input  logic [P_CH*A_BIT-1:0] in1_data,
    input  logic                  in2_valid,
    output logic                  in2_ready,
    input  logic [P_CH*A_BIT-1:0] in2_data,
    output logic                  out_valid,
    input  logic                  out_ready,
    output logic [P_CH*A_BIT-1:0] out_data
);

    logic                  pipe_valid;
    logic [P_CH*A_BIT-1:0] pipe_data;
    logic                  pipe_in2_valid;
    logic [P_CH*A_BIT-1:0] pipe_in2_data;
    logic                  pipe_in1_valid;
    logic [P_CH*A_BIT-1:0] pipe_in1_data;
    logic                  handshake_in;
    logic                  handshake_out;
    logic [P_CH*A_BIT-1:0] calc_result;

    assign handshake_in  = pipe_in1_valid && pipe_in2_valid;
    assign handshake_out = !out_valid || out_ready;
    assign in1_ready     = !pipe_in1_valid || (handshake_in && handshake_out);
    assign in2_ready     = !pipe_in2_valid || (handshake_in && handshake_out);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_in1_valid <= 1'b0;
            pipe_in1_data  <= 'b0;
        end else begin
            if (in1_valid && in1_ready) begin
                pipe_in1_valid <= 1'b1;
                pipe_in1_data  <= in1_data;
            end else if (handshake_in && handshake_out) begin
                pipe_in1_valid <= 1'b0;
                pipe_in1_data  <= 'b0;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_in2_valid <= 1'b0;
            pipe_in2_data  <= 'b0;
        end else begin
            if (in2_valid && in2_ready) begin
                pipe_in2_valid <= 1'b1;
                pipe_in2_data  <= in2_data;
            end else if (handshake_in && handshake_out) begin
                pipe_in2_valid <= 1'b0;
                pipe_in2_data  <= 'b0;
            end
        end
    end

    always_comb begin
        for (int i = 0; i < P_CH; i++) begin
            logic signed [A_BIT-1:0] x1;
            logic signed [A_BIT-1:0] x2;
            logic signed [A_BIT-1:0] sum;

            x1                          = $signed(pipe_in1_data[i*A_BIT+:A_BIT]);
            x2                          = $signed(pipe_in2_data[i*A_BIT+:A_BIT]);
            sum                         = x1 + x2;

            calc_result[i*A_BIT+:A_BIT] = sum;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_valid <= 1'b0;
            pipe_data  <= 'b0;
        end else begin
            if (handshake_in) begin
                pipe_valid <= 1'b1;
                pipe_data <= calc_result;
            end else if (handshake_out) begin
                pipe_valid <= 1'b0;
                pipe_data  <= 'b0;
            end
        end
    end
    assign out_valid = pipe_valid;
    assign out_data  = pipe_data;

endmodule