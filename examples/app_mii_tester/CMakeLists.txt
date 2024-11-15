cmake_minimum_required(VERSION 3.21)
include($ENV{XMOS_CMAKE_PATH}/xcommon.cmake)
project(app_mii_tester)

set(APP_HW_TARGET           SLICEKIT-ETH-TRIANGLE1.xn)

include(${CMAKE_CURRENT_LIST_DIR}/../deps.cmake)

set(APP_PCA_ENABLE          ON)

set(COMPILER_FLAGS_COMMON   -g
                            -report
                            -DDEBUG_PRINT_ENABLE
                            -DRGMII=0)

set(APP_COMPILER_FLAGS      ${COMPILER_FLAGS_COMMON})

set(XMOS_SANDBOX_DIR        ${CMAKE_CURRENT_LIST_DIR}/../../..)

XMOS_REGISTER_APP()
