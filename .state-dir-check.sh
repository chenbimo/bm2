#!/bin/bash
set -e
export PATH="$HOME/.moon/bin:$PATH"
cd /mnt/c/codes/bm2
moon fmt
moon check --target native --deny-warn
