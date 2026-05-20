FROM node:22.22.2-slim

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY app.js .

EXPOSE 8000
CMD ["node", "app.js"]
