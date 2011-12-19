// Copyright (c) 2011, XMOS Ltd, All rights reserved
// This software is freely distributable under a derivative of the
// University of Illinois/NCSA Open Source License posted in
// LICENSE.txt and at <http://github.xcore.com/>

#include <platform.h>
#include "uip_server.h"
#include "xhttpd.h"
#include "miiSingleServer.h"

#define PORT_ETH_FAKE    XS1_PORT_8C

#define PORT_ETH_RST_N_MDIO  XS1_PORT_1P

on stdcore[1]: mii_interface_t mii =
  {
    XS1_CLKBLK_1,
    XS1_CLKBLK_2,

    PORT_ETH_RXCLK,
    PORT_ETH_RXER,
    PORT_ETH_RXD,
    PORT_ETH_RXDV,

    PORT_ETH_TXCLK,
    PORT_ETH_TXEN,
    PORT_ETH_TXD,

    PORT_ETH_FAKE,
  };

#ifdef PORT_ETH_RST_N
on stdcore[1]: out port p_mii_resetn = PORT_ETH_RST_N;
on stdcore[1]: smi_interface_t smi = { PORT_ETH_MDIO, PORT_ETH_MDC, 0 };
#else
on stdcore[1]: smi_interface_t smi = { PORT_ETH_RST_N_MDIO, PORT_ETH_MDC, 1 };
#endif

on stdcore[1]: clock clk_smi = XS1_CLKBLK_5;



// IP Config - change this to suit your network.  Leave with all
// 0 values to use DHCP
xtcp_ipconfig_t ipconfig = {
		{ 169, 254, 13, 15 }, // ip address (eg 192,168,0,2)
		{ 255, 255, 0, 0 }, // netmask (eg 255,255,255,0)
		{ 169, 254, 11, 11 } // gateway (eg 192,168,0,1)
};

// Program entry point
int main(void) {
	chan mac_rx[1], mac_tx[1], xtcp[1], connect_status;

	par
	{
	 	on stdcore[1]: miiSingleServer(clk_smi, null, smi, mii,
                                       mac_rx[0], mac_tx[0], connect_status);

		// The TCP/IP server thread
		on stdcore[1]: uip_server(mac_rx[0], mac_tx[0],
				xtcp, 1, ipconfig,
				connect_status);

		// The webserver thread
		on stdcore[1]: xhttpd(xtcp[0]);

	}
	return 0;
}