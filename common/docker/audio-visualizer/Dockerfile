FROM python:3.14-slim

WORKDIR /app

# ALSA library for loopback capture
RUN apt-get update && apt-get install -y --no-install-recommends \
    libasound2 \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies (pip avoids ghcr.io/astral-sh/uv TLS flakiness on self-hosted runner)
RUN pip install --no-cache-dir numpy websockets

RUN groupadd -r -g 1000 app && useradd -r -u 1000 -g app -d /app -s /sbin/nologin app

COPY --chown=1000:1000 visualizer.py /app/
RUN chmod +x /app/visualizer.py

USER app

CMD ["python3", "/app/visualizer.py"]
