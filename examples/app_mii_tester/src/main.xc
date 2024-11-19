// Copyright 2015-2021 XMOS LIMITED.
// This Software is subject to the terms of the XMOS Public Licence: Version 1.
#include <xs1.h>
#include <platform.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "mii.h"
#include "smi.h"


port p_eth_rxclk  = PORT_ETH_RXCLK;
port p_eth_rxd    = PORT_ETH_RXD;
port p_eth_txd    = PORT_ETH_TXD;
port p_eth_rxdv   = PORT_ETH_RXDV;
port p_eth_txen   = PORT_ETH_TXEN;
port p_eth_txclk  = PORT_ETH_TXCLK;
port p_eth_rxerr  = PORT_ETH_RXER;
port p_eth_dummy  = on tile[1]: XS1_PORT_8C;

clock eth_rxclk   = on tile[1]: XS1_CLKBLK_1;
clock eth_txclk   = on tile[1]: XS1_CLKBLK_2;

port p_smi_mdio   = PORT_SMI_MDIO;
port p_smi_mdc    = PORT_SMI_MDC;

uint8_t ethernet_frame[] = {
    // Destination MAC Address (6 bytes)
    0x80, 0x31, 0x76, 0x90, 0x00, 0x00,
    
    // Source MAC Address (6 bytes)
    0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC,
    
    // Type/Length (2 bytes, 0x0800 indicates IPv4)
    0x08, 0x00,
    
    // Payload/Data (minimum 46 bytes)
    0xed, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0xed, 0x99,
};

int frame_aligned[60 / 4 + 1] = {0};


void app(client interface mii_if mii)
{
  mii_info_t mii_info = mii.init();
  timer tmr;
  int send_trigger;
  tmr :> send_trigger;

  memcpy(frame_aligned, ethernet_frame, sizeof(ethernet_frame));


  while (1) {
    select {
    case mii_incoming_packet(mii_info):
        int * unsafe data = NULL;
        int nbytes;
        unsigned timestamp;
        {data, nbytes, timestamp} = mii.get_incoming_packet();
        if (data) {
           uint8_t *ptr = (uint8_t *)data;
           printf("XCORE200 Received frame: %d bytes source MAC: %x %x %x %x %x %x ED: %x\n", nbytes, ptr[6], ptr[7], ptr[8], ptr[9], ptr[10], ptr[11], ptr[14] );
        }
        mii.release_packet(data);
      break;
    case tmr when timerafter(send_trigger + XS1_TIMER_HZ/4) :> send_trigger:
        int * unsafe data = NULL;

        unsafe{data = (int * unsafe)frame_aligned;}

        int nbytes = sizeof(ethernet_frame);

        mii.send_packet(data, nbytes);
        printf("Sent packet %d bytes\n", nbytes);

        // Wait fot the packet to send.
        mii_packet_sent(mii_info);
        break;
    }
  }
}

void smi_setup(client interface smi_if i_smi){
    int phy_address = 0x00;
    while (smi_phy_is_powered_down(i_smi, phy_address));
    printf("PHY powered up\n");
    // smi_configure(i_smi, phy_address, LINK_100_MBPS_FULL_DUPLEX, SMI_DISABLE_AUTONEG);
    // printf("PHY configured\n");
}

int main()
{
  interface mii_if i_mii;
  interface smi_if i_smi;

  par {
    on tile[1]: mii(i_mii, p_eth_rxclk, p_eth_rxerr, p_eth_rxd, p_eth_rxdv, p_eth_txclk,
                    p_eth_txen, p_eth_txd, p_eth_dummy,
                    eth_rxclk, eth_txclk, 1024)
    on tile[1]: app(i_mii);
    on tile[1]: par {
        smi_setup(i_smi);
        [[distribute]]
        smi(i_smi, p_smi_mdio, p_smi_mdc);
    }
  }
  return 0;
}
