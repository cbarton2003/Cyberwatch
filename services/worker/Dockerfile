FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

FROM node:20-alpine AS production
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY src/ ./src/
COPY package.json ./
RUN chown -R appuser:appgroup /app
USER appuser
ENV NODE_ENV=production
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD node -e "const r=require('ioredis');const c=new r({host:process.env.REDIS_HOST||'localhost',lazyConnect:true});c.connect().then(()=>c.ping()).then(()=>{c.disconnect();process.exit(0)}).catch(()=>process.exit(1))"
CMD ["node", "src/index.js"]
