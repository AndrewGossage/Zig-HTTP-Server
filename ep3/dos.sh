#!/bin/sh 
# sudo ip addr add 127.0.0.2/32 dev lo
while true; do
    (printf "GET / HTTP/1.1\r\nHost: localhost\r\n"; sleep 300) | ncat --source 127.0.0.2 localhost 8090 &
done
