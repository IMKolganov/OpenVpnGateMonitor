```
docker compose -f docker-compose-local.yml --env-file .env.dev.x64 build --no-cache
docker compose -f docker-compose-local.yml --env-file .env.dev.x64 up -d
```