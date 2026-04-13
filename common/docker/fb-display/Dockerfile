FROM python:3.14-slim

WORKDIR /app

# Install font for text rendering
RUN apt-get update && apt-get install -y --no-install-recommends \
    fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies (pip avoids ghcr.io/astral-sh/uv TLS flakiness on self-hosted runner)
RUN pip install --no-cache-dir Pillow websockets requests numpy zeroconf

RUN groupadd -r -g 1000 app && useradd -r -u 1000 -g app -d /app -s /sbin/nologin app

# Copy renderer and assets
COPY --chown=1000:1000 fb_display.py logo.png snapforge-text.png /app/
RUN chmod +x /app/fb_display.py

USER app

CMD ["python3", "/app/fb_display.py"]
