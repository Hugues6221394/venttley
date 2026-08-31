FROM python:3.11-slim
WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Fetch the ONNX weights at build time, and do it BEFORE copying the source.
#
# Two reasons, both learned the hard way:
#   * Without baking them in, the first request after a cold start also pays
#     for a model download, which outlasts media-scan's timeout and quarantines
#     an image that was never a problem.
#   * Docker invalidates every layer after a changed one, so with app.py copied
#     first, editing a single line of Python re-downloads the whole model.
RUN python -c "from nudenet import NudeDetector; NudeDetector()"

COPY app.py .

# Not root. This service accepts arbitrary bytes from the internet and hands
# them to an image decoder, which is exactly the shape of thing that should not
# be running as uid 0.
RUN useradd -m app && chown -R app:app /app
USER app

EXPOSE 8090
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8090"]
