// Copyright 2014-2021 XMOS LIMITED.
// This Software is subject to the terms of the XMOS Public Licence: Version 1.
#include <xs1.h>
#include <platform.h>
#include <stdio.h>
#include <stdint.h>
#include <debug_print.h>
#include <string.h>
#include "mii.h"
#include "smi.h"
#include "rmii_master.h"

#define RMII    1

#if RMII
out buffered port:32    p_eth_txd    = on tile[1]: XS1_PORT_4A; // J10 - 02 03 08, CODEC_RST_N
in buffered port:32     p_eth_rxd    = on tile[1]: XS1_PORT_4B; // J10 - 04 05 06 07
in buffered port:1      p_eth_rxerr  = on tile[1]: XS1_PORT_1C; // BCLK

#else
port p_eth_txd    = on tile[1]: XS1_PORT_4A; // J10 - 02 03 08, CODEC_RST_N
port p_eth_rxd    = on tile[1]: XS1_PORT_4B; // J10 - 04 05 06 07
port p_eth_rxerr  = on tile[1]: XS1_PORT_1C; // BCLK

#endif
port p_eth_rxdv   = on tile[1]: XS1_PORT_1A; // DAC
port p_eth_txen   = on tile[1]: XS1_PORT_1B; // LRCLK
port p_eth_txclk  = on tile[1]: XS1_PORT_1O; // J10 - 38
port p_eth_rxclk  = on tile[1]: XS1_PORT_1M; // J10 - 36
port p_eth_dummy  = on tile[1]: XS1_PORT_8C; // Internal port not pinned out

clock eth_rxclk   = on tile[1]: XS1_CLKBLK_1;
clock eth_txclk   = on tile[1]: XS1_CLKBLK_2;

port p_smi_mdio   = on tile[0]: XS1_PORT_1O; // SDATA
port p_smi_mdc    = on tile[0]: XS1_PORT_1N; // SCL
port p_phy_rst    = on tile[0]: XS1_PORT_4C; // J11 - 14, Also LEDS

port p_clkin      = on tile[1]: XS1_PORT_1D; // MCLK
clock clk_clkin   = on tile[1]: XS1_CLKBLK_3;



uint8_t ethernet_frame[] = {
    // Destination MAC Address (6 bytes)
    0x80, 0x31, 0x76, 0x90, 0x00, 0x00,
    
    // Source MAC Address (6 bytes)
    0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC,
    
    // Type/Length (2 bytes, 0x0800 indicates IPv4)
    0x08, 0x00,
    
    // Payload/Data (minimum 46 bytes)
    0xed, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xff, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff, 0x00,
    0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0, 0xf0,
    0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb, 0xbb,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0xed
};

unsigned frame_aligned[60 / 4] = {0};

#define outport(c, x)   asm ("out res[%0], %1" :: "r" (c), "r" (x))

void phy_reset(void){
    p_phy_rst <: 0;
    delay_microseconds(200);
    p_phy_rst <: 0x1;
    printf("Reset released\n");
}

void init_eth_clock_and_mode_pins(void){
#if RMII
    unsigned rxd_mode_pin = 0x77777777; // PHY_AD2 = 0, RMMI = 1, MODE1 = 1, MODE0 = 1
    // asm ("out res[%0], %1" :: "r" (p_eth_rxd) : "r" rxd_mode_pin);
    outport(p_eth_rxd, rxd_mode_pin);
    printf("Set mode pins for RMII\n");
    configure_clock_ref(clk_clkin, (2 / 2)); // 100 / 2 = 50 MHz
    printf("Clock init'd 50MHz\n");
#else
    configure_clock_ref(clk_clkin, (4 / 2)); // 100 / 4 = 25 MHz
    printf("Clock init'd 25MHz\n");
#endif
    set_port_clock(p_clkin, clk_clkin);
    set_port_mode_clock(p_clkin);
    start_clock(clk_clkin);

    delay_microseconds(300);
    p_eth_rxd :> int _; // Hi z


}

void app(client interface mii_if mii)
{
#if RMII
  rmii_master_init(p_eth_rxclk, p_eth_rxd, p_eth_rxdv, p_eth_txclk, p_eth_txen, p_eth_txd, clk_clkin, p_eth_rxerr);
#else
  mii_info_t mii_info = mii.init();
#endif
  timer tmr;
  int send_trigger;
  tmr :> send_trigger;

  memcpy(frame_aligned, ethernet_frame, sizeof(ethernet_frame));

#if RMII
    while(1){
        unsafe{
            hwtimer_t ifg_tmr;
            unsigned ifg_time = 96;
            rmii_transmit_packet(frame_aligned, sizeof(ethernet_frame), p_eth_txd, ifg_tmr, ifg_time);
        }
        delay_seconds(1);
    }

#else

  while (1) {
    select {
    case mii_incoming_packet(mii_info):
        int * unsafe data = NULL;
        int nbytes;
        unsigned timestamp;
        {data, nbytes, timestamp} = mii.get_incoming_packet();
        if (data) {
            uint8_t *ptr = (uint8_t *)data;
            printf("XCOREAI Received frame: %d bytes source MAC: %x %x %x %x %x %x ED: %x\n", nbytes, ptr[6], ptr[7], ptr[8], ptr[9], ptr[10], ptr[11], ptr[14] );
        }
        mii.release_packet(data);
      break;
    case 1 => tmr when timerafter(send_trigger + XS1_TIMER_HZ) :> send_trigger:
        int * unsafe data = NULL;

        unsafe{data = (int * unsafe)frame_aligned;}

        int nbytes = sizeof(ethernet_frame);

        mii.send_packet(data, nbytes);
        printf("Sent packet %d bytes \n", nbytes);

        // Wait fot the packet to send.
        mii_packet_sent(mii_info);
        break;
    }
  }
#endif
}

[[combinable]]
void lan8710a_phy_driver(client interface smi_if smi,
                         client interface ethernet_cfg_if eth) {

  ethernet_link_state_t link_state = ETHERNET_LINK_DOWN;
  ethernet_speed_t link_speed = LINK_100_MBPS_FULL_DUPLEX;
  const int link_poll_period_ms = 1000;
  const int phy_address = 0x0;
  timer tmr;
  int t;
  tmr :> t;

  printf("Waiting for PHY\n");

  while (smi_phy_is_powered_down(smi, phy_address));

  printf("PHY powered up\n");

  // printf("BASIC_CONTROL_REG init: 0x%x\n", smi.read_reg(phy_address, BASIC_CONTROL_REG));
  // smi.write_reg(phy_address, BASIC_CONTROL_REG, 0xb1000000000000000); // Soft reset, use reg values
  // delay_milliseconds(500);
  // printf("BASIC_CONTROL_REG post reset: 0x%x\n", smi.read_reg(phy_address, BASIC_CONTROL_REG));

  #if RMII
    unsigned special_modes = smi.read_reg(phy_address, SPECIAL_MODES_REGISTER);
    printf("SPECIAL_MODES_REGISTER: 0x%x\n", special_modes);
    special_modes |= (1 << MIIMODE_CONTROL_BIT);
    smi.write_reg(phy_address, SPECIAL_MODES_REGISTER, special_modes);
    special_modes = smi.read_reg(phy_address, SPECIAL_MODES_REGISTER);
    printf("SPECIAL_MODES_REGISTER: 0x%x\n", special_modes);
  #endif

  smi_configure(smi, phy_address, LINK_100_MBPS_FULL_DUPLEX, SMI_ENABLE_AUTONEG);

  // unsigned basic_ctrl = smi.read_reg(phy_address, BASIC_CONTROL_REG);
  // printf("BASIC_CONTROL_REG pre: 0x%x\n", basic_ctrl);
  // basic_ctrl |= 0b0010000100000000; // Force 100M, full duplex
  // basic_ctrl &= 0b1110111111111111; // Disable autoneg
  // printf("basic_ctrl: 0x%x\n", basic_ctrl);
  // smi.write_reg(phy_address, BASIC_CONTROL_REG, basic_ctrl); // Force 100M normal operation full Duplex
  // delay_microseconds(1000);

  printf("BASIC_CONTROL_REG post: 0x%x\n", smi.read_reg(phy_address, BASIC_CONTROL_REG));
  printf("BASIC_STATUS: 0x%x\n", smi.read_reg(phy_address, BASIC_STATUS_REG));


  printf("PHY configured\n");
  while(1);

  while (1) {
    select {
    case tmr when timerafter(t) :> t:
      ethernet_link_state_t new_state = smi_get_link_state(smi, phy_address);
      // Read LAN8710A status register bit 2 to get the current link speed
      if ((new_state == ETHERNET_LINK_UP) &&
         ((smi.read_reg(phy_address, 0x1F) >> 2) & 1)) {
        link_speed = LINK_10_MBPS_FULL_DUPLEX;
      }
      else {
        link_speed = LINK_100_MBPS_FULL_DUPLEX;
      }
      if (new_state != link_state) {
        link_state = new_state;
        printf("State: %s speed: %s\n", link_state == ETHERNET_LINK_UP ? "UP" : "DOWN", link_speed == LINK_100_MBPS_FULL_DUPLEX ? "100" : "10");
        // eth.set_link_state(0, new_state, link_speed);
      }
      t += link_poll_period_ms * XS1_TIMER_KHZ;
      break;
    }
  }
}

int main()
{
    interface mii_if i_mii;
    smi_if i_smi;
    ethernet_cfg_if i_cfg;

    par{
        on tile[1]: {
            init_eth_clock_and_mode_pins();

            par{
#if !RMII
                mii(i_mii, p_eth_rxclk, p_eth_rxerr, p_eth_rxd, p_eth_rxdv, p_eth_txclk,
                        p_eth_txen, p_eth_txd, p_eth_dummy,
                        eth_rxclk, eth_txclk, 1024);
#endif
                app(i_mii);
            }
        }
        on tile[0]: {
            phy_reset();

            par{
                smi(i_smi, p_smi_mdio, p_smi_mdc);
                lan8710a_phy_driver(i_smi, i_cfg);
            }
        }
    }
  return 0;
}
