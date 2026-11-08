FROM node:24.15.0-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
COPY apps/backend/package.json apps/backend/
COPY packages/game-contracts/package.json packages/game-contracts/
COPY packages/game-content/package.json packages/game-content/
RUN --mount=type=cache,target=/root/.npm npm ci --ignore-scripts --no-audit --no-fund --prefer-offline --maxsockets=4 --fetch-retries=3
COPY apps/backend/tsconfig.json apps/backend/
COPY apps/backend/src apps/backend/src
COPY packages/game-contracts/schemas packages/game-contracts/schemas
COPY packages/game-contracts/generated packages/game-contracts/generated
RUN npm run build --workspace @partybox/backend && npm prune --omit=dev --ignore-scripts --no-audit --no-fund

FROM node:24.15.0-bookworm-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production HOST=0.0.0.0 PORT=3000
COPY --from=build --chown=node:node /app/node_modules node_modules
COPY --from=build /app/package.json ./
COPY --from=build /app/apps/backend/package.json apps/backend/
COPY --from=build /app/apps/backend/dist apps/backend/dist
COPY --from=build /app/packages/game-contracts packages/game-contracts
COPY packages/game-content/package.json packages/game-content/
COPY packages/game-content/packs packages/game-content/packs
COPY apps/backend/migrations apps/backend/migrations
COPY deploy/entrypoint.mjs deploy/entrypoint.mjs
USER node
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=5s --start-period=15s --retries=3 CMD ["node", "-e", "fetch('http://127.0.0.1:3000/ready').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
ENTRYPOINT ["node", "deploy/entrypoint.mjs"]
