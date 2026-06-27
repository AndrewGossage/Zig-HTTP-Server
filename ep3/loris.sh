#!/bin/sh 
# Open a socket and send a partial request, hold it open
for i in $(seq 1 100); do
  (printf "GET / HTTP/1.1\r\nHost: localhost\r\n"; sleep 300) | nc localhost 8090 &
done
