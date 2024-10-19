# Stream Request Body to another service as a MultiPart Form Request 

## Use Case

Our server is receiving a large media file in the request body and we want to send it to a third party service. 
This service expects a multi-part form request. 

We don't want to collect the file into server's memory. That's why we want to stream this multi-part data to the third party service.

For illustartion, we make the request to `httpbin.org/post` or some local server that does nothing.

See [Application+build](Sources/App/Application+build.swift)

## Issues

Observing the memory consumption on the Xcode debug navigator, we see very large spikes in memory although we create an AsyncStream for the third-party API request body.


https://github.com/user-attachments/assets/bea19d1b-1c9d-4637-bab0-577dba7476c7

<sub>Spike is around 00:06</sub>

The server starts with 10MB. With incoming requests it spikes to 2-4GB. After the requests are finished the new baseline becomes 70MB.

## Reproduce

Send thirty 100MB files concurrently.

For example 
- download `100MB.bin` file from https://ash-speed.hetzner.com to the `~/Downloads` folder
- run the script

```bash
chmod +x ./scripts/curl_concurrent.sh
./scripts/curl_concurrent.sh
``` 
