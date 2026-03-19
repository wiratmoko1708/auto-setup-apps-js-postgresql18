#!/bin/bash
# ==========================================
# Setup Script: KASBI BPMP Papua RAG Chatbot
# Target: Debian 12 (Bookworm)
# Stack: Node.js + Next.js + PostgreSQL 18 + pgvector
# ==========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "Jalankan script ini sebagai root: sudo bash $0"
    exit 1
  fi
}

check_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
    CODENAME=$VERSION_CODENAME
  else
    log_error "OS tidak terdeteksi."
    exit 1
  fi
  log_info "OS: $OS $VER ($CODENAME)"
  if [[ "$ID" != "debian" ]]; then
    log_warning "Script ini dioptimalkan untuk Debian 12. Lanjutkan dengan risiko sendiri."
  fi
}

# ==========================================
# 1. Update Sistem
# ==========================================
step_update_system() {
  log_info "1. Update sistem..."
  apt update && apt upgrade -y
  log_success "Sistem diupdate."
}

# ==========================================
# 2. Paket Dasar
# ==========================================
step_install_basics() {
  log_info "2. Install paket dasar..."
  apt install -y \
    apt-transport-https ca-certificates curl gnupg lsb-release \
    git wget unzip build-essential software-properties-common \
    ufw supervisor certbot python3-certbot-nginx nginx
  log_success "Paket dasar terinstall."
}

# ==========================================
# 3. Firewall
# ==========================================
step_setup_firewall() {
  log_info "3. Konfigurasi UFW Firewall..."
  ufw allow ssh
  ufw allow http
  ufw allow https
  # PostgreSQL hanya dari localhost, tidak expose ke publik
  ufw deny 5432
  echo "y" | ufw enable
  ufw status
  log_success "Firewall dikonfigurasi."
}

# ==========================================
# 4. Node.js LTS (via NodeSource)
# ==========================================
step_install_node() {
  log_info "4. Install Node.js LTS..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt install -y nodejs
  npm install -g pm2
  log_success "Node.js $(node -v) | npm $(npm -v) | pm2 $(pm2 -v)"
}

# ==========================================
# 5. PostgreSQL 18 + pgvector
# ==========================================
step_install_postgres() {
  log_info "5. Install PostgreSQL 18..."

  # Tambah repo resmi PostgreSQL
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg

  echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
https://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list

  apt update
  apt install -y postgresql-18 postgresql-client-18 postgresql-server-dev-18

  systemctl enable postgresql
  systemctl start postgresql
  log_success "PostgreSQL 18 terinstall."

  # ==========================================
  # 6. pgvector (wajib untuk RAG embedding)
  # ==========================================
  log_info "6. Install pgvector extension..."

  apt install -y git build-essential
  cd /tmp
  git clone --branch v0.8.0 https://github.com/pgvector/pgvector.git
  cd pgvector
  make PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
  make install PG_CONFIG=/usr/lib/postgresql/18/bin/pg_config
  cd /
  rm -rf /tmp/pgvector

  log_success "pgvector terinstall."
}

# ==========================================
# 7. Setup Database & User PostgreSQL
# ==========================================
step_setup_database() {
  log_info "7. Setup database PostgreSQL..."

  read -p "Nama database [rag_chatbot]: " DB_NAME
  DB_NAME=${DB_NAME:-rag_chatbot}

  read -p "Username PostgreSQL [kasbi_user]: " DB_USER
  DB_USER=${DB_USER:-kasbi_user}

  read -sp "Password PostgreSQL: " DB_PASS
  echo ""

  # Buat user dan database
  sudo -u postgres psql <<EOF
CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';
CREATE DATABASE $DB_NAME OWNER $DB_USER;
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
\c $DB_NAME
CREATE EXTENSION IF NOT EXISTS vector;
GRANT ALL ON SCHEMA public TO $DB_USER;
EOF

  # Buat tabel-tabel aplikasi
  sudo -u postgres psql -d $DB_NAME <<'EOF'
CREATE TABLE IF NOT EXISTS documents (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  file_type TEXT NOT NULL,
  file_size INTEGER,
  blob_url TEXT,
  upload_date TIMESTAMP DEFAULT NOW(),
  chunk_count INTEGER DEFAULT 0,
  metadata JSONB DEFAULT '{}'::jsonb,
  session_id TEXT,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS chunks (
  id SERIAL PRIMARY KEY,
  document_id INTEGER REFERENCES documents(id) ON DELETE CASCADE,
  chunk_index INTEGER NOT NULL,
  content TEXT NOT NULL,
  token_count INTEGER,
  embedding vector(1536),
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_chunks_document_id ON chunks(document_id);
CREATE INDEX IF NOT EXISTS idx_documents_session_id ON documents(session_id);
CREATE INDEX IF NOT EXISTS idx_chunks_embedding ON chunks
  USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);

CREATE TABLE IF NOT EXISTS query_history (
  id SERIAL PRIMARY KEY,
  query TEXT NOT NULL,
  response TEXT NOT NULL,
  retrieved_chunks INTEGER[],
  retrieval_time_ms INTEGER,
  generation_time_ms INTEGER,
  total_time_ms INTEGER,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS users (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT UNIQUE NOT NULL,
  password TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('admin', 'operator')),
  created_at TIMESTAMP DEFAULT NOW()
);

INSERT INTO users (name, email, password, role)
VALUES ('Admin', 'admin@bpmp.go.id', 'Admin2025!', 'admin')
ON CONFLICT (email) DO NOTHING;
EOF

  # Simpan DATABASE_URL untuk dipakai nanti
  export DATABASE_URL="postgresql://$DB_USER:$DB_PASS@localhost:5432/$DB_NAME"
  echo "DATABASE_URL=$DATABASE_URL" >> /tmp/kasbi_env_vars

  log_success "Database '$DB_NAME' siap dengan pgvector dan semua tabel."
}

# ==========================================
# 8. Deploy Aplikasi Next.js
# ==========================================
step_deploy_app() {
  log_info "8. Deploy aplikasi KASBI..."

  read -p "Path deploy aplikasi [/var/www/kasbi]: " APP_DIR
  APP_DIR=${APP_DIR:-/var/www/kasbi}

  read -p "Git repository URL (kosongkan jika upload manual): " GIT_URL

  mkdir -p "$APP_DIR"

  if [[ -n "$GIT_URL" ]]; then
    git clone "$GIT_URL" "$APP_DIR"
  else
    log_warning "Silakan upload file aplikasi ke $APP_DIR secara manual (scp/rsync)."
    log_warning "Lanjutkan setelah file ada di $APP_DIR"
    read -p "Tekan ENTER setelah file diupload..."
  fi

  # Buat .env.local
  if [ -f /tmp/kasbi_env_vars ]; then
    source /tmp/kasbi_env_vars
  fi

  read -p "OPENAI_API_KEY (SumoPod): " OPENAI_KEY
  read -p "OPENAI_BASE_URL [https://ai.sumopod.com/v1]: " OPENAI_URL
  OPENAI_URL=${OPENAI_URL:-https://ai.sumopod.com/v1}

  SESSION_SECRET=$(openssl rand -base64 32)

  cat > "$APP_DIR/.env.local" <<EOF
DATABASE_URL=${DATABASE_URL}
POSTGRES_URL=${DATABASE_URL}
OPENAI_API_KEY=${OPENAI_KEY}
OPENAI_BASE_URL=${OPENAI_URL}
SESSION_SECRET=${SESSION_SECRET}
EOF

  log_info "Install dependencies dan build..."
  cd "$APP_DIR"
  npm install
  npm run build

  # Simpan APP_DIR untuk PM2
  export APP_DIR
  echo "APP_DIR=$APP_DIR" >> /tmp/kasbi_env_vars

  log_success "Aplikasi berhasil di-build."
}

# ==========================================
# 9. PM2 Process Manager
# ==========================================
step_setup_pm2() {
  log_info "9. Setup PM2..."

  if [ -f /tmp/kasbi_env_vars ]; then
    source /tmp/kasbi_env_vars
  fi

  cd "$APP_DIR"

  # Buat ecosystem PM2
  cat > "$APP_DIR/ecosystem.config.js" <<EOF
module.exports = {
  apps: [{
    name: 'kasbi-chatbot',
    script: 'node_modules/.bin/next',
    args: 'start',
    cwd: '${APP_DIR}',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '1G',
    env: {
      NODE_ENV: 'production',
      PORT: 3000
    }
  }]
};
EOF

  pm2 start ecosystem.config.js
  pm2 save
  pm2 startup systemd -u root --hp /root | tail -1 | bash

  log_success "PM2 berjalan. Aplikasi di port 3000."
}

# ==========================================
# 10. Nginx Reverse Proxy + SSL
# ==========================================
step_setup_nginx() {
  log_info "10. Konfigurasi Nginx + SSL..."

  echo ""
  echo "Contoh domain  : kasbi.bpmp.go.id"
  echo "Contoh subdomain: chatbot.bpmp.go.id"
  echo ""
  read -p "Masukkan domain atau subdomain: " DOMAIN
  if [[ -z "$DOMAIN" ]]; then
    log_error "Domain tidak boleh kosong."
    exit 1
  fi

  read -p "Email untuk SSL Certbot [admin@${DOMAIN}]: " SSL_EMAIL
  SSL_EMAIL=${SSL_EMAIL:-admin@$DOMAIN}

  # Cek apakah DNS sudah pointing ke server ini
  SERVER_IP=$(curl -s https://api.ipify.org)
  DOMAIN_IP=$(getent hosts "$DOMAIN" | awk '{ print $1 }' | head -1)

  log_info "IP server ini : $SERVER_IP"
  log_info "IP dari DNS   : ${DOMAIN_IP:-tidak ditemukan}"

  if [[ "$SERVER_IP" != "$DOMAIN_IP" ]]; then
    log_warning "DNS $DOMAIN belum mengarah ke server ini ($SERVER_IP)."
    log_warning "SSL Certbot akan gagal jika DNS belum propagasi."
    read -p "Lanjutkan tanpa SSL dulu? (y/n): " SKIP_SSL
  else
    log_success "DNS $DOMAIN sudah mengarah ke server ini."
    SKIP_SSL="n"
  fi

  # Konfigurasi Nginx
  cat > /etc/nginx/sites-available/kasbi <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    client_max_body_size 30M;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 120s;
    }
}
EOF

  ln -sf /etc/nginx/sites-available/kasbi /etc/nginx/sites-enabled/
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl restart nginx
  log_success "Nginx dikonfigurasi untuk $DOMAIN."

  # SSL
  if [[ "$SKIP_SSL" == "n" || "$SKIP_SSL" == "N" ]]; then
    log_info "Setup SSL dengan Certbot..."
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$SSL_EMAIL"
    if [[ $? -eq 0 ]]; then
      log_success "SSL berhasil dipasang. Aplikasi bisa diakses di https://$DOMAIN"
      # Auto-renew via cron
      (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet && systemctl reload nginx") | crontab -
      log_success "Auto-renew SSL ditambahkan ke crontab."
    else
      log_warning "SSL gagal. Jalankan manual setelah DNS propagasi:"
      log_warning "  certbot --nginx -d $DOMAIN -m $SSL_EMAIL --agree-tos"
    fi
  else
    log_warning "SSL dilewati. Jalankan manual setelah DNS propagasi:"
    log_warning "  certbot --nginx -d $DOMAIN -m $SSL_EMAIL --agree-tos"
  fi

  # Simpan domain untuk status akhir
  echo "DOMAIN=$DOMAIN" >> /tmp/kasbi_env_vars
}

# ==========================================
# 11. Status Akhir
# ==========================================
step_show_status() {
  if [ -f /tmp/kasbi_env_vars ]; then
    source /tmp/kasbi_env_vars
  fi
  DOMAIN=${DOMAIN:-localhost}
  echo ""
  echo "========================================"
  log_success "INSTALASI SELESAI"
  echo "========================================"
  echo ""
  echo "  Node.js    : $(node -v)"
  echo "  npm        : $(npm -v)"
  echo "  PM2        : $(pm2 -v)"
  echo "  PostgreSQL : $(psql --version)"
  echo "  Nginx      : $(nginx -v 2>&1)"
  echo ""
  echo "  Aplikasi   : https://$DOMAIN"
  echo "  Dashboard  : https://$DOMAIN/mburi/dashboard"
  echo "  Login awal : admin@bpmp.go.id / Admin2025!"
  echo ""
  echo "  PM2 status : pm2 status"
  echo "  PM2 logs   : pm2 logs kasbi-chatbot"
  echo "  Restart    : pm2 restart kasbi-chatbot"
  echo ""
  echo "  Jika SSL belum terpasang:"
  echo "  certbot --nginx -d $DOMAIN --agree-tos -m admin@$DOMAIN"
  echo ""
  echo "========================================"
  rm -f /tmp/kasbi_env_vars
}

# ==========================================
# Main
# ==========================================
check_root
check_os
step_update_system
step_install_basics
step_setup_firewall
step_install_node
step_install_postgres
step_setup_database
step_deploy_app
step_setup_pm2
step_setup_nginx
step_show_status

exit 0
