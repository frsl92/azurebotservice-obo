FROM python:3.12-slim AS build
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy PIP_DISABLE_PIP_VERSION_CHECK=1
RUN pip install --no-cache-dir uv --index-url https://pkgs.dev.azure.com/ms-feed-12/1es-public/_packaging/pypi-public/pypi/simple/
WORKDIR /app
COPY pyproject.toml uv.lock ./
COPY bot ./bot
COPY mcp_server ./mcp_server
RUN uv sync --frozen --no-dev --no-editable --package obo-mcp-server

FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PATH="/app/.venv/bin:$PATH" PORT=8000
RUN useradd --system --uid 10001 app
WORKDIR /app
COPY --from=build /app/.venv /app/.venv
USER app
EXPOSE 8000
CMD ["python", "-m", "mcp_server.server"]
