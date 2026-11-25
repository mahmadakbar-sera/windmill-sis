# Windmill: scheduler SIS

Windmill (self-hosted, Community Edition) menjalankan job terjadwal SIS dengan memanggil endpoint `/internal/...` milik service. Di IA Claim · 11 §5 peran ini dipegang **EventBridge + AWS Step Functions**; keputusan 13 Nov 2026: **Windmill dipakai di dev dan nantinya prod**. Service tidak tahu siapa pemanggilnya, karena kontraknya hanya `POST` + `x-api-key`.

Deploy memakai **Windmill CLI** (`wmill sync push`). Folder ini adalah sumber kebenaran: ubah di sini lalu push, jangan edit script/schedule di UI (akan tertimpa push berikutnya).

| Job | Script | Schedule | Endpoint |
| --- | --- | --- | --- |
| API-CL-34 Job Outstanding | `f/sis/claim_outstanding_job` | `f/sis/claim_outstanding_hourly`: `0 5 * * * *` (detik menit jam …), Asia/Jakarta, **`limit: 50`** per run | `POST {claim-service}/internal/v1/claims/jobs/outstanding` |

## Isi folder

| File | Fungsi | Di-sync CLI |
| --- | --- | --- |
| `wmill.yaml` | Konfigurasi CLI: apa yang di-sync (script + schedule di `f/sis/**`). | - |
| `wmill-lock.yaml` | Hash konten script, dipakai CLI untuk mendeteksi perubahan. Ikut di-commit. | - |
| `f/sis/claim_outstanding_job.ts` | Kode script (Bun). | ✓ |
| `f/sis/claim_outstanding_job.script.yaml` | Metadata script: summary, description, schema argumen (`limit`, nama variable). | ✓ |
| `f/sis/claim_outstanding_job.script.lock` | Lock dependency (`windmill-client`). | ✓ |
| `f/sis/claim_outstanding_hourly.schedule.yaml` | **Jadwal**: cron, timezone, `enabled`. | ✓ |
| `f/sis/folder.meta.yaml` | Wajib ada untuk CLI ≥ 1.882 walau `skipFolders`. Isinya disamakan dengan folder `sis` di server (owner `u/mpuhambyah`). | - |
| `docker-compose.yml`, `.env.example` | Windmill lokal (Postgres, server port 8000, 1 worker di `sera-sis-network`). | - |

**Tidak di-sync** (diatur sekali per workspace, lihat langkah 3):

| Item | Alasan |
| --- | --- |
| Folder `sis` | Push folder menimpa owner/permission folder di server. |
| Variable `f/sis/claim_service_base_url` | URL berbeda antara lokal (`http://claim-service:3003`) dan server. |
| Variable secret `f/sis/claim_internal_api_key` | Secret tidak boleh ada di file repo. |

## 1. Pasang CLI (sekali)

```bash
npm i -g windmill-cli@1.871.1   # samakan dengan versi server: lihat `wmill version`
wmill --version
```

## 2. Daftarkan workspace (sekali per komputer)

Token: UI Windmill → profil (User settings) → **Tokens** → New token. Token disimpan di `~/.config/windmill`, bukan di repo.

```bash
# Server dev SERA. <workspace_id> = nilai ?workspace=... di URL dashboard (bukan nama tampilan "SERA")
wmill workspace add sera-dev <workspace_id> https://<url-windmill-server>/
# Lokal (docker-compose di folder ini)
wmill workspace add local sis http://localhost:8000/

wmill workspace switch sera-dev   # pilih target aktif
wmill workspace whoami
```

`workspace add` meminta token secara interaktif (atau `--token <token>`).

## 3. Siapkan folder dan variable (sekali per workspace)

1. Folder **`sis`**: buat dari UI (Home → New → Folder) bila belum ada.
2. Variable:

```bash
# Server dev SERA
wmill variable add "https://service-claim-sis-dev.sera.astra.co.id" f/sis/claim_service_base_url \
  --no-secret --yes --description "Base URL claim-service dari worker Windmill"
wmill variable add "<WINDMILL_INTERNAL_API_KEY claim-service server>" f/sis/claim_internal_api_key \
  --secret --yes --description "x-api-key endpoint /internal claim-service"

# Lokal: URL = http://claim-service:3003, key = WINDMILL_INTERNAL_API_KEY di SERA_SIS_ClaimService/.env
```

Sementara ini key server **sama dengan dev lokal**; ganti dengan key khusus server nanti (isi di ClaimService server + perintah di atas, keduanya harus sama).

## 4. Deploy script dan schedule

Jalankan dari folder `windmill/`:

```bash
cd windmill
wmill sync push --dry-run     # lihat apa yang akan berubah
wmill sync push               # terapkan (konfirmasi y)
```

Target bisa dipilih per perintah: `wmill sync push --workspace local`. Push ulang tanpa perubahan = 0 changes (idempoten).

> ⚠️ `sync push` menimpa item di dalam `f/sis/**` yang berbeda dari repo, dan **menghapus** item di path itu yang tidak ada di repo. Selalu `--dry-run` dulu.

## Mengubah jadwal

Edit `f/sis/claim_outstanding_hourly.schedule.yaml`, lalu `wmill sync push`:

```yaml
args:
  limit: 50                # maks klaim dipindah per run (1..1000)
schedule: 0 5 * * * *      # 6 field: detik menit jam tanggal bulan hari
timezone: Asia/Jakarta
enabled: false             # true untuk menyalakan
```

**Batas per run (`limit`).** Setiap klaim yang pindah ke Outstanding mengirim email `CLAIM_OUTSTANDING` ke **semua** PIC Cabang di BA klaim itu. Run penuh tanpa batas pernah mengirim ribuan email sekaligus (24 Nov 2026), jadi schedule mengirim `limit: 50`: satu panggilan, maks 50 klaim per run; sisanya menunggu run berikutnya. Kapasitas = `limit` × run per hari (50 × 24 = 1.200 klaim/hari untuk tiap jam). Jumlah email per run = 50 × jumlah PIC per BA, bukan tepat 50.

| Kebutuhan | Cron |
| --- | --- |
| Tiap jam menit ke-5 | `0 5 * * * *` |
| Tiap 30 menit | `0 */30 * * * *` |
| Tiap jam, 07:00–20:00 | `0 5 7-20 * * *` |

`enabled` ikut di-sync: kalau schedule dinyalakan dari UI tapi file masih `false`, push berikutnya mematikannya lagi. Nyalakan lewat file.

## Mengubah script

1. Edit `f/sis/claim_outstanding_job.ts`.
2. Bila argumen fungsi `main` atau import berubah: `wmill generate-metadata` (memperbarui `.script.yaml`, `.script.lock`, `wmill-lock.yaml`). Bila hanya isi kode: `wmill generate-metadata rehash`.
3. `wmill sync push --dry-run`, lalu `wmill sync push`.

## Uji

UI → script `f/sis/claim_outstanding_job` → **Run** dengan argumen **`limit`** (mis. `1` atau `100`, maks 1000): satu panggilan `?limit=N`, memindahkan paling banyak sebanyak itu. Kosongkan untuk run penuh. Atau dari CLI:

```bash
wmill script run f/sis/claim_outstanding_job -d '{"limit": 1}'
```

> ⚠️ Claim-service dev memakai **database dev bersama**. Run berarti memindahkan klaim yang memenuhi syarat ke Outstanding (tidak bisa dibatalkan) dan mengirim email `CLAIM_OUTSTANDING` ke PIC Cabang. Karena itu schedule `enabled: false` secara default.

## Windmill lokal

1. Jalankan stack utama dulu (`docker compose up -d` di root SIS), karena network `sera-sis-network` dibuat di sana.
2. `cp windmill/.env.example windmill/.env`
3. `docker compose -f windmill/docker-compose.yml --env-file windmill/.env up -d`
4. Login `http://localhost:8000` (`admin@windmill.dev` / `changeme`), buat workspace **sis** dan folder **sis**, ganti password admin.
5. Langkah 2–4 di atas dengan workspace `local`.

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
| Image | `1.871.1` | Pin rilis yang sama dengan CLI |
| Postgres Windmill | Container | DB terkelola (RDS) terpisah dari DB SIS |
| Akses ke service | Domain dev claim-service | Jaringan privat ke ClaimService. Bila lewat API Gateway/ingress, timeout ≥ 30 detik (endpoint dibatasi 25 detik) |
| API key | Sama dengan dev lokal | Config Vault (KMS `WINDMILL_INTERNAL_API_KEY`), disalin ke variable secret Windmill, dirotasi bersama |
| Alert gagal | Lihat Runs | Error handler schedule/workspace ke Slack/email (pengganti CloudWatch alarm) |
| Admin | Akun manual | SSO/akun per orang, password default dihapus |
| Deploy | `wmill sync push` dari laptop | `wmill sync push --yes --base-url … --workspace … --token $WM_TOKEN` di pipeline CI |
