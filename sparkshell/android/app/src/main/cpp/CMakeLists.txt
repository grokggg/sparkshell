cmake_minimum_required(VERSION 3.22.1)
project(ptybridge C)

add_library(ptybridge SHARED pty_bridge.c)

find_library(log-lib log)
target_link_libraries(ptybridge ${log-lib})
