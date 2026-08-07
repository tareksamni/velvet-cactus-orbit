# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Two stages so build tooling never reaches the runtime image.
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS builder

WORKDIR /build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1

COPY requirements.txt .
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt


FROM python:3.12-slim AS runtime

# Non-root from the start; the chart also enforces runAsNonRoot.
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY --chown=app:app . /app

# Drop test-only material from the runtime image.
#
# The chown matters: WORKDIR creates /app as root before COPY runs, and
# `COPY --chown` only sets ownership on the copied contents, not on the
# directory itself. Without this the runtime user can read /app but not write
# to it, which breaks any file sync into the container during development.
# In production the root filesystem is read-only anyway, so this changes
# nothing there.
RUN rm -rf /app/tests /app/requirements-dev.txt \
 && chown app:app /app

USER app
EXPOSE 8000

# Liveness is also enforced by the Kubernetes probe; this makes `docker run`
# behave sensibly on its own.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2).status == 200 else 1)"

# Workers are overridden by the chart via APP_ env/args where needed.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2", "--no-server-header"]
