#!/bin/bash

# ============================================================
#  SETUP SERVIDOR - Concesionario Spring Boot
#  Ejecutar en: Ubuntu Server (sin GUI)
#  Uso: sudo bash setup_servidor.sh
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[✔]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✘] ERROR:${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}══════════════════════════════════════${NC}";
         echo -e "${CYAN}${BOLD}  $1${NC}";
         echo -e "${CYAN}${BOLD}══════════════════════════════════════${NC}"; }

if [[ $EUID -ne 0 ]]; then
  err "Este script debe ejecutarse como root: sudo bash setup_servidor.sh"
fi

# ============================================================
# BIENVENIDA
# ============================================================
clear
echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   SETUP SERVIDOR - CONCESIONARIO          ║"
echo "  ║   Spring Boot + PostgreSQL + Apache       ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Este script configurará ${BOLD}paso a paso${NC} tu servidor."
echo -e "  Se te pedirán algunos datos antes de empezar.\n"

# ============================================================
# RECOGIDA DE DATOS INTERACTIVA
# ============================================================
step "CONFIGURACIÓN INICIAL"

# --- Usuario del sistema ---
read -rp "  Usuario del sistema (el que usará la app) [$SUDO_USER]: " APP_USER
APP_USER=${APP_USER:-$SUDO_USER}
[[ -z "$APP_USER" ]] && err "No se pudo detectar el usuario. Introdúcelo manualmente."

# --- PostgreSQL ---
read -rp "  Contraseña para el usuario PostgreSQL 'concesionario_user': " -s PG_PASSWORD
echo ""
[[ -z "$PG_PASSWORD" ]] && err "La contraseña no puede estar vacía."

# --- Datos de red (se usarán AL FINAL) ---
echo ""
info "Ahora introduce los datos para la IP estática (se aplicará al final):"
echo ""
info "Interfaces de red disponibles:"
ip link show | grep -E "^[0-9]+:" | awk '{print "    " $2}' | tr -d ':'
echo ""
read -rp "  Nombre de la interfaz de red (ej: enp0s3, eth0): " NET_IFACE
[[ -z "$NET_IFACE" ]] && err "Debes introducir el nombre de la interfaz."

read -rp "  IP estática que quieres asignar (ej: 192.168.100.2): " STATIC_IP
[[ -z "$STATIC_IP" ]] && err "Debes introducir una IP."

read -rp "  Máscara de red en CIDR (ej: 24 para /24): " CIDR
CIDR=${CIDR:-24}

read -rp "  Puerta de enlace / Gateway (ej: 192.168.100.1): " GATEWAY
[[ -z "$GATEWAY" ]] && err "Debes introducir el gateway."

read -rp "  DNS primario [8.8.8.8]: " DNS1
DNS1=${DNS1:-8.8.8.8}

read -rp "  DNS secundario [1.1.1.1]: " DNS2
DNS2=${DNS2:-1.1.1.1}

APP_DIR="/home/$APP_USER/concesionario"

# Confirmación
echo ""
echo -e "${BOLD}  ┌─ Resumen de configuración ──────────────────┐${NC}"
echo -e "  │  Usuario app:    ${CYAN}$APP_USER${NC}"
echo -e "  │  Usuario PG:     ${CYAN}concesionario_user${NC}"
echo -e "  │  Interfaz red:   ${CYAN}$NET_IFACE${NC}"
echo -e "  │  IP estática:    ${CYAN}$STATIC_IP/$CIDR${NC}"
echo -e "  │  Gateway:        ${CYAN}$GATEWAY${NC}"
echo -e "  │  DNS:            ${CYAN}$DNS1, $DNS2${NC}"
echo -e "  │"
echo -e "  │  ${YELLOW}⚠ La IP estática se aplicará AL FINAL${NC}"
echo -e "  │  ${YELLOW}  para no perder internet durante la instalación${NC}"
echo -e "${BOLD}  └──────────────────────────────────────────────┘${NC}"
echo ""
read -rp "  ¿Continuar? [s/N]: " CONFIRM
[[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]] && echo "Cancelado." && exit 0

# ============================================================
# PASO 1 — SSH
# ============================================================
step "PASO 1/6 · SSH y Firewall"

apt-get update -qq
apt-get install -y openssh-server -qq
systemctl enable ssh
systemctl start ssh
ok "OpenSSH instalado y activo"

ufw --force enable
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow "Apache Full" 2>/dev/null || true
ok "UFW activado · puertos 22 y 80 abiertos"
info "SFTP disponible automáticamente por el puerto 22"

# ============================================================
# PASO 2 — JAVA 17
# ============================================================
step "PASO 2/6 · Java 17"

if java -version 2>&1 | grep -q "17"; then
  ok "Java 17 ya está instalado"
else
  apt-get install -y openjdk-17-jdk -qq
  ok "Java 17 instalado"
fi
info "Versión: $(java -version 2>&1 | head -1)"

# ============================================================
# PASO 3 — POSTGRESQL
# ============================================================
step "PASO 3/6 · PostgreSQL"

apt-get install -y postgresql postgresql-contrib -qq
systemctl enable postgresql
systemctl start postgresql
ok "PostgreSQL instalado y activo"

info "Creando usuario y base de datos..."
sudo -u postgres psql <<EOSQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'concesionario_user') THEN
    CREATE USER concesionario_user WITH PASSWORD '${PG_PASSWORD}';
  ELSE
    ALTER USER concesionario_user WITH PASSWORD '${PG_PASSWORD}';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE concesionario OWNER concesionario_user'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'concesionario')\gexec

GRANT ALL PRIVILEGES ON DATABASE concesionario TO concesionario_user;
EOSQL
ok "Usuario y base de datos PostgreSQL listos"

# --- Schema ---
info "Creando tablas..."
SCHEMA_FILE="/tmp/schema_pg.sql"
cat > "$SCHEMA_FILE" <<'EOSQL'
CREATE TABLE IF NOT EXISTS users (
    id        SERIAL PRIMARY KEY,
    nombre    VARCHAR(50)  NOT NULL,
    apellidos VARCHAR(100) DEFAULT NULL,
    dni       VARCHAR(20)  DEFAULT NULL,
    telefono  VARCHAR(20)  DEFAULT NULL,
    email     VARCHAR(100) NOT NULL UNIQUE,
    password  VARCHAR(255) NOT NULL,
    role      VARCHAR(20)  NOT NULL DEFAULT 'USER'
);

CREATE TABLE IF NOT EXISTS vehiculos (
    id          SERIAL PRIMARY KEY,
    marca       VARCHAR(50)    NOT NULL,
    modelo      VARCHAR(100)   NOT NULL,
    anyo        INT            NOT NULL,
    precio      DECIMAL(12, 2) NOT NULL,
    categoria   VARCHAR(50)    DEFAULT NULL,
    matricula   VARCHAR(20)    DEFAULT NULL,
    descripcion TEXT           DEFAULT NULL
);

CREATE TABLE IF NOT EXISTS vehiculo_imagenes (
    id          SERIAL PRIMARY KEY,
    vehiculo_id INT          NOT NULL,
    url         VARCHAR(255) NOT NULL,
    CONSTRAINT fk_vehiculo
        FOREIGN KEY (vehiculo_id)
        REFERENCES vehiculos(id)
        ON DELETE CASCADE
);
EOSQL

sudo -u postgres psql -d concesionario -f "$SCHEMA_FILE" -q
ok "Tablas creadas"

# --- Datos ---
info "Insertando datos iniciales..."
DATA_FILE="/tmp/data_pg.sql"
cat > "$DATA_FILE" <<'EOSQL'
INSERT INTO vehiculos (id, marca, modelo, anyo, precio, categoria, matricula, descripcion)
OVERRIDING SYSTEM VALUE VALUES
(1, 'Porsche',     'Taycan Turbo S',    2026, 195000.00,  'Deportivo Eléctrico', '1234-ABC', 'Deportivo 100% eléctrico con diseño futurista, car...'),
(2, 'Mercedes',    'Clase C',           2026, 1500000.00, 'suv',                 '1234 ABC', 'dsadadsa'),
(3, 'BMW',         'M4',                2025, 1499998.00, 'deportivo',           '1235 ABC', 'dW'),
(4, 'Bentley',     'Lincoln Navigator', 2025, 1000000.00, 'suv',                 '0001 ABC', 'La Lincoln Navigator 2025-2026 es un SUV de lujo d...'),
(7, 'Rolls-Royce', 'Silver Ghost',      2020, 1000000.00, 'deportivo',           '0111 PKB', '1915'),
(9, 'BMW',         'x1',                2017, 12.00,      'suv',                 '1234 JLD', 'Jose Luis')
ON CONFLICT (id) DO NOTHING;

SELECT setval('vehiculos_id_seq', (SELECT MAX(id) FROM vehiculos));

INSERT INTO vehiculo_imagenes (id, vehiculo_id, url)
OVERRIDING SYSTEM VALUE VALUES
(1,  4, '/uploads/vehiculo/Lincoln-Navigator-delante.jpg'),
(3,  7, '/uploads/vehiculo/1925_Rolls-Royce-45-50.jpg'),
(5,  1, '/uploads/vehiculo/porsche_taycan.jpg'),
(6,  2, '/uploads/vehiculo/2019-mercedes-benz-c-class.jpg'),
(7,  3, '/uploads/vehiculo/BMW_M4_CS_2024.jpg'),
(14, 9, '/uploads/vehiculo/a5ae0779-ecc7-429c-b0de-e0312e96...')
ON CONFLICT (id) DO NOTHING;

SELECT setval('vehiculo_imagenes_id_seq', (SELECT MAX(id) FROM vehiculo_imagenes));

INSERT INTO users (id, nombre, apellidos, dni, telefono, email, password, role)
OVERRIDING SYSTEM VALUE VALUES
(1, 'fran',      NULL, NULL, NULL, 'danilopezdeve@gmail.com', '$2b$10$BvbLLZKUX7a0Ro7fQRfpGeNRGM/h3Y7OWk9Xi1RclwGNFGkYHPfNi', 'USER'),
(2, 'fer',       NULL, NULL, NULL, 'fer@example.com',         '$2b$10$0EIlguNw10nlMOOr2vbknuLv3wtldp/UVT0w74CrC3unJH2FufT4a',  'USER'),
(3, 'dani',      NULL, NULL, NULL, 'dani@example.com',        '$2b$10$EOs5G5FaE6F9/dVexfwKFOw3awAExNkpLz/TL0Vx5K96UhNDxoWUW',  'USER'),
(7, 'mecanico',  NULL, NULL, NULL, 'mecanico@autoelite.es',   '$2b$10$TuXfMkSfAvzzt3dh.3Gyk.dD1ee54.RUkCO10dStvdcDqMmxBtaE6',  'MECANICO'),
(8, 'comercial', NULL, NULL, NULL, 'comercial@autoelite.es',  '$2b$10$PCtTl9BfYuZGcwfjJSICjekboqIY5gNCw99/b4cpc3vUmszRxjEOm',   'COMERCIAL'),
(9, 'admin',     NULL, NULL, NULL, 'admin@autoelite.es',      '$2b$10$3N2pP5PnjxIDW4YiJNXi..baSm.KS0FgVVR7L1v.3gsg/lws/O/xC',  'ADMIN')
ON CONFLICT (id) DO NOTHING;

SELECT setval('users_id_seq', (SELECT MAX(id) FROM users));
EOSQL

sudo -u postgres psql -d concesionario -f "$DATA_FILE" -q
ok "Datos insertados"

# --- Permisos ---
info "Aplicando permisos sobre tablas y secuencias..."
sudo -u postgres psql -d concesionario <<EOSQL
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO concesionario_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO concesionario_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO concesionario_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO concesionario_user;
EOSQL
ok "Permisos PostgreSQL aplicados"

# ============================================================
# PASO 4 — DIRECTORIO DE LA APP
# ============================================================
step "PASO 4/6 · Directorio de la aplicación"

mkdir -p "$APP_DIR"
chown "$APP_USER":"$APP_USER" "$APP_DIR"
ok "Directorio $APP_DIR creado y asignado a $APP_USER"

# ============================================================
# PASO 5 — APACHE REVERSE PROXY
# ============================================================
step "PASO 5/6 · Apache Reverse Proxy"

apt-get install -y apache2 -qq
systemctl enable apache2
systemctl start apache2

a2enmod proxy      -q
a2enmod proxy_http -q
a2enmod rewrite    -q

VHOST_FILE="/etc/apache2/sites-available/concesionario.conf"
cat > "$VHOST_FILE" <<EOF
<VirtualHost *:80>
    ServerName ${STATIC_IP}

    ProxyPreserveHost On
    ProxyPass        / http://localhost:8088/
    ProxyPassReverse / http://localhost:8088/

    ErrorLog  \${APACHE_LOG_DIR}/concesionario_error.log
    CustomLog \${APACHE_LOG_DIR}/concesionario_access.log combined
</VirtualHost>
EOF

a2ensite  concesionario.conf -q
a2dissite 000-default.conf   -q
systemctl reload apache2
ok "Apache configurado como reverse proxy → puerto 80 → :8088"

# ============================================================
# PASO 6 — SERVICIO SYSTEMD
# ============================================================
step "PASO 6/6 · Servicio systemd"

JAR_PATH="$APP_DIR/concesionario2-0.0.1-SNAPSHOT.jar"
cat > /etc/systemd/system/concesionario.service <<EOF
[Unit]
Description=Concesionario Spring Boot App
After=network.target postgresql.service

[Service]
User=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/java -jar ${JAR_PATH}
SuccessExitStatus=143
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=concesionario

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable concesionario
ok "Servicio 'concesionario' registrado y habilitado"
warn "El servicio arrancará cuando el cliente suba el JAR"

# ============================================================
# ÚLTIMO PASO — IP ESTÁTICA (al final para no perder internet)
# ============================================================
step "ÚLTIMO PASO · IP Estática"

NETPLAN_FILE="/etc/netplan/00-installer-config.yaml"

if [[ -f "$NETPLAN_FILE" ]]; then
  cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak"
  info "Backup guardado en ${NETPLAN_FILE}.bak"
fi

cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  ethernets:
    ${NET_IFACE}:
      dhcp4: false
      addresses:
        - ${STATIC_IP}/${CIDR}
      gateway4: ${GATEWAY}
      nameservers:
        addresses: [${DNS1}, ${DNS2}]
EOF

chmod 600 "$NETPLAN_FILE"

warn "A punto de aplicar IP estática $STATIC_IP en $NET_IFACE"
warn "Si estás conectado por SSH, la sesión se cortará. ¡Es normal!"
echo ""
read -rp "  ¿Aplicar IP estática ahora? [s/N]: " APPLY_IP

if [[ "$APPLY_IP" == "s" || "$APPLY_IP" == "S" ]]; then
  netplan apply && ok "IP estática $STATIC_IP aplicada" || warn "Netplan aplicado con advertencias"
else
  info "Puedes aplicarla manualmente después con: sudo netplan apply"
fi

# ============================================================
# VERIFICACIÓN FINAL
# ============================================================
step "VERIFICACIÓN FINAL"

echo ""
systemctl is-active --quiet ssh        && ok "SSH activo"        || warn "SSH NO activo"
systemctl is-active --quiet postgresql && ok "PostgreSQL activo" || warn "PostgreSQL NO activo"
systemctl is-active --quiet apache2    && ok "Apache activo"     || warn "Apache NO activo"

info "Comprobando tablas PostgreSQL..."
sudo -u postgres psql -d concesionario -c "\dt" -q 2>/dev/null && ok "Tablas accesibles" || warn "No se pudo verificar PostgreSQL"

# ============================================================
# RESUMEN FINAL
# ============================================================
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║   SERVIDOR CONFIGURADO CORRECTAMENTE             ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${BOLD}IP del servidor:${NC}     ${CYAN}$STATIC_IP${NC}"
echo -e "  ${BOLD}Puerto SSH/SFTP:${NC}     ${CYAN}22${NC}"
echo -e "  ${BOLD}Usuario sistema:${NC}     ${CYAN}$APP_USER${NC}"
echo -e "  ${BOLD}Directorio JAR:${NC}      ${CYAN}$APP_DIR${NC}"
echo -e "  ${BOLD}Usuario PostgreSQL:${NC}  ${CYAN}concesionario_user${NC}"
echo ""
echo -e "  ${YELLOW}PRÓXIMO PASO:${NC} Ejecuta ${BOLD}setup_cliente.sh${NC} en la VM cliente"
echo ""
echo -e "  Una vez subido el JAR, arranca la app con:"
echo -e "  ${CYAN}sudo systemctl start concesionario${NC}"
echo ""
