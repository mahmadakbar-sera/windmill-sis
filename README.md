# Windmill: scheduler SIS

Windmill (self-hosted, Community Edition) menjalankan job terjadwal SIS dengan memanggil endpoint `/internal/...` milik service. Di IA Claim · 11 §5 peran ini dipegang **EventBridge + AWS Step Functions**; keputusan 13 Nov 2026: **Windmill dipakai di dev dan nantinya prod**. Service tidak tahu siapa pemanggilnya, karena kontraknya hanya `POST` + `x-api-key`.

| Job | Script | Schedule | Endpoint |
| --- | --- | --- | --- |
| API-CL-34 Job Outstanding | `f/sis/claim_outstanding_job` | `f/sis/claim_outstanding_hourly`: `0 5 * * * *` (detik menit jam …), Asia/Jakarta | `POST {claim-service}/internal/v1/claims/jobs/outstanding` |

## Isi folder

| File | Fungsi |
| --- | --- |
| `docker-compose.yml` | Postgres Windmill, server (UI/API, port 8000), 1 worker. Worker ikut `sera-sis-network` agar bisa memanggil `claim-service:3003`. |
| `.env.example` → `.env` | Versi image, port, kredensial admin, URL claim-service, API key internal, `SCHEDULE_ENABLED`. `.env` tidak di-commit. |
| `f/sis/claim_outstanding_job.ts` | Script (Bun). Sumber kebenaran: edit di sini lalu jalankan `setup.sh` lagi, bukan edit di UI. |
| `setup.sh` | Provisioning lewat REST API Windmill (idempoten): workspace `sis`, folder, variable, script, schedule. |

## Setup dev

1. Jalankan stack utama dulu (`docker compose up -d` di root SIS), karena network `sera-sis-network` dibuat di sana.
2. `cp windmill/.env.example windmill/.env`, lalu isi `CLAIM_INTERNAL_API_KEY` dengan nilai yang **sama** dengan `INTERNAL_API_KEY` di `SERA_SIS_ClaimService/.env` (misalnya `openssl rand -hex 32`, isi di kedua file).
3. `docker compose -f windmill/docker-compose.yml --env-file windmill/.env up -d`
4. Tunggu `http://localhost:8000` siap, lalu `./windmill/setup.sh`.
5. Login UI `admin@windmill.dev` / `changeme`, buka workspace **sis**, lalu **ganti password admin**.
6. Uji: buka script `f/sis/claim_outstanding_job` → **Test** / **Run**. Untuk uji terbatas isi argumen **`limit`** (mis. `100`, maks 1000): script memanggil sekali dengan `?limit=` dan memindahkan paling banyak sebanyak itu. Kosongkan untuk run penuh. Setelah hasilnya benar, aktifkan schedule (UI → Schedules, atau `SCHEDULE_ENABLED=true ./windmill/setup.sh`).

**Windmill di server** (sudah terpasang, workspace kosong): buat `windmill/.env.server` dari `.env.example`, isi `WM_URL` server, `WM_TOKEN` (UI → Settings → Tokens) atau email/password, `CLAIM_SERVICE_BASE_URL` yang bisa dijangkau worker server, dan `CLAIM_INTERNAL_API_KEY` = `INTERNAL_API_KEY` claim-service di server tersebut. Lalu `./windmill/setup.sh windmill/.env.server`. File `.env.*` tidak di-commit.

> ⚠️ Claim-service dev memakai **database dev bersama**. Menjalankan job berarti memindahkan klaim dev yang memenuhi syarat ke Outstanding dan mengirim notifikasi `CLAIM_OUTSTANDING` ke user PIC Email. Karena itu schedule dibuat **nonaktif** secara default.

## Perilaku script (pengganti state machine Step Functions)

```
limit diisi → 1 panggilan ?limit=N, tanpa loop
limit kosong → loop maks 10:
  POST /internal/v1/claims/jobs/outstanding (x-api-key, timeout 45 detik)
    200           → catat hasil; hasMore ? lanjut : selesai
    409 JOB_RUNNING → selesai (run lain masih jalan), tidak retry
    401/4xx lain  → gagal (key salah, perlu diperbaiki)
    5xx / network → retry 2x, jeda 30 detik, lalu gagal
```

Job yang gagal tercatat merah di **Runs** Windmill. Hasil yang sukses berisi `processed/updated/skipped/failed/hasMore` dan `transactionId` per panggilan, sama dengan `transactionId` baris Audit Trail di claim-service.

## Menuju prod (yang perlu disiapkan DevOps)

| Hal | Dev (sekarang) | Prod (usulan) |
| --- | --- | --- |
| Image | `main` | Pin rilis (`WM_VERSION=1.xxx.x`) |
| Postgres Windmill | Container | DB terkelola (RDS) terpisah dari DB SIS |
| Akses ke service | Network docker `claim-service:3003` | Jaringan privat ke ClaimService. Bila lewat API Gateway, timeout 29 detik (endpoint dibatasi 25 detik) |
| API key | `.env` | Config Vault (KMS `INTERNAL_API_KEY`), disalin ke variable secret Windmill, dirotasi bersama |
| Alert gagal | Lihat Runs | Error handler schedule/workspace ke Slack/email (pengganti CloudWatch alarm) |
| Admin | `admin@windmill.dev` | SSO/akun per orang, password default dihapus |
| Deploy script | `setup.sh` | `setup.sh` di pipeline CI, atau `wmill sync push` |
