// Copyright 2013-2021 XMOS LIMITED.
// This Software is subject to the terms of the XMOS Public Licence: Version 1.
#include "mii_master.h"
#include <xs1.h>
#include <xclib.h>
#include <print.h>
#include <stdlib.h>
#include <syscall.h>
#include <stdio.h>
#include <xclib.h>
#include <hwtimer.h>
#include "mii_buffering.h"
#include "debug_print.h"
#include "default_ethernet_conf.h"
#include "mii_common_lld.h"
#include "string.h"

#define QUOTEAUX(x) #x
#define QUOTE(x) QUOTEAUX(x)

// As of the v12/13 xTIMEcomper tools. The compiler schedules code around a
// bit too much which violates the timing constraints. This change to the
// crc32 makes it a barrier to scheduling. This is not really
// recommended practice since it inhibits the compiler in a bit of a hacky way,
// but is perfectly safe.
#undef crc32
#define crc32(a, b, c) {__builtin_crc32(a, b, c); asm volatile (""::"r"(a):"memory");}


#ifndef ETHERNET_ENABLE_FULL_TIMINGS
#define ETHERNET_ENABLE_FULL_TIMINGS (1)
#endif

// Timing tuning constants
#define PAD_DELAY_RECEIVE    0
#define PAD_DELAY_TRANSMIT   0
#define CLK_DELAY_RECEIVE    3 // works 0..6
#define CLK_DELAY_TRANSMIT   0
// After-init delay (used at the end of mii_init)
#define PHY_INIT_DELAY 10000000

// The inter-frame gap is 96 bit times (1 clock tick at 100Mb/s). However,
// the EOF time stamp is taken when the last but one word goes into the
// transfer register, so that leaves 96 bits of data still to be sent
// on the wire (shift register word, transfer register word, crc word).
// In the case of a non word-aligned transfer compensation is made for
// that in the code at runtime.
// The adjustment is due to the fact that the instruction
// that reads the timer is the next instruction after the out at the
// end of the packet and the timer wait is an instruction before the
// out of the pre-amble
#define MII_ETHERNET_IFS_AS_REF_CLOCK_COUNT  (96 + 96 - 9)



void rmii_master_init(port p_rxclk, in buffered port:32 p_rxd, in port p_rxdv,
                     in port p_txclk, out port p_txen, out buffered port:32 p_txd,
                     clock phy_clk, in buffered port:1 p_rxer, clock clk_rx)
{
  // p_rxclk :> int x;
  set_port_use_on(p_rxd);
  set_port_use_on(p_rxdv);

  set_port_strobed(p_rxd);
  set_port_slave(p_rxd);

  set_clock_on(clk_rx);
  set_clock_src(clk_rx, p_txclk); // Note tx clock!!
  set_clock_ready_src(clk_rx, p_rxdv);
  set_port_clock(p_rxd, clk_rx);
  set_port_clock(p_rxdv, clk_rx);

  // Output Rx clock to check it's chooching
  // set_port_use_on(p_rxclk);
  // set_port_clock(p_rxclk, clk_rx);
  // set_port_mode_clock(p_rxclk);

  // Do timing stuff
  set_clock_rise_delay(clk_rx, CLK_DELAY_RECEIVE);
  set_clock_fall_delay(clk_rx, CLK_DELAY_RECEIVE);
  set_port_sample_delay(p_rxd);
  set_port_sample_delay(p_rxdv);


  start_clock(clk_rx);

  clearbuf(p_rxd);

  /////////////// TX //////////////

  // set_port_use_on(p_txclk);
  set_port_use_on(p_txd);
  set_port_use_on(p_txen);
  //  set_port_use_on(p_txer);

  set_pad_delay(p_txclk, PAD_DELAY_TRANSMIT);

  p_txd <: 0;
  p_txen <: 0;
  //  p_txer <: 0;
  sync(p_txd);
  sync(p_txen);
  //  sync(p_txer);

  set_port_strobed(p_txd);
  set_port_master(p_txd);
  clearbuf(p_txd);

  set_port_ready_src(p_txen, p_txd);
  set_port_mode_ready(p_txen);

  // set_clock_on(clk_tx);
  // set_clock_src(clk_tx, p_txclk);
  set_port_clock(p_txd, phy_clk);
  set_port_clock(p_txen, phy_clk);

  // set_clock_fall_delay(clk_tx, CLK_DELAY_TRANSMIT);

  start_clock(phy_clk);

  clearbuf(p_txd);
  printf("Tx init fin\n");

}

unsafe void rmii_master_rx_pins(unsigned *buff,
                               in port p_mii_rxdv,
                               in buffered port:32 p_mii_rxd,
                               in buffered port:1 p_mii_rxer,
                               unsigned &crc, int &num_rx_bytes)
{
    timer tmr;

    /* Make sure we do not start in the middle of a packet */
    p_mii_rxdv when pinseq(0) :> int lo;


    /* Discount the CRC word */
    num_rx_bytes = -4;

    crc = 0x9226F562;
    unsigned poly = 0xEDB88320;

    /* Enable interrupts as the rx_err port is configured to raise an interrupt
     * that logs the error and continues. */
    asm("setsr 0x2");

    /* Wait for the start of the packet and timestamp it */
    unsigned preamble[3]; //3 because we will lose some due to crd_dv early

    // First 4 bytes of preamble
    uint32_t word, word2;
    p_mii_rxd :> word;
    p_mii_rxd :> word2;
    {word2, word} = unzip((uint64_t)word| ((uint64_t)word2 << 32), 1); // Lower crumb
    preamble[0] = word;

    // Find out how many bits late the data was - we know TXD0 is 1 for the preamble
    unsigned crs_dv_early = clz(bitrev(word));

    // Second 4 bytes of preamble
    p_mii_rxd :> word;
    p_mii_rxd :> word2;
    {word2, word} = unzip((uint64_t)word| ((uint64_t)word2 << 32), 1); // Lower crumb

    preamble[1] = word;

    word = partin(p_mii_rxd, crs_dv_early << 1);
    word2 = 0;
    {word2, word} = unzip((uint64_t)word| ((uint64_t)word2 << 32), 1); // Lower crumb
    preamble[2] = word;

    // CUrrently discard the preamble

    if (((preamble[1] >> 24) & 0xFF) != 0xD5) {
      /* Corrupt the CRC so that the packet is discarded */
      // crc = ~crc;
    }

    /* Timestamp the start of packet and record it in the packet structure */
    unsigned time;
    tmr :> time;
    // buf->timestamp = time;

    unsigned end_of_frame = 0;

    do {
     select
       {
       case p_mii_rxd :> word:
         p_mii_rxd :> word2;
         {word2, word} = unzip((uint64_t)word| ((uint64_t)word2 << 32), 1); // Lower crumb

         crc32(crc, word, poly);

         *buff = word;
         buff++;
       
         num_rx_bytes += 4;
         break;

       case p_mii_rxdv when pinseq(0) :> int:
         end_of_frame = 1;
         // printf("EOF\n");
         break;
      }
    } while (!end_of_frame);

    /* Clear interrupts used by rx_err port handler */
    asm("clrsr 0x2");

    /* If the rx_err port detects an error then drop the packet */
    // if (*error_ptr) {
    //   endin(p_mii_rxd);
    //   p_mii_rxd :> void;
    //   *error_ptr = 0;
    //   continue;
    // }

    /* Note: we don't store the last word since it contains the CRC and
     * we don't need it from this point on. */

    unsigned taillen = endin(p_mii_rxd) * 2;
    printf("Tail: %u\n", taillen);

    unsigned tail;
    p_mii_rxd :> word;
    p_mii_rxd :> word2;
    {word2, word} = unzip((uint64_t)word| ((uint64_t)word2 << 32), 1); // Lower crumb
    tail = word;

    if (taillen & ~0x7) {
      #pragma xta label "mii_rx_no_tail"

      num_rx_bytes += (taillen>>3);

      /* Ensure that the mask is byte-aligned */
      unsigned mask = ~0U >> (taillen & ~0x7);

      /* Correct for non byte-aligned frames */
      tail <<= taillen & 0x7;

      /* Mask out junk bits in last input */
      tail &= ~mask;

      /* Incorporate tailbits of input data,
       * see https://github.com/xcore/doc_tips_and_tricks for details. */
      { tail, crc } = mac(crc, mask, tail, crc);
      crc32(crc, tail, poly);
    }


    printf("crs_dv_early: %u, preamble [0,1,2]: 0x%x 0x%x 0x%x\n", crs_dv_early >> 1, preamble[0], preamble[1], preamble[2]);

    //TMP as we are not consuming the buffer properly
    clearbuf(p_mii_rxd);

  return;
}


////////////////////////////////// TRANSMIT ////////////////////////////////


static inline void tx_crumb(uint32_t word, out buffered port:32 p_txd){
    uint64_t zipped = zip(0, word, 1); // Lower crumb, port bits 0, 1
    // uint64_t zipped = zip(word, 0, 1); // Upper crumb, port bits 2,
    p_txd <: zipped & 0xffffffff;
    p_txd <: zipped >> 32;
}

static inline void tx_crumb_8(uint32_t word, out buffered port:32 p_txd){
    uint64_t zipped = zip(0, word, 1); // Lower crumb, port bits 0, 1
    // uint64_t zipped = zip(word, 0, 1); // Upper crumb, port bits 2,
    partout(p_txd, 16, zipped & 0x0000ffff);
}



#undef crc32
#define crc32(a, b, c) {__builtin_crc32(a, b, c);}

#ifndef MII_TX_TIMESTAMP_END_OF_PACKET
#define MII_TX_TIMESTAMP_END_OF_PACKET (0)
#endif

 unsigned rmii_transmit_packet(unsigned *buff, unsigned num_bytes,
                                    out buffered port:32 p_mii_txd,
                                    hwtimer_t ifg_tmr, unsigned &ifg_time)
{

unsafe{

  unsigned time;
  register const unsigned poly = 0xEDB88320;
  unsigned int crc = 0;
  unsigned * unsafe dptr = buff;
  int i=0;
  int word_count = num_bytes >> 2;
  int tail_byte_count = num_bytes & 3;
  // printf("word_count: %d tail_byte_count: %d\n", word_count, tail_byte_count);
 
  // Check that we are out of the inter-frame gap
  asm volatile ("in %0, res[%1]"
                  : "=r" (ifg_time)
                  : "r" (ifg_tmr));

  tx_crumb(0x55555555, p_mii_txd);
  tx_crumb(0xD5555555, p_mii_txd);

  // if (!MII_TX_TIMESTAMP_END_OF_PACKET && buf->timestamp_id) {
    ifg_tmr :> time;
  // }

  unsigned word = *dptr;
  tx_crumb(*dptr, p_mii_txd);
  dptr++;
  i++;
  crc32(crc, ~word, poly);

  do {
    // printf("%d\n", i);
    unsigned word = *dptr;
    dptr++;
    i++;

    crc32(crc, word, poly);

    tx_crumb(word, p_mii_txd);
    ifg_tmr :> ifg_time;
  } while (i < word_count);

  // if (MII_TX_TIMESTAMP_END_OF_PACKET && buf->timestamp_id) {
    ifg_tmr :> time;
  // }

  if (tail_byte_count) {
    unsigned word = *dptr;
    switch (tail_byte_count)
      {
      default:
        __builtin_unreachable();
        break;
#pragma fallthrough
      case 3:
        tx_crumb_8(word, p_mii_txd);
        word = crc8shr(crc, word, poly);
#pragma fallthrough
      case 2:
        tx_crumb_8(word, p_mii_txd);
        word = crc8shr(crc, word, poly);
      case 1:
        tx_crumb_8(word, p_mii_txd);
        crc8shr(crc, word, poly);
        break;
      }
  }
  crc32(crc, ~0, poly);
  tx_crumb(crc, p_mii_txd);
  return time;
}
}
