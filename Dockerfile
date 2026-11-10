FROM node:22-alpine
WORKDIR /app
COPY --chown=node:node server.js index.html ./
USER node
EXPOSE 3000
CMD ["node", "server.js"]
