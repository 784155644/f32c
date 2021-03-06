--
-- Copyright (c) 2018 Felix Vietmeyer
-- All rights reserved.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions
-- are met:
-- 1. Redistributions of source code must retain the above copyright
--    notice, this list of conditions and the following disclaimer.
-- 2. Redistributions in binary form must reproduce the above copyright
--    notice, this list of conditions and the following disclaimer in the
--    documentation and/or other materials provided with the distribution.
--
-- THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
-- ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
-- IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
-- ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
-- FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
-- DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
-- OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
-- HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
-- LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
-- OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
-- SUCH DAMAGE.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.MATH_REAL.ALL; -- floor(), log2()

library unisim;
use unisim.vcomponents.all;

use work.f32c_pack.all;

entity papilio_xram_sdram is
  generic
  (
    -- ISA: either ARCH_MI32 or ARCH_RV32
    C_arch                      : integer := ARCH_MI32;
    C_debug                     : boolean := false;

    -- Main clock: 99.2 MHz
    C_clk_freq                  : integer := 99;
    C_vendor_specific_startup   : boolean := false -- false: disabled (xilinx startup doesn't work reliable on this board - check this)
  );
  port
  (
    clk_crystal                 : in    std_logic;

    tx                          : out   std_logic;
    rx                          : in    std_logic;

    spi_sck                     : out   std_logic;
    spi_ss                      : out   std_logic;
    spi_mosi                    : out   std_logic;
    spi_miso                    : in    std_logic;

    flash_ck                    : out   std_logic;
    flash_cs                    : out   std_logic;
    flash_si                    : out   std_logic;
    flash_so                    : in    std_logic;

    --user LED on Papilio
    led1                        : out   std_logic;
    --0-7 simple_in 8-15 simple_out for Papilio pins
    port_a                      : inout std_logic_vector(15 downto 0);
    --GPIO
    port_b                      : inout std_logic_vector(15 downto 0);
    port_c                      : inout std_logic_vector(11 downto 0);

    --SDRAM
    sdram_addr                  : out   std_logic_vector(12 downto 0);
    sdram_data                  : inout std_logic_vector(15 downto 0);
    sdram_ba                    : out   std_logic_vector(1 downto 0);
    sdram_dqm                   : out   std_logic_vector(1 downto 0);
    sdram_nras                  : out   std_logic;
    sdram_ncas                  : out   std_logic;
    sdram_clk                   : out   std_logic;
    sdram_cke                   : out   std_logic;
    sdram_nwe                   : out   std_logic;
    sdram_cs                    : out   std_logic
  );
end;

architecture Behavioral of papilio_xram_sdram is
  signal clk_cpu     : std_logic;
  signal clk_pixel: std_logic; -- 25 MHz
  signal clk_pixel_shift_p: std_logic; -- 125 MHz
  signal clk_pixel_shift_n: std_logic; -- 125 MHz inverted (180 deg phase)
  signal clk_locked: std_logic;
  signal sdram_clk_internal: std_logic;
  signal rs232_break : std_logic;
  signal dvid_red, dvid_green, dvid_blue, dvid_clock: std_logic_vector(1 downto 0);
  signal tmds_out_crgb: std_logic_vector(3 downto 0);
begin
  -- clock synthesizer: Xilinx Spartan-6 specific
  clk100: if C_clk_freq = 99 generate
    clkgen: entity work.xil_pll
      generic map(
        clk_in_period_ns    => 31.250,  --32 MHz
        clk_mult            => 31,      --fVCO = 992 MHz
        clk_div0            => 10,      --  99.2 Mhz
        clk_phase0          => 0.0,
        clk_div1            => 40,      --  24.8 MHz
        clk_phase1          => 0.0,
        clk_div2            => 8,       -- 124.0 MHz
        clk_phase2          => 0.0
      )
      port map(
        clk_in              => clk_crystal,
        clk_out0            => clk_cpu,
        clk_out1            => clk_pixel,
        clk_out2            => clk_pixel_shift_p
      );
    clk_pixel_shift_n <= not clk_pixel_shift_p;
  end generate;

  G_vendor_specific_startup: if C_vendor_specific_startup generate
  -- reset hard-block: Xilinx Spartan-6 specific
  reset: startup_spartan6
    port map
    (
      clk       => clk_cpu,
      gsr       => rs232_break,
      gts       => rs232_break,
      keyclearb => '0'
    );
  end generate; -- G_vendor_specific_startup

  -- generic XRAM glue, listing options for clarity
  glue_xram: entity work.glue_xram
  generic map (
    --options configured in top
    C_arch                      => C_arch,
    C_debug                     => C_debug,
    C_clk_freq                  => C_clk_freq,

    --parameters we fix for this example
    C_bram_size                 => 4, -- KB, from 2/4/8K choose which one synthesizes best

    C_sio                       => 1,
    C_spi                       => 2,
    C_boot_spi                  => true,
    C_gpio                      => 32,

    C_boot_write_protect        => false,
    C_icache_size               => 2,
    C_dcache_size               => 2,
    C_cached_addr_bits          => 23, -- 2^23 bytes = 8 MB onboard SDRAM

    C_timer                     => true,
    C_timer_ocp_mux             => false,
    C_timer_ocps                => 2,
    C_timer_icps                => 2,

    C_sdram                     => true,
    C_sdram_clock_range         => 2,
    C_sdram_address_width       => 22,
    C_sdram_column_bits         => 8,
    C_sdram_startup_cycles      => 10100,
    C_sdram_cycles_per_refresh  => 1524,

    C_vgahdmi                   => true,
    C_dvid_ddr                  => true,

    --these settings reflext default settings in glue_xram
    -- ISA options
    C_big_endian                => false,
    C_mult_enable               => true,
    C_mul_acc                   => false,
    C_mul_reg                   => false,
    C_branch_likely             => true,
    C_sign_extend               => true,
    C_ll_sc                     => false,
    C_PC_mask                   => x"ffffffff",
    C_exceptions                => true,

    -- COP0 options
    C_cop0_count                => true,
    C_cop0_compare              => true,
    C_cop0_config               => true,

    -- CPU core configuration options
    C_branch_prediction         => true,
    C_full_shifter              => true,
    C_result_forwarding         => true,
    C_load_aligner              => true,
    C_regfile_synchronous_read  => false,
    -- Negatively influences timing closure, hence disabled
    C_movn_movz                 => false,

    -- SoC configuration options
    C_bram_const_init           => true,
    C_xram_base                 => X"8", -- SDRAM mapping at 0x80000000

    C_sio_init_baudrate         => 115200,
    C_sio_fixed_baudrate        => false,
    C_sio_break_detect          => true,

    C_spi_turbo_mode            => "0000",
    C_spi_fixed_speed           => "1111",

    C_simple_in                 => 32,
    C_simple_out                => 32,

    --these settings turn off unused features in glue_xram
    C_xdma                      => false,
    C_sram                      => false,
    C_acram                     => false,
    C_axiram                    => false,
    C_tv                        => false,
    C_ledstrip                  => false,
    C_vgatext                   => false,
    C_pcm                       => false,
    C_synth                     => false,
    C_spdif                     => false,
    C_cw_simple_out             => -1,
    C_fmrds                     => false,
    C_gpio_adc                  => 0,
    C_pids                      => 0,
    C_vector                    => false
  )
  port map(
    clk                         => clk_cpu,
    clk_pixel                   => clk_pixel, -- pixel clock
    clk_pixel_shift             => clk_pixel_shift_p, -- tmds clock 10x pixel clock for SDR or 5x for DDR
    sio_txd(0)                  => tx,
    sio_rxd(0)                  => rx,
    sio_break(0)                => rs232_break,
    reset                       => rs232_break,
    spi_sck(0)  => flash_ck,  spi_sck(1)  => spi_sck,
    spi_ss(0)   => flash_cs,  spi_ss(1)   => spi_ss,
    spi_mosi(0) => flash_si,  spi_mosi(1) => spi_mosi,
    spi_miso(0) => flash_so,  spi_miso(1) => spi_miso,
    simple_in(31 downto 8)      => (others => '0'),
    simple_in(7 downto 4)       => port_a(7 downto 4),
    simple_in(3 downto 0)       => (others => '0'),
    simple_out(31 downto 9)     => open,
    simple_out(8 downto 1)      => port_a(15 downto 8),
    simple_out(0)               => led1,
    gpio(127 downto 28)         => open,
    gpio(27 downto 16)          => port_c,
    gpio(15 downto 12)          => open,
    gpio(11 downto 0)           => port_b(11 downto 0),
    -- digital video
    dvid_clock => dvid_clock,
    dvid_red   => dvid_red,
    dvid_green => dvid_green,
    dvid_blue  => dvid_blue,
    -- sdram
    sdram_addr                  => sdram_addr,
    sdram_data(31 downto 16)    => open,
    sdram_data(15 downto 0)     => sdram_data,
    sdram_ba                    => sdram_ba,
    sdram_dqm(3 downto 2)       => open,
    sdram_dqm(1 downto 0)       => sdram_dqm,
    sdram_ras                   => sdram_nras,
    sdram_cas                   => sdram_ncas,
    sdram_cke                   => sdram_cke,
    sdram_clk                   => sdram_clk_internal,
    sdram_we                    => sdram_nwe,
    sdram_cs                    => sdram_cs
  );

  -- SDRAM clock output needs special routing on Spartan-6
  sdram_clk_forward : ODDR2
      generic map
      (
        DDR_ALIGNMENT => "NONE", INIT => '0', SRTYPE => "SYNC"
      )
      port map
      (
        Q => sdram_clk, C0 => clk_cpu, C1 => sdram_clk_internal, CE => '1',
        R => '0', S => '0', D0 => '0', D1 => '1'
      );

  -- vendor specific modules to
  -- convert 2-bit pairs to DDR 1-bit
  G_vga_ddrout0: entity work.ddr_dvid_out_se
  port map
  (
    clk       => clk_pixel_shift_p,
    clk_n     => clk_pixel_shift_n,
    reset     => '0',
    in_clock  => dvid_clock,
    in_red    => dvid_red,
    in_green  => dvid_green,
    in_blue   => dvid_blue,
    out_clock => tmds_out_crgb(3),
    out_red   => tmds_out_crgb(2),
    out_green => tmds_out_crgb(1),
    out_blue  => tmds_out_crgb(0)
  );

  -- differential output buffering for HDMI clock and video
  hdmi_output0: entity work.hdmi_out
  port map
  (
    tmds_in_clk    => tmds_out_crgb(3),
    tmds_out_clk_p => port_a(3),
    tmds_out_clk_n => port_b(12),
    tmds_in_rgb    => tmds_out_crgb(2 downto 0),
    tmds_out_rgb_p(2) => port_a(0),
    tmds_out_rgb_p(1) => port_a(1),
    tmds_out_rgb_p(0) => port_a(2),
    tmds_out_rgb_n(2) => port_b(15),
    tmds_out_rgb_n(1) => port_b(14),
    tmds_out_rgb_n(0) => port_b(13)
  );

end Behavioral;
