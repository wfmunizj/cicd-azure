import os

from fastapi import FastAPI

VERSION = os.getenv("APP_VERSION", "local")
COLOR = os.getenv("APP_COLOR", "local")

app = FastAPI(title="app-teste", version=VERSION)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/")
def root():
    return {"app": "app-teste-v3 teste", "versao": VERSION, "cor": COLOR}
