// UVM environment for the AES-128 APB peripheral (aes_apb).
//
//   apb_item        one APB transfer
//   apb_driver      drives transfers onto the bus
//   apb_monitor     rebuilds transfers from the pins, stamped with the clock count
//   apb_agent       sequencer + driver + monitor
//   aes_scoreboard  register model of the block + DPI-C AES reference; checks
//                   every read and collects functional coverage
//   aes_env         agent + scoreboard
//   sequences       known answers, random blocks, busy-window attacks, CLEAR,
//                   a register sweep for coverage closure, bus fuzz
//   tests           aes_kat_test, aes_rand_test, aes_fuzz_test, aes_full_test
//
// The scoreboard checks reads only from what the monitor saw on the pins. It
// does not look inside the DUT and it does not trust the sequences.
package aes_uvm_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import "DPI-C" function void aes128_ref(input bit [127:0] key, input bit [127:0] pt, output bit [127:0] ct);

    localparam bit [11:0] CTRL = 12'h000, STATUS = 12'h004, KEY0 = 12'h010, PT0 = 12'h020, CT0 = 12'h030;
    localparam int BUSY_CLOCKS = 10;

    // ------------------------------------------------------------------ item
    class apb_item extends uvm_sequence_item;
        rand bit          write;
        rand bit [11:0]   addr;
        rand bit [31:0]   data;       // write data
        rand int unsigned idle;       // idle clocks before the transfer
        bit [31:0]        rdata;      // read data (filled in by driver / monitor)
        int unsigned      cycle;      // clock count at the access edge (monitor)

        constraint c_idle   { idle dist {0 := 6, [1:3] := 3, [4:12] := 1}; }
        constraint c_align  { addr[1:0] == 2'b00; }

        `uvm_object_utils_begin(apb_item)
            `uvm_field_int(write, UVM_ALL_ON)
            `uvm_field_int(addr,  UVM_ALL_ON)
            `uvm_field_int(data,  UVM_ALL_ON)
            `uvm_field_int(rdata, UVM_ALL_ON)
            `uvm_field_int(cycle, UVM_ALL_ON | UVM_DEC)
        `uvm_object_utils_end

        function new(string name = "apb_item");
            super.new(name);
        endfunction
    endclass

    // Item for unstructured traffic: mostly the real registers, some unmapped
    // offsets, and CTRL writes that are mostly START with an occasional CLEAR.
    class apb_fuzz_item extends apb_item;
        rand bit [2:0] tgt;    // 0 CTRL, 1 STATUS, 2 KEY, 3 PT, 4 CT, 5 unmapped
        rand bit [1:0] cmd;    // CTRL write data: mostly START, sometimes CLEAR
        constraint c_tgt  { tgt dist { 3'd0 := 15, 3'd1 := 15, 3'd2 := 20, 3'd3 := 20, 3'd4 := 20, 3'd5 := 10 }; }
        constraint c_cmd  { cmd dist { 2'd1 := 12, 2'd2 := 1, 2'd3 := 1, 2'd0 := 1 }; }
        constraint c_addr {
            (tgt == 3'd0) -> (addr == 12'h000);
            (tgt == 3'd1) -> (addr == 12'h004);
            (tgt == 3'd2) -> (addr inside {[12'h010:12'h01c]});
            (tgt == 3'd3) -> (addr inside {[12'h020:12'h02c]});
            (tgt == 3'd4) -> (addr inside {[12'h030:12'h03c]});
            (tgt == 3'd5) -> (addr inside {12'h008, 12'h00c} || addr >= 12'h040);
        }
        constraint c_ctrl  { (tgt == 3'd0 && write) -> (data == {30'd0, cmd}); }
        // pick the register and the direction first, so every register gets its share
        constraint c_order { solve tgt before addr; solve tgt before data; solve write before data; solve cmd before data; }

        `uvm_object_utils(apb_fuzz_item)

        function new(string name = "apb_fuzz_item");
            super.new(name);
        endfunction
    endclass

    typedef uvm_sequencer #(apb_item) apb_sequencer;

    // ---------------------------------------------------------------- driver
    class apb_driver extends uvm_driver #(apb_item);
        `uvm_component_utils(apb_driver)
        virtual aes_apb_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual aes_apb_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "aes_apb_if not set for the driver")
        endfunction

        task run_phase(uvm_phase phase);
            vif.drv_cb.psel <= 1'b0; vif.drv_cb.penable <= 1'b0; vif.drv_cb.pwrite <= 1'b0;
            vif.drv_cb.paddr <= '0;  vif.drv_cb.pwdata <= '0;
            wait (vif.rst_n === 1'b1);
            @(vif.drv_cb);
            forever begin
                seq_item_port.get_next_item(req);
                repeat (req.idle) @(vif.drv_cb);
                // setup phase
                vif.drv_cb.psel    <= 1'b1;
                vif.drv_cb.penable <= 1'b0;
                vif.drv_cb.pwrite  <= req.write;
                vif.drv_cb.paddr   <= req.addr;
                vif.drv_cb.pwdata  <= req.write ? req.data : '0;
                @(vif.drv_cb);
                // access phase
                vif.drv_cb.penable <= 1'b1;
                @(vif.drv_cb);
                while (vif.drv_cb.pready !== 1'b1) @(vif.drv_cb);
                req.rdata = vif.drv_cb.prdata;
                vif.drv_cb.psel    <= 1'b0;
                vif.drv_cb.penable <= 1'b0;
                vif.drv_cb.pwrite  <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // --------------------------------------------------------------- monitor
    class apb_monitor extends uvm_monitor;
        `uvm_component_utils(apb_monitor)
        virtual aes_apb_if vif;
        uvm_analysis_port #(apb_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual aes_apb_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "aes_apb_if not set for the monitor")
        endfunction

        task run_phase(uvm_phase phase);
            apb_item it;
            forever begin
                @(vif.mon_cb);
                if (vif.rst_n === 1'b1 && vif.mon_cb.psel && vif.mon_cb.penable && vif.mon_cb.pready) begin
                    it = apb_item::type_id::create("it");
                    it.write = vif.mon_cb.pwrite;
                    it.addr  = vif.mon_cb.paddr;
                    it.data  = vif.mon_cb.pwdata;
                    it.rdata = vif.mon_cb.prdata;
                    it.cycle = vif.mon_cb.cycle;
                    ap.write(it);
                end
            end
        endtask
    endclass

    // ----------------------------------------------------------------- agent
    class apb_agent extends uvm_agent;
        `uvm_component_utils(apb_agent)
        apb_sequencer sqr;
        apb_driver    drv;
        apb_monitor   mon;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            mon = apb_monitor::type_id::create("mon", this);
            if (get_is_active() == UVM_ACTIVE) begin
                sqr = apb_sequencer::type_id::create("sqr", this);
                drv = apb_driver::type_id::create("drv", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            if (get_is_active() == UVM_ACTIVE) drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // ------------------------------------------------------------ scoreboard
    class aes_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(aes_scoreboard)
        uvm_analysis_imp #(apb_item, aes_scoreboard) imp;
        virtual aes_apb_if vif;

        // register model
        bit [127:0]  key, pt, ct_exp;
        bit          active, done, werr;
        int unsigned start_cycle;

        // bookkeeping
        int unsigned n_reads, n_writes, n_blocks, n_ct_checked, n_mismatch, n_dropped;
        bit [3:0]    ct_words_read;

        // coverage sample variables
        bit [3:0]    cv_reg;       // 0 CTRL, 1 STATUS, 2 KEY, 3 PT, 4 CT, 5 unmapped
        bit          cv_write, cv_busy, cv_done, cv_werr;
        bit [1:0]    cv_ctrl;      // CTRL write data [1:0]
        bit [1:0]    cv_keyclass, cv_ptclass;
        int unsigned cv_gap;       // clocks between a result and the next START

        covergroup cg_bus;
            option.per_instance = 1;
            cp_reg:   coverpoint cv_reg   { bins ctrl = {0}; bins status = {1}; bins key = {2}; bins pt = {3};
                                            bins ct = {4};   bins unmapped = {5}; }
            cp_write: coverpoint cv_write { bins rd = {0}; bins wr = {1}; }
            cp_busy:  coverpoint cv_busy  { bins idle = {0}; bins busy = {1}; }
            cp_done:  coverpoint cv_done;
            cp_werr:  coverpoint cv_werr;
            // every register read and written, both while idle and inside the busy window
            x_reg_rw_busy: cross cp_reg, cp_write, cp_busy;
        endgroup

        covergroup cg_ctrl;
            option.per_instance = 1;
            cp_cmd:  coverpoint cv_ctrl { bins none = {0}; bins start = {1}; bins clear = {2}; bins start_clear = {3}; }
            cp_busy: coverpoint cv_busy { bins idle = {0}; bins busy = {1}; }
            x_cmd_busy: cross cp_cmd, cp_busy;      // START and CLEAR, each when idle and when busy
        endgroup

        covergroup cg_block;
            option.per_instance = 1;
            // 0 all zeros, 1 all ones, 2 a single one bit, 3 anything else
            cp_key: coverpoint cv_keyclass { bins zeros = {0}; bins ones = {1}; bins onehot = {2}; bins other = {3}; }
            cp_pt:  coverpoint cv_ptclass  { bins zeros = {0}; bins ones = {1}; bins onehot = {2}; bins other = {3}; }
            x_key_pt: cross cp_key, cp_pt;
            cp_gap: coverpoint cv_gap { bins back_to_back = {[0:2]}; bins short_gap = {[3:20]}; bins long_gap = {[21:$]}; }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            imp = new("imp", this);
            cg_bus = new();
            cg_ctrl = new();
            cg_block = new();
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual aes_apb_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "aes_apb_if not set for the scoreboard")
        endfunction

        function void reset_model();
            key = '0; pt = '0; ct_exp = '0; active = 0; done = 0; werr = 0; ct_words_read = '0;
        endfunction

        task run_phase(uvm_phase phase);
            reset_model();
            forever begin
                @(negedge vif.rst_n);
                reset_model();
                `uvm_info("SB", "reset seen, register model cleared", UVM_MEDIUM)
            end
        endtask

        function bit [1:0] classify(bit [127:0] v);
            if (v == '0)            return 2'd0;
            if (v == '1)            return 2'd1;
            if ($countones(v) == 1) return 2'd2;
            return 2'd3;
        endfunction

        function bit [3:0] reg_class(bit [11:0] a);
            if (a[11:8] != 4'h0) return 4'd5;
            case (a[7:4])
                4'h0:    return (a[3:2] == 2'd0) ? 4'd0 : (a[3:2] == 2'd1) ? 4'd1 : 4'd5;
                4'h1:    return 4'd2;
                4'h2:    return 4'd3;
                4'h3:    return 4'd4;
                default: return 4'd5;
            endcase
        endfunction

        // Called by the monitor for every completed transfer.
        function void write(apb_item it);
            bit          busy;
            bit [31:0]   exp;
            bit [3:0]    rc;
            int          w;

            // The DUT is busy for the 10 clocks after the START write.
            if (active && (it.cycle - start_cycle) > BUSY_CLOCKS) begin
                active = 0;
                done   = 1;
                aes128_ref(key, pt, ct_exp);     // key and pt cannot have changed since START
                n_blocks++;
                ct_words_read = '0;
            end
            busy = active;
            rc   = reg_class(it.addr);
            w    = it.addr[3:2];

            cv_reg = rc; cv_write = it.write; cv_busy = busy; cv_done = done; cv_werr = werr;
            cg_bus.sample();

            if (it.write) begin
                n_writes++;
                case (rc)
                    4'd0: begin
                        cv_ctrl = it.data[1:0];
                        cg_ctrl.sample();
                        if (it.data[1]) begin
                            reset_model();                       // CLEAR wins over START
                        end else if (it.data[0]) begin
                            if (busy) begin werr = 1; n_dropped++; end
                            else begin
                                cv_keyclass = classify(key);
                                cv_ptclass  = classify(pt);
                                // clocks between the last result and this START (large if there was none)
                                cv_gap      = done ? it.cycle - (start_cycle + BUSY_CLOCKS + 1) : 1000;
                                cg_block.sample();
                                active = 1; done = 0; start_cycle = it.cycle;
                            end
                        end
                    end
                    4'd1: if (it.data[2]) werr = 0;
                    4'd2: if (busy) begin werr = 1; n_dropped++; end else key[127 - 32*w -: 32] = it.data;
                    4'd3: if (busy) begin werr = 1; n_dropped++; end else pt[127 - 32*w -: 32]  = it.data;
                    default: ;                                   // CT and unmapped: writes do nothing
                endcase
            end else begin
                n_reads++;
                case (rc)
                    4'd1:    exp = {29'd0, werr, done, busy};
                    4'd3:    exp = pt[127 - 32*w -: 32];
                    4'd4:    exp = done ? ct_exp[127 - 32*w -: 32] : 32'd0;
                    default: exp = 32'd0;                        // CTRL, KEY (write-only), unmapped
                endcase
                if (it.rdata !== exp) begin
                    n_mismatch++;
                    `uvm_error("SB", $sformatf("read addr %03h at clock %0d: got %08h, expected %08h (busy=%0b done=%0b key=%032h pt=%032h)",
                                               it.addr, it.cycle, it.rdata, exp, busy, done, key, pt))
                end else if (rc == 4'd4 && done) begin
                    ct_words_read[w] = 1'b1;
                    if (ct_words_read == 4'hF) begin n_ct_checked++; ct_words_read = '0; end
                end
            end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("%0d reads checked, %0d writes, %0d blocks encrypted, %0d full ciphertexts checked, %0d writes dropped while busy, %0d mismatches",
                                      n_reads, n_writes, n_blocks, n_ct_checked, n_dropped, n_mismatch), UVM_NONE)
            `uvm_info("SB", $sformatf("functional coverage: bus %.1f%%, ctrl %.1f%%, block %.1f%%",
                                      cg_bus.get_inst_coverage(), cg_ctrl.get_inst_coverage(), cg_block.get_inst_coverage()), UVM_NONE)
            if (n_reads == 0) `uvm_error("SB", "no reads were checked")
        endfunction
    endclass

    // ------------------------------------------------------------------- env
    class aes_env extends uvm_env;
        `uvm_component_utils(aes_env)
        apb_agent      agent;
        aes_scoreboard sb;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent = apb_agent::type_id::create("agent", this);
            sb    = aes_scoreboard::type_id::create("sb", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            super.connect_phase(phase);
            agent.mon.ap.connect(sb.imp);
        endfunction
    endclass

    // ------------------------------------------------------------- sequences
    class aes_base_seq extends uvm_sequence #(apb_item);
        `uvm_object_utils(aes_base_seq)

        function new(string name = "aes_base_seq");
            super.new(name);
        endfunction

        task wr(bit [11:0] a, bit [31:0] d, int gap = -1);
            apb_item it = apb_item::type_id::create("it");
            start_item(it);
            if (!it.randomize() with { write == 1; addr == a; data == d; if (gap >= 0) idle == gap; })
                `uvm_fatal("RAND", "apb_item randomize failed")
            finish_item(it);
        endtask

        task rd(bit [11:0] a, output bit [31:0] d, input int gap = -1);
            apb_item it = apb_item::type_id::create("it");
            start_item(it);
            if (!it.randomize() with { write == 0; addr == a; if (gap >= 0) idle == gap; })
                `uvm_fatal("RAND", "apb_item randomize failed")
            finish_item(it);
            d = it.rdata;
        endtask

        task wr128(bit [11:0] base, bit [127:0] v);
            int first = $urandom_range(0, 3);          // word order must not matter
            for (int i = 0; i < 4; i++) begin
                int w = (first + i) % 4;
                wr(base + 12'(4 * w), v[127 - 32*w -: 32]);
            end
        endtask

        task rd128(bit [11:0] base, output bit [127:0] v);
            bit [31:0] d;
            for (int w = 0; w < 4; w++) begin
                rd(base + 12'(4 * w), d);
                v[127 - 32*w -: 32] = d;
            end
        endtask

        task wait_done();
            bit [31:0] s;
            int n = 0;
            do begin rd(STATUS, s); n++; end while (!s[1] && n < 40);
            if (!s[1]) `uvm_error("SEQ", "DONE never set")
        endtask

        // key + plaintext + START + wait + read the ciphertext
        task encrypt(bit [127:0] key, bit [127:0] pt, output bit [127:0] ct, input bit write_key = 1);
            if (write_key) wr128(KEY0, key);
            wr128(PT0, pt);
            wr(CTRL, 32'h1);
            wait_done();
            rd128(CT0, ct);
        endtask
    endclass

    // Known answers from FIPS-197 and NIST SP 800-38A. The expected ciphertexts are
    // typed in here, so this test also proves the DPI reference model is right.
    class aes_kat_seq extends aes_base_seq;
        `uvm_object_utils(aes_kat_seq)

        function new(string name = "aes_kat_seq");
            super.new(name);
        endfunction

        task body();
            bit [127:0] k [7], p [7], c [7], got;
            k[0] = 128'h2b7e151628aed2a6abf7158809cf4f3c; p[0] = 128'h3243f6a8885a308d313198a2e0370734; c[0] = 128'h3925841d02dc09fbdc118597196a0b32;
            k[1] = 128'h000102030405060708090a0b0c0d0e0f; p[1] = 128'h00112233445566778899aabbccddeeff; c[1] = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
            k[2] = 128'h0;                                p[2] = 128'h0;                                c[2] = 128'h66e94bd4ef8a2c3b884cfa59ca342b2e;
            k[3] = 128'h2b7e151628aed2a6abf7158809cf4f3c; p[3] = 128'h6bc1bee22e409f96e93d7e117393172a; c[3] = 128'h3ad77bb40d7a3660a89ecaf32466ef97;
            k[4] = k[3];                                  p[4] = 128'hae2d8a571e03ac9c9eb76fac45af8e51; c[4] = 128'hf5d3d58503b9699de785895a96fdbaaf;
            k[5] = k[3];                                  p[5] = 128'h30c81c46a35ce411e5fbc1191a0a52ef; c[5] = 128'h43b1cd7f598ece23881b00e3ed030688;
            k[6] = k[3];                                  p[6] = 128'hf69f2445df4f9b17ad2b417be66c3710; c[6] = 128'h7b0c785e27e8ad3f8223207104725dd4;
            for (int i = 0; i < 7; i++) begin
                encrypt(k[i], p[i], got, (i < 4));       // blocks 4..6 reuse the key already loaded
                if (got !== c[i]) `uvm_error("KAT", $sformatf("known answer %0d: got %032h, expected %032h", i, got, c[i]))
                else              `uvm_info("KAT", $sformatf("known answer %0d ok", i), UVM_LOW)
            end
        endtask
    endclass

    // Random blocks. Keys and plaintexts are biased towards corner values, the key is
    // sometimes reused, and inside the busy window the sequence tries what an attacker
    // or a careless driver would: read the ciphertext early, read the key, overwrite the
    // key or plaintext, START again, or CLEAR.
    class aes_rand_seq extends aes_base_seq;
        `uvm_object_utils(aes_rand_seq)
        rand int unsigned n_blocks;
        constraint c_n { soft n_blocks == 500; }

        function new(string name = "aes_rand_seq");
            super.new(name);
        endfunction

        function bit [127:0] pick();
            bit [127:0] v;
            case ($urandom_range(0, 9))
                0:       v = '0;
                1:       v = '1;
                2:       v = 128'h1 << $urandom_range(0, 127);
                default: v = {$urandom(), $urandom(), $urandom(), $urandom()};
            endcase
            return v;
        endfunction

        task body();
            bit [127:0] key, pt, got;
            bit [31:0]  d;
            bit         have_key = 0;
            for (int n = 0; n < n_blocks; n++) begin
                bit new_key = !have_key || ($urandom_range(0, 3) != 0);
                if (new_key) begin key = pick(); wr128(KEY0, key); have_key = 1; end
                pt = pick();
                wr128(PT0, pt);
                if ($urandom_range(0, 9) == 0) begin rd128(KEY0, got); rd128(PT0, got); end
                wr(CTRL, 32'h1, $urandom_range(0, 12));       // also varies the gap after the last block
                case ($urandom_range(0, 7))
                    0: rd128(CT0, got);                                               // ciphertext while busy
                    1: rd128(KEY0, got);                                              // key while busy
                    2: wr(KEY0 + 12'(4 * $urandom_range(0, 3)), $urandom(), 0);       // overwrite key
                    3: wr(PT0  + 12'(4 * $urandom_range(0, 3)), $urandom(), 0);       // overwrite plaintext
                    4: wr(CTRL, 32'h1, 0);                                            // START again
                    5: if ($urandom_range(0, 3) == 0) begin                           // CLEAR mid-block
                           wr(CTRL, $urandom_range(0, 1) ? 32'h2 : 32'h3, $urandom_range(0, 6));
                           have_key = 0;
                           rd(STATUS, d); rd128(CT0, got); rd128(PT0, got);
                           continue;
                       end
                    6: repeat (3) begin                                               // any register, read or write (CTRL writes are cases 4 and 5)
                           apb_fuzz_item f = apb_fuzz_item::type_id::create("f");
                           start_item(f);
                           if (!f.randomize() with { idle == 0; !(tgt == 3'd0 && write); }) `uvm_fatal("RAND", "apb_fuzz_item randomize failed")
                           finish_item(f);
                       end
                    default: ;
                endcase
                wait_done();
                rd128(CT0, got);
                rd(STATUS, d);
                if (d[2]) wr(STATUS, 32'h4);                                          // clear WERR
                if ($urandom_range(0, 19) == 0) begin                                 // CLEAR when idle
                    wr(CTRL, 32'h2); have_key = 0;
                    rd(STATUS, d); rd128(CT0, got); rd128(PT0, got);
                end
            end
        endtask
    endclass

    // Coverage closure: read and write every register class once while idle and once
    // inside the busy window, so the register x direction x busy cross does not
    // depend on luck. The data check is still the scoreboard's.
    class aes_busy_sweep_seq extends aes_base_seq;
        `uvm_object_utils(aes_busy_sweep_seq)

        function new(string name = "aes_busy_sweep_seq");
            super.new(name);
        endfunction

        task body();
            bit [11:0]  a [6] = '{CTRL, STATUS, KEY0 + 12'h4, PT0 + 12'h8, CT0 + 12'hc, 12'h7f0};
            bit [127:0] got;
            bit [31:0]  d;
            for (int busy = 0; busy < 2; busy++)
                for (int r = 0; r < 6; r++)
                    for (int w = 0; w < 2; w++) begin
                        wr128(KEY0, {$urandom(), $urandom(), $urandom(), $urandom()});
                        wr128(PT0,  {$urandom(), $urandom(), $urandom(), $urandom()});
                        if (busy) wr(CTRL, 32'h1, 0);
                        // a CTRL write of 0 is a legal write that starts nothing
                        if (w) wr(a[r], (r == 0) ? 32'h0 : $urandom(), 0);
                        else   rd(a[r], d, 0);
                        if (!busy) wr(CTRL, 32'h1);
                        wait_done();
                        rd128(CT0, got);
                        wr(STATUS, 32'h4);
                    end
        endtask
    endclass

    // Unstructured traffic: any register, any data, any time. The scoreboard still
    // has to predict every read.
    class aes_fuzz_seq extends aes_base_seq;
        `uvm_object_utils(aes_fuzz_seq)
        rand int unsigned n_items;
        constraint c_n { soft n_items == 20000; }

        function new(string name = "aes_fuzz_seq");
            super.new(name);
        endfunction

        task body();
            apb_fuzz_item it;
            repeat (n_items) begin
                it = apb_fuzz_item::type_id::create("it");
                start_item(it);
                if (!it.randomize())
                    `uvm_fatal("RAND", "apb_fuzz_item randomize failed")
                finish_item(it);
            end
        endtask
    endclass

    // ----------------------------------------------------------------- tests
    class aes_base_test extends uvm_test;
        `uvm_component_utils(aes_base_test)
        aes_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = aes_env::type_id::create("env", this);
        endfunction

        virtual task run_seqs();
        endtask

        task run_phase(uvm_phase phase);
            phase.raise_objection(this);
            run_seqs();
            #200;
            phase.drop_objection(this);
        endtask

        function void report_phase(uvm_phase phase);
            uvm_report_server srv = uvm_report_server::get_server();
            if (srv.get_severity_count(UVM_ERROR) + srv.get_severity_count(UVM_FATAL) == 0)
                `uvm_info("TEST", $sformatf("==== %s PASSED ====", get_type_name()), UVM_NONE)
            else
                `uvm_info("TEST", $sformatf("==== %s FAILED ====", get_type_name()), UVM_NONE)
        endfunction
    endclass

    class aes_kat_test extends aes_base_test;
        `uvm_component_utils(aes_kat_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task run_seqs();
            aes_kat_seq s = aes_kat_seq::type_id::create("s");
            s.start(env.agent.sqr);
        endtask
    endclass

    class aes_rand_test extends aes_base_test;
        `uvm_component_utils(aes_rand_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task run_seqs();
            aes_rand_seq s = aes_rand_seq::type_id::create("s");
            if (!s.randomize()) `uvm_fatal("RAND", "sequence randomize failed")
            s.start(env.agent.sqr);
        endtask
    endclass

    class aes_fuzz_test extends aes_base_test;
        `uvm_component_utils(aes_fuzz_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task run_seqs();
            aes_fuzz_seq s = aes_fuzz_seq::type_id::create("s");
            if (!s.randomize()) `uvm_fatal("RAND", "sequence randomize failed")
            s.start(env.agent.sqr);
        endtask
    endclass

    // Everything, in one run: this is the regression test.
    class aes_full_test extends aes_base_test;
        `uvm_component_utils(aes_full_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task run_seqs();
            aes_kat_seq  k = aes_kat_seq::type_id::create("k");
            aes_rand_seq r = aes_rand_seq::type_id::create("r");
            aes_fuzz_seq f = aes_fuzz_seq::type_id::create("f");
            aes_busy_sweep_seq b = aes_busy_sweep_seq::type_id::create("b");
            k.start(env.agent.sqr);
            b.start(env.agent.sqr);
            if (!r.randomize()) `uvm_fatal("RAND", "sequence randomize failed")
            r.start(env.agent.sqr);
            if (!f.randomize()) `uvm_fatal("RAND", "sequence randomize failed")
            f.start(env.agent.sqr);
            k.start(env.agent.sqr);          // known answers again after the fuzzing
        endtask
    endclass
endpackage
