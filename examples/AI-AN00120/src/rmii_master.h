// Copyright 2013-2021 XMOS LIMITED.
// This Software is subject to the terms of the XMOS Public Licence: Version 1.
#ifndef __mii_master_h__
#define __mii_master_h__
#include "mii_buffering.h"
#include "mii_ts_queue.h"
#include "server_state.h"
#include <hwtimer.h>

#ifdef __XC__

void rmii_master_init(port p_rxclk, in buffered port:32 p_rxd, in port p_rxdv,
                     in port p_txclk, out port p_txen, out buffered port:32 p_txd,
                     clock phy_clk, in buffered port:1 p_rxer, clock clk_rx);

unsafe void rmii_master_rx_pins(unsigned *buff,
                               in port p_mii_rxdv,
                               in buffered port:32 p_mii_rxd,
                               in buffered port:1 p_mii_rxer,
                               unsigned &crc, int &num_rx_bytes);

 unsigned rmii_transmit_packet(unsigned *buff, unsigned num_bytes,
                                    out buffered port:32 p_mii_txd,
                                    hwtimer_t ifg_tmr, unsigned &ifg_time);


#endif

#endif // __mii_master_h__
