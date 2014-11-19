#ifndef __ethernet_routing_h__
#define __ethernet_routing_h__
#include <ethernet.h>

#ifndef ETHERNET_MAX_MACADDR_FILTERS
#define ETHERNET_MAX_MACADDR_FILTERS (10)
#endif

#define ETHERNET_MACADDR_FILTER_TABLE_SIZE 10

typedef struct eth_global_filter_entry_t {
  uint16_t vlan;
  char addr[6];
  unsigned result;
  unsigned appdata;
} eth_global_filter_entry_t;

typedef eth_global_filter_entry_t eth_global_filter_info_t[ETHERNET_MACADDR_FILTER_TABLE_SIZE];

void ethernet_init_filter_table(eth_global_filter_info_t table);

ethernet_macaddr_filter_result_t
ethernet_add_filter_table_entry(eth_global_filter_info_t table,
                                 unsigned client_id,
                                 ethernet_macaddr_filter_t entry);

void ethernet_del_filter_table_entry(eth_global_filter_info_t table,
                                     unsigned client_id,
                                     ethernet_macaddr_filter_t entry);

void ethernet_clear_filter_table(eth_global_filter_info_t table,
                                 unsigned client_id);

unsigned ethernet_do_filtering(eth_global_filter_info_t table,
                               char buf[packet_size],
                               size_t packet_size,
                               unsigned &appdata);


#ifndef ETHERNET_MAX_ETHERTYPE_FILTERS
#define ETHERNET_MAX_ETHERTYPE_FILTERS 2
#endif

#endif // __ethernet_routing_h__
