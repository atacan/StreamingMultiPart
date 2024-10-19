#!/bin/bash

# Function to run a single curl request
run_curl() {
  curl -s "http://127.0.0.1:8080/" \
    -H "Content-Type: image/jpeg" \
    --data-binary "@$HOME/Downloads/100MB.bin" > /dev/null 2>&1
}

# Array to store background process IDs
pids=()

# Start curl requests in the background
for i in {1..3}
do
  run_curl &
  pids+=($!)
done

# Wait for all background processes to finish
for pid in "${pids[@]}"
do
  wait $pid
done

echo "All curl requests completed."
