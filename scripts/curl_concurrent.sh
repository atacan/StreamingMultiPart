#!/bin/bash

# Function to run a single curl request and print errors
run_curl() {
  local output
  output=$(curl -s -S "http://127.0.0.1:8080/new" \
    -H "Content-Type: image/jpeg" \
    --data-binary "@$HOME/Downloads/100MB.bin" 2>&1)
  
  if [ $? -ne 0 ]; then
    echo "Error in curl request: $output" >&2
  fi
}

# Array to store background process IDs
pids=()

# Start curl requests in the background
for i in {1..50}
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
