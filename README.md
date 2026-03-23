# HimRate

Twitch audience analytics platform — Chrome Extension + Rails API.
Bot detection, Trust Index, ERV% (Estimated Real Viewers).

## Stack

- **Backend:** Ruby 3.3 + Rails 8 + PostgreSQL 16 + Redis 7 + Sidekiq 7
- **Frontend:** Chrome Extension MV3 + React + TypeScript
- **Deploy:** Docker + Kamal → VPS (staging + production)
- **CI:** GitHub Actions (rubocop + rspec + brakeman)

## Local Development

```bash
# 1. Clone
git clone git@github.com:himratesdev/himrate-platform.git
cd himrate-platform

# 2. Environment
cp .env.example .env

# 3. Start all services
docker compose up

# 4. Verify
curl http://localhost:3000/health
# → {"status":"ok","db":true,"redis":true}
```

## Running Tests

```bash
docker compose run web bundle exec rspec
docker compose run web bundle exec rubocop
```

## Deployment

Managed by Kamal. CI/CD via GitHub Actions.

```bash
# Staging (auto on merge to main)
kamal deploy -d staging

# Production (manual, via git tag)
git tag v1.0.0
git push origin v1.0.0
# → GitHub Actions deploys to production
```

## Environments

| Env | URL | Deploy |
|-----|-----|--------|
| Local | localhost:3000 | docker compose up |
| Staging | staging.himrate.com | auto on merge to main |
| Production | api.himrate.com | git tag v*.*.* |
