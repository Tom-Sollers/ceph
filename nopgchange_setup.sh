#!/bin/bash
MDS=0 MON=1 OSD=6 MGR=1 ../src/vstart.sh --debug --new -x --localhost -o timeout=10000 -o session_timeout=10000 -o debug_osd=20 -o osd_pool_default_flag_ec_optimizations=true -o osd_op_complaint_time=5
source ./vstart_environment.sh 
ceph osd set-require-min-compat-client umbrella
ceph osd pool set noautoscale
