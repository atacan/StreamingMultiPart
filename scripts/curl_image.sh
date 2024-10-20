curl -v -X POST "http://127.0.0.1:8080/" \
  -H "Content-Type: image/jpeg" \
  --data-binary "@$HOME/Downloads/240432.jpg" \
  > image_httpbin.txt;
