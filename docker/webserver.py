if __name__ == "__main__":
    import os

    from granian import Granian
    from granian.constants import Interfaces

    server = Granian(
        target="paperless.asgi:application",
        interface=Interfaces.ASGINL,
        address=os.getenv("PAPERLESS_BIND_ADDR", "::"),
        port=int(os.getenv("PAPERLESS_PORT", 8000)),
        workers=int(os.getenv("PAPERLESS_WEBSERVER_WORKERS", 1)),
        url_path_prefix=os.getenv("PAPERLESS_FORCE_SCRIPT_NAME"),
    )

    server.serve()
