module conv #(
    parameter int unsigned P_ICH      = 4,//并行输入通道数
    parameter int unsigned P_OCH      = 4,//并行输出通道数
    parameter int unsigned N_ICH      = 16,//输入通道数
    parameter int unsigned N_OCH      = 16,//输出通道数
    parameter int unsigned K          = 3,//卷积核
    parameter int unsigned A_BIT      = 8,//元素位宽
    parameter int unsigned W_BIT      = 8,//权重位宽
    parameter int unsigned B_BIT      = 32,//累加器位宽
    parameter int unsigned N_HW       = 64,//输出特征图H*W
    parameter string       W_FILE     = "",
    parameter              W_ROM_TYPE = "block"
) (
    input  logic                   clk,
    input  logic                   rst_n,
    input  logic [P_ICH*A_BIT-1:0] in_data,
    input  logic                   in_valid,
    output logic                   in_ready,
    output logic [P_OCH*B_BIT-1:0] out_data,
    output logic                   out_valid,
    input  logic                   out_ready
);

    localparam int unsigned FOLD_I = N_ICH / P_ICH;
    localparam int unsigned FOLD_O = N_OCH / P_OCH;
    localparam int unsigned KK = K * K;
    localparam int unsigned WEIGHT_DEPTH = FOLD_O * FOLD_I * KK;
    localparam int unsigned LB_DEPTH = FOLD_I * KK;
    localparam int unsigned LB_AWIDTH = $clog2(LB_DEPTH);

    logic signed [               B_BIT-1:0] acc                   [  P_OCH];
    logic        [      $clog2(N_HW+1)-1:0] cntr_hw;
    logic        [      $clog2(P_ICH+1)-1:0] mac_array_vld_cnt;
    logic        [    $clog2(FOLD_O+1)-1:0] cntr_fo;
    logic        [    $clog2(FOLD_I+1)-1:0] cntr_fi;
    logic        [        $clog2(KK+1)-1:0] cntr_kk;
    logic                                   pipe_en;
    logic                                   pipe_en_in;
    logic                                   pipe_en_out;
    logic                                   is_fst_fo;
    logic                                   mac_array_data_vld;
    logic                                   mac_array_ready;
    logic                                   mac_array_en;
    logic        [         P_ICH*A_BIT-1:0] in_buf;
    logic        [         P_ICH*A_BIT-1:0] in_data_d1;
    logic                                   is_fst_kk_fi;
    logic                                   is_lst_kk_fi;
    logic                                   is_lst_kk_fi_d1;
    logic                                   is_fst_kk_fi_d1;
    logic                                   line_buffer_we;
    logic        [           LB_AWIDTH-1:0] line_buffer_waddr;
    logic        [         P_ICH*A_BIT-1:0] line_buffer_wdata;
    logic                                   line_buffer_re;
    logic        [           LB_AWIDTH-1:0] line_buffer_raddr;
    logic        [         P_ICH*A_BIT-1:0] line_buffer_rdata;
    logic        [$clog2(WEIGHT_DEPTH)-1:0] weight_addr;
    logic        [   P_OCH*P_ICH*W_BIT-1:0] weight_data;
    logic                                   is_fst_fo_d1; 

    rom #(
        .DWIDTH(P_OCH * P_ICH * W_BIT),
        .AWIDTH($clog2(WEIGHT_DEPTH)),
        .MEM_SIZE(WEIGHT_DEPTH),
        .INIT_FILE(W_FILE),
        .ROM_TYPE(W_ROM_TYPE)
    ) u_weight_rom (
        .clk  (clk),
        .ce0  (pipe_en),
        .addr0(weight_addr),
        .q0   (weight_data)
    );

    ram #(
        .DWIDTH(P_ICH * A_BIT),
        .AWIDTH(LB_AWIDTH),
        .MEM_SIZE(LB_DEPTH),
        .RAM_STYLE("ultra")
    ) u_line_buffer (
        .clk  (clk),
        .we   (line_buffer_we),
        .waddr(line_buffer_waddr),
        .wdata(line_buffer_wdata),
        .re   (line_buffer_re),
        .raddr(line_buffer_raddr),
        .rdata(line_buffer_rdata)
    );

    assign is_fst_fo            = (cntr_fo == 0); //第一个输出通道
    assign is_fst_kk_fi         = (cntr_kk == 0) && (cntr_fi == 0); //第一个输入通道的第一个元素  
    assign is_lst_kk_fi         = (cntr_kk == KK - 1) && (cntr_fi == FOLD_I - 1) && pipe_en; //最后一个输入通道的最后一个元素
    assign pipe_en_in           = is_fst_fo ? in_valid : 1'b1; //第一个输出通道的数据来自外部输入，其它输出通道的数据从line buffer获取
    assign pipe_en_out          = !mac_array_data_vld || (mac_array_data_vld && mac_array_ready && mac_array_vld_cnt==P_ICH-1); //下级流水线ready
    assign pipe_en              = pipe_en_in && pipe_en_out; //输入数据握手成功
    assign in_ready             = is_fst_fo && pipe_en_out;  //第一个输出通道且下级流水线ready
    assign weight_addr          = (cntr_fo * KK * FOLD_I) + cntr_fi * KK + cntr_kk; //计算权重地址
    assign line_buffer_we       = is_fst_fo && pipe_en; //第一个输出通道使用的输入数据写入line buffer保存
    assign line_buffer_waddr    = cntr_fi * KK + cntr_kk; //写地址
    assign line_buffer_wdata    = in_data; //输入数据
    assign line_buffer_re       = pipe_en && !is_fst_fo; // 除第一输出通道外，其余输出通道从line buffer中读取数据
    assign line_buffer_raddr    = cntr_fi * KK + cntr_kk; //读地址


    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cntr_hw <= 0;
            cntr_fo <= 0;
            cntr_fi <= 0;
            cntr_kk <= 0;
        end else if (pipe_en) begin
            if (cntr_kk == KK - 1) begin
                cntr_kk <= 0;
                if (cntr_fi == FOLD_I - 1) begin
                    cntr_fi <= 0;
                    if (cntr_fo == FOLD_O - 1) begin
                        cntr_fo <= 0;
                        if (cntr_hw == N_HW-1) begin
                            cntr_hw <= 0;
                        end else begin
                            cntr_hw <= cntr_hw + 1;
                        end
                    end else begin
                        cntr_fo <= cntr_fo + 1;
                    end
                end else begin
                    cntr_fi <= cntr_fi + 1;
                end
            end else begin
                cntr_kk <= cntr_kk + 1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            is_fst_fo_d1 <= 1'b0;
            in_data_d1   <= 'b0;
        end else if(pipe_en)begin
            is_fst_fo_d1 <= is_fst_fo;
            in_data_d1   <= in_data;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_array_data_vld <= 1'b0;
        end else if(pipe_en)begin
            mac_array_data_vld <= 1'b1;
        end else if(mac_array_data_vld && mac_array_ready && mac_array_vld_cnt== P_ICH-1)
            mac_array_data_vld <= 1'b0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mac_array_vld_cnt <= 'b0;
        end else if(mac_array_data_vld && mac_array_ready && mac_array_vld_cnt==P_ICH-1)begin
            mac_array_vld_cnt <= 'b0;
        end else if(mac_array_data_vld && mac_array_ready)
            mac_array_vld_cnt <= mac_array_vld_cnt + 'b1;
    end

    assign mac_array_ready = !out_valid || out_ready;
    assign mac_array_en    = mac_array_data_vld && mac_array_ready  && mac_array_vld_cnt==P_ICH-1;

    assign in_buf = is_fst_fo_d1 ? in_data_d1 : line_buffer_rdata;

    logic        [A_BIT-1:0] x_vec[P_ICH];
    logic signed [W_BIT-1:0] w_vec[P_OCH] [P_ICH];
    always_comb begin
        for (int i = 0; i < P_ICH; i++) begin
            x_vec[i] = in_buf[i*A_BIT+:A_BIT];
        end
    end

    always_comb begin
        for (int o = 0; o < P_OCH; o++) begin
            for (int i = 0; i < P_ICH; i++) begin
                w_vec[o][i] = weight_data[(P_ICH*o+i)*W_BIT+:W_BIT];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            is_fst_kk_fi_d1 <= 1'b0;
            is_lst_kk_fi_d1 <= 1'b0;
        end else if(pipe_en) begin
            is_fst_kk_fi_d1 <= is_fst_kk_fi;
            is_lst_kk_fi_d1 <= is_lst_kk_fi;
        end else if(mac_array_en) begin
            is_fst_kk_fi_d1 <= 1'b0;
        end else if(out_valid && out_ready) begin
            is_lst_kk_fi_d1 <= 1'b0;
        end
    end

    generate
        for (genvar o = 0; o < P_OCH; o++) begin : gen_mac_array
            conv_mac_array #(
                .P_ICH(P_ICH),
                .A_BIT(A_BIT),
                .W_BIT(W_BIT),
                .B_BIT(B_BIT)
            ) u_mac_array (
                .clk    (clk),
                .rst_n  (rst_n),
                .en     (mac_array_en),
                .dat_vld(mac_array_data_vld),
                .clr    (is_fst_kk_fi_d1),
                .x_vec  (x_vec),
                .w_vec  (w_vec[o]),
                .acc    (acc[o])
            );
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid       <= 1'b0;
        end else if(is_lst_kk_fi_d1 && mac_array_data_vld && mac_array_ready && mac_array_vld_cnt==P_ICH-1) begin
            out_valid       <= 1'b1;
        end else if(out_valid && out_ready) begin
            out_valid       <= 1'b0;
        end
    end

    always_comb begin
        for (int o = 0; o < P_OCH; o++) begin
            out_data[o*B_BIT+:B_BIT] = acc[o];
        end
    end
endmodule
