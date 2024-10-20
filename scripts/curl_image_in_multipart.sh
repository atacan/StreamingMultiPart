#!/bin/bash

curl -v -X POST "http://127.0.0.1:8080/multifileextract" \
  -H "Content-Type: multipart/form-data" \
  -F "file=@$HOME/Downloads/240432.jpg"