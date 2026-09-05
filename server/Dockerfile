# Node's built-in SQLite driver means there is no native module to compile,
# so the image stays small and the build never breaks on a toolchain.

FROM node:24-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:24-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist

# Overridden by fly.toml, but keeps `docker run` working on its own.
ENV PORT=8080
ENV DATABASE_PATH=/data/app.db
EXPOSE 8080

# Runs as root deliberately: the Fly volume at /data is mounted root-owned,
# and this container holds nothing else worth isolating from.
CMD ["node", "--env-file-if-exists=.env", "dist/index.js"]
