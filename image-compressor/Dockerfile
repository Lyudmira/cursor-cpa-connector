FROM node:24-alpine3.22
WORKDIR /app
COPY . .
ENV PORT=47822
USER node
EXPOSE 47822
HEALTHCHECK --interval=15s --timeout=3s --retries=3 CMD wget -q -O /dev/null http://127.0.0.1:47822/health || exit 1
CMD ["node", "server.mjs"]
