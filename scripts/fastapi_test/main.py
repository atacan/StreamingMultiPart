# Run
# uvicorn main:app --host 0.0.0.0 --port 80

from fastapi import FastAPI
import asyncio

app = FastAPI()


@app.post("/")
async def root():
    # await asyncio.sleep(1)

    return {"message": "Hello World"}
