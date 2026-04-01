#!/bin/bash
for _ in 1 2 3; do
  wget -q -O /dev/null http://localhost/ && exit 0
  sleep 2
done
exit 1
