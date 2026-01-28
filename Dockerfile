# syntax=docker/dockerfile:1

############################
# Stage 1: Build frontend
############################
FROM node:20-slim AS build
WORKDIR /app

ENV NODE_OPTIONS="--max-old-space-size=4096"

# Install dependencies
COPY package.json package-lock.json ./
RUN npm ci

# Copy source
COPY . .

# Build frontend
RUN npm run build

############################
# Stage 2: Runtime
############################
FROM python:3.11-slim AS final
WORKDIR /app

# System deps
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Copy backend and built frontend
COPY --from=build /app/backend /app/backend
COPY --from=build /app/build /app/build

ENV PYTHONPATH="/app/backend:${PYTHONPATH}"

# Install python deps
COPY backend/requirements.txt /app/backend/requirements.txt
RUN pip install --no-cache-dir -r /app/backend/requirements.txt \
    uvicorn sqlalchemy pydantic-settings

EXPOSE 8080

WORKDIR /app/backend
CMD ["python", "-m", "open_webui.main", "--host", "0.0.0.0", "--port", "8080"]
