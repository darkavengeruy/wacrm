# syntax=docker/dockerfile:1

# ============================================================
# wacrm — production image for EasyPanel (Next.js 16 standalone)
# ============================================================
# Multi-stage build:
#   deps    → install npm dependencies (cached layer)
#   builder → next build → .next/standalone
#   runner  → minimal runtime image, non-root, ~150 MB
# ============================================================

# ---- 1. Dependencies ----------------------------------------
FROM node:22-alpine AS deps
WORKDIR /app

# libc6-compat: some Node native addons expect glibc symbols on Alpine.
RUN apk add --no-cache libc6-compat

# Install against the lockfile only — copying just these two files keeps
# this layer cached until dependencies actually change.
COPY package.json package-lock.json ./
RUN npm ci

# ---- 2. Build ------------------------------------------------
FROM node:22-alpine AS builder
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY . .

# NEXT_PUBLIC_* values are inlined into the client bundle at BUILD time,
# so they must be present here (not just at runtime). EasyPanel passes
# these via "Build Args". Server-only secrets (service role key, etc.)
# are read at runtime and do NOT belong here.
ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY
ARG NEXT_PUBLIC_SITE_URL
ENV NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL
ENV NEXT_PUBLIC_SUPABASE_ANON_KEY=$NEXT_PUBLIC_SUPABASE_ANON_KEY
ENV NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL

ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# ---- 3. Runtime ----------------------------------------------
FROM node:22-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

# Run as an unprivileged user.
RUN addgroup --system --gid 1001 nodejs \
  && adduser --system --uid 1001 nextjs

# The standalone server plus the assets it does not bundle itself:
#   public/            static files served at the site root
#   .next/static/      hashed JS/CSS chunks
COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs
EXPOSE 3000

CMD ["node", "server.js"]
