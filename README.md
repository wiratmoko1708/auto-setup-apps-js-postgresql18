# Panduan Instalasi Chatbot di VPS

Script `setup-npm-postgres.sh` mengotomasi seluruh proses instalasi aplikasi RAG Chatbot di VPS Debian 12.

---

## Persyaratan

| Komponen | Minimum |
|---|---|
| OS | Debian 12 (Bookworm) |
| RAM | 2 GB |
| Storage | 20 GB |
| Akses | Root / sudo |
| Domain/Subdomain | Sudah diarahkan ke IP VPS (untuk SSL) |

---

## Yang Diinstall Otomatis

| No | Komponen | Keterangan |
|---|---|---|
| 1 | System update | apt update & upgrade |
| 2 | Paket dasar | curl, git, build-essential, nginx, certbot, supervisor, dll |
| 3 | UFW Firewall | Buka port 22, 80, 443 — tutup port 5432 dari publik |
| 4 | Node.js LTS | Via NodeSource + PM2 process manager |
| 5 | PostgreSQL 18 | Dari repo resmi postgresql.org |
| 6 | pgvector v0.8.0 | Extension vector similarity search (wajib untuk RAG) |
| 7 | Database & Tabel | Buat DB, user, semua tabel + HNSW index otomatis |
| 8 | Aplikasi Next.js | Clone dari Git atau upload manual, npm install & build |
| 9 | PM2 | Auto-restart + startup systemd |
| 10 | Nginx + SSL | Reverse proxy ke port 3000 + Certbot Let's Encrypt |

---

## Cara Instalasi

### 1. Upload script ke VPS

```bash
scp setup-npm-postgres.sh root@IP_VPS:/root/
```

Atau langsung di VPS:

```bash
wget https://your-repo/setup-npm-postgres.sh
```

### 2. Beri permission dan jalankan

```bash
chmod +x setup-npm-postgres.sh
bash setup-npm-postgres.sh
```

### 3. Ikuti pertanyaan interaktif

Script akan menanyakan beberapa hal secara berurutan:

```
Nama database        [rag_chatbot]
Username PostgreSQL  [kasbi_user]
Password PostgreSQL  : ****
Path deploy aplikasi [/var/www/kasbi]
Git repository URL   : (kosongkan jika upload manual)
OPENAI_API_KEY       : sk-xxxx
OPENAI_BASE_URL      [https://ai.sumopod.com/v1]
Domain/Subdomain     : kasbi.bpmp.go.id
Email SSL Certbot    [admin@kasbi.bpmp.go.id]
```

---

## Setup Domain / Subdomain

Script otomatis mengecek apakah DNS domain sudah mengarah ke IP server sebelum memasang SSL.

### Langkah di panel DNS (sebelum install)

Tambahkan A Record di panel DNS domain kamu:

```
Type  : A
Name  : kasbi          (untuk subdomain kasbi.domain.com)
        @              (untuk root domain domain.com)
Value : IP_VPS_KAMU
TTL   : 3600
```

Contoh untuk subdomain `kasbi.bpmp.go.id`:
```
Type  : A
Name  : kasbi
Value : 103.x.x.x
TTL   : 3600
```

### Jika DNS belum propagasi saat install

Script akan mendeteksi dan menawarkan opsi lanjut tanpa SSL dulu. Setelah DNS propagasi (biasanya 5–30 menit), jalankan manual:

```bash
certbot --nginx -d kasbi.bpmp.go.id --agree-tos -m admin@bpmp.go.id
```

SSL akan auto-renew setiap hari pukul 03:00 via crontab.

---

## Struktur File yang Dibuat

```
/var/www/kasbi/
├── .env.local          # Konfigurasi environment (DB, API key)
├── ecosystem.config.js # Konfigurasi PM2
└── ...                 # File aplikasi Next.js

/etc/nginx/sites-available/kasbi   # Konfigurasi Nginx
```

### Isi .env.local yang dibuat otomatis

```env
DATABASE_URL=postgresql://kasbi_user:****@localhost:5432/rag_chatbot
POSTGRES_URL=postgresql://kasbi_user:****@localhost:5432/rag_chatbot
OPENAI_API_KEY=sk-xxxx
OPENAI_BASE_URL=https://ai.sumopod.com/v1
SESSION_SECRET=<random 32 byte>
```

---

## Akses Setelah Instalasi

| URL | Keterangan |
|---|---|
| `https://domain.com` | Halaman chatbot utama |
| `https://domain.com/mburi/dashboard` | Dashboard admin |

### Login default dashboard

| Role | Email | Password |
|---|---|---|
| Admin | `admin@bpmp.go.id` | `Admin2025!` |

> **Segera ganti password** setelah login pertama melalui menu Manajemen User di dashboard.

---

## Perintah Berguna Setelah Install

```bash
# Cek status aplikasi
pm2 status

# Lihat log real-time
pm2 logs kasbi-chatbot

# Restart aplikasi
pm2 restart kasbi-chatbot

# Reload setelah update kode
cd /var/www/kasbi && git pull && npm run build && pm2 restart kasbi-chatbot

# Cek status PostgreSQL
systemctl status postgresql

# Masuk ke database
sudo -u postgres psql -d rag_chatbot

# Cek status Nginx
systemctl status nginx

# Cek SSL
certbot certificates
```

---

## Menjalankan Aplikasi di VPS

Script sudah otomatis menjalankan aplikasi via PM2. Tapi berikut penjelasan lengkapnya jika perlu dilakukan manual.

### Pertama kali (setelah upload kode)

```bash
cd /var/www/kasbi

# 1. Install semua dependencies
npm install

# 2. Build aplikasi Next.js untuk production
npm run build

# 3. Jalankan via PM2
pm2 start ecosystem.config.js

# 4. Simpan agar otomatis jalan saat server reboot
pm2 save
```

### Setelah update kode

```bash
cd /var/www/kasbi

git pull                  # ambil kode terbaru (jika pakai Git)
npm install               # update dependencies jika ada perubahan package.json
npm run build             # build ulang
pm2 restart kasbi-chatbot # restart aplikasi
```

### Cek aplikasi berjalan

```bash
pm2 status                          # lihat status semua proses
pm2 logs kasbi-chatbot --lines 50   # lihat 50 baris log terakhir
curl http://localhost:3000           # test dari dalam server
```

### Jangan gunakan `npm run dev` di VPS

`npm run dev` hanya untuk development lokal — tidak stabil dan lambat untuk production. Selalu gunakan:

```
npm run build  →  pm2 start
```

---



Setelah aplikasi berjalan, upload dokumen PDF via dashboard admin atau gunakan script bulk:

```bash
cd /var/www/kasbi
node scripts/bulk-upload-pdf.js /path/ke/folder/dokumen
```

---

## Troubleshooting

**Aplikasi tidak bisa diakses**
```bash
pm2 logs kasbi-chatbot   # cek error
pm2 restart kasbi-chatbot
```

**SSL gagal**
```bash
# Pastikan DNS sudah pointing ke server
dig kasbi.bpmp.go.id

# Pasang SSL manual
certbot --nginx -d kasbi.bpmp.go.id --agree-tos -m admin@bpmp.go.id
```

**Error koneksi database**
```bash
# Cek PostgreSQL berjalan
systemctl status postgresql

# Test koneksi
psql postgresql://kasbi_user:PASSWORD@localhost:5432/rag_chatbot -c "\dt"
```

**Port 3000 tidak bisa diakses dari luar**
Normal — aplikasi hanya diakses via Nginx (port 80/443). Port 3000 hanya untuk internal.
