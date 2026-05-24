#!/bin/bash

# ============================================================
#  SETUP CLIENTE - Concesionario Spring Boot
#  Ejecutar en: VM Cliente (Linux Mint Cinnamon)
#  Uso: bash setup_cliente.sh
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

# ============================================================
# BIENVENIDA
# ============================================================
clear
echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   SETUP CLIENTE - CONCESIONARIO           ║"
echo "  ║   Linux Mint → Compilar JAR → Servidor    ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}"

# ============================================================
# RECOGIDA DE DATOS
# ============================================================
step "CONFIGURACIÓN"

# Detectar usuario y ruta del escritorio
CURRENT_USER=$(whoami)
# Linux Mint en español usa "Escritorio", en inglés "Desktop"
if [[ -d "/home/$CURRENT_USER/Escritorio" ]]; then
  DESKTOP_PATH="/home/$CURRENT_USER/Escritorio"
elif [[ -d "/home/$CURRENT_USER/Desktop" ]]; then
  DESKTOP_PATH="/home/$CURRENT_USER/Desktop"
else
  DESKTOP_PATH="/home/$CURRENT_USER"
fi

info "Usuario detectado: $CURRENT_USER"
info "Escritorio detectado: $DESKTOP_PATH"

# Mostrar carpetas disponibles en el escritorio
echo ""
info "Carpetas encontradas en el escritorio:"
ls -d "$DESKTOP_PATH"/*/ 2>/dev/null | while read d; do echo "    → $(basename $d)"; done
echo ""

read -rp "  Nombre de la carpeta del proyecto en el escritorio [concesionario5]: " PROJECT_FOLDER
PROJECT_FOLDER=${PROJECT_FOLDER:-concesionario5}

PROJECT_DIR="$DESKTOP_PATH/$PROJECT_FOLDER"
[[ ! -d "$PROJECT_DIR" ]] && err "No se encontró la carpeta '$PROJECT_FOLDER' en $DESKTOP_PATH"

# Buscar pom.xml
POM_PATH=$(find "$PROJECT_DIR" -name "pom.xml" -not -path "*/target/*" | head -1)
[[ -z "$POM_PATH" ]] && err "No se encontró pom.xml dentro de $PROJECT_DIR"
POM_DIR=$(dirname "$POM_PATH")
ok "Proyecto encontrado: $POM_DIR"

echo ""
read -rp "  IP del servidor Ubuntu (ej: 192.168.100.2): " SERVER_IP
[[ -z "$SERVER_IP" ]] && err "Debes introducir la IP del servidor."

read -rp "  Usuario SSH del servidor (ej: ubuntu): " SERVER_USER
[[ -z "$SERVER_USER" ]] && err "Debes introducir el usuario SSH."

read -rp "  Puerto SSH del servidor [22]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

read -rp "  Contraseña PostgreSQL (concesionario_user): " -s PG_PASSWORD
echo ""
[[ -z "$PG_PASSWORD" ]] && err "La contraseña no puede estar vacía."

APP_DIR_REMOTE="/home/$SERVER_USER/concesionario"
JAR_NAME="concesionario2-0.0.1-SNAPSHOT.jar"

echo ""
echo -e "${BOLD}  ┌─ Resumen ────────────────────────────────────┐${NC}"
echo -e "  │  Proyecto:        ${CYAN}$PROJECT_DIR${NC}"
echo -e "  │  Servidor:        ${CYAN}$SERVER_IP:$SSH_PORT${NC}"
echo -e "  │  Usuario SSH:     ${CYAN}$SERVER_USER${NC}"
echo -e "  │  JAR destino:     ${CYAN}$APP_DIR_REMOTE/$JAR_NAME${NC}"
echo -e "${BOLD}  └──────────────────────────────────────────────┘${NC}"
echo ""
read -rp "  ¿Continuar? [s/N]: " CONFIRM
[[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]] && echo "Cancelado." && exit 0

# ============================================================
# PASO 1 — INSTALAR DEPENDENCIAS EN EL CLIENTE
# ============================================================
step "PASO 1/4 · Instalar dependencias en Linux Mint"

info "Actualizando repositorios..."
sudo apt-get update -qq

# Java 17
if java -version 2>&1 | grep -q "17"; then
  ok "Java 17 ya instalado"
else
  info "Instalando Java 17..."
  sudo apt-get install -y openjdk-17-jdk -qq && ok "Java 17 instalado"
fi
info "Versión Java: $(java -version 2>&1 | head -1)"

# Maven
if command -v mvn &>/dev/null; then
  ok "Maven disponible: $(mvn -v 2>&1 | head -1)"
else
  sudo apt-get install -y maven -qq && ok "Maven instalado"
fi

# SSH cliente
command -v ssh  &>/dev/null && ok "SSH disponible" || sudo apt-get install -y openssh-client -qq
command -v sftp &>/dev/null && ok "SFTP disponible"

# ============================================================
# PASO 2 — ADAPTAR EL PROYECTO PARA POSTGRESQL
# ============================================================
step "PASO 2/4 · Adaptar proyecto para PostgreSQL"

# --- application.properties ---
PROPS_FILE="$POM_DIR/src/main/resources/application.properties"
[[ ! -f "$PROPS_FILE" ]] && err "No se encontró application.properties en $PROPS_FILE"

cp "$PROPS_FILE" "${PROPS_FILE}.bak"
info "Backup guardado: application.properties.bak"

cat > "$PROPS_FILE" <<EOF
spring.application.name=concesionario
server.port=8088

# === CONEXIÓN A POSTGRESQL ===
spring.datasource.url=jdbc:postgresql://localhost:5432/concesionario
spring.datasource.username=concesionario_user
spring.datasource.password=${PG_PASSWORD}
spring.datasource.driver-class-name=org.postgresql.Driver

spring.jackson.property-naming-strategy=SNAKE_CASE
server.error.whitelabel.enabled=false
EOF

ok "application.properties actualizado para PostgreSQL"

# --- pom.xml: MySQL → PostgreSQL ---
POM_FILE="$POM_DIR/pom.xml"

if grep -q "mysql-connector-j" "$POM_FILE"; then
  cp "$POM_FILE" "${POM_FILE}.bak"
  info "Backup guardado: pom.xml.bak"

  python3 - <<PYEOF
import re

with open("$POM_FILE", "r") as f:
    content = f.read()

# Eliminar bloque dependencia MySQL completo
mysql_pattern = r'\s*<dependency>\s*<groupId>com\.mysql</groupId>\s*<artifactId>mysql-connector-j</artifactId>.*?</dependency>'
content = re.sub(mysql_pattern, '', content, flags=re.DOTALL)

# Insertar dependencia PostgreSQL antes de </dependencies>
pg_dep = '''
        <dependency>
            <groupId>org.postgresql</groupId>
            <artifactId>postgresql</artifactId>
            <scope>runtime</scope>
        </dependency>'''

content = content.replace('</dependencies>', pg_dep + '\n    </dependencies>', 1)

with open("$POM_FILE", "w") as f:
    f.write(content)
PYEOF

  ok "pom.xml actualizado: MySQL → PostgreSQL"

elif grep -q "postgresql" "$POM_FILE"; then
  ok "pom.xml ya tiene dependencia PostgreSQL, no se modifica"
else
  warn "No se encontró dependencia MySQL ni PostgreSQL en pom.xml. Revísalo manualmente."
fi

# ============================================================
# PASO 3 — COMPILAR EL JAR
# ============================================================
step "PASO 3/4 · Compilar el JAR con Maven"

cd "$POM_DIR" || err "No se puede acceder a $POM_DIR"

if [[ -f "./mvnw" ]]; then
  chmod +x ./mvnw
  MVNW="./mvnw"
else
  MVNW="mvn"
fi

info "Ejecutando: $MVNW package -DskipTests"
echo ""

$MVNW package -DskipTests

[[ $? -ne 0 ]] && err "La compilación falló. Revisa los errores anteriores."

JAR_LOCAL=$(find "$POM_DIR/target" -name "*.jar" -not -name "*sources*" | head -1)
[[ -z "$JAR_LOCAL" ]] && err "No se encontró el JAR en target/ tras la compilación."
ok "JAR compilado: $JAR_LOCAL"

# ============================================================
# PASO 4 — SUBIR EL JAR AL SERVIDOR POR SFTP
# ============================================================
step "PASO 4/4 · Subir JAR al servidor por SFTP"

info "Conectando a $SERVER_USER@$SERVER_IP (puerto $SSH_PORT)..."
echo -e "  ${YELLOW}Se te pedirá la contraseña SSH del servidor.${NC}"
echo ""

sftp -P "$SSH_PORT" "$SERVER_USER@$SERVER_IP" <<SFTP_COMMANDS
mkdir $APP_DIR_REMOTE
put $JAR_LOCAL $APP_DIR_REMOTE/$JAR_NAME
bye
SFTP_COMMANDS

[[ $? -ne 0 ]] && err "Falló la transferencia SFTP. Verifica la IP ($SERVER_IP), usuario ($SERVER_USER) y que el servidor está encendido."
ok "JAR subido correctamente a $SERVER_USER@$SERVER_IP:$APP_DIR_REMOTE/$JAR_NAME"

# ============================================================
# ARRANCAR SERVICIO REMOTAMENTE
# ============================================================
step "ARRANCAR LA APLICACIÓN EN EL SERVIDOR"

echo ""
read -rp "  ¿Arrancar/reiniciar el servicio en el servidor ahora? [s/N]: " START_SERVICE

if [[ "$START_SERVICE" == "s" || "$START_SERVICE" == "S" ]]; then
  info "Conectando por SSH para iniciar el servicio..."
  echo -e "  ${YELLOW}Se te pedirá la contraseña SSH del servidor.${NC}"
  echo ""

  ssh -p "$SSH_PORT" "$SERVER_USER@$SERVER_IP" \
    "sudo systemctl restart concesionario && sudo systemctl status concesionario --no-pager"

  [[ $? -ne 0 ]] && warn "No se pudo iniciar remotamente. Hazlo manualmente en el servidor:" && \
                    echo -e "  ${CYAN}sudo systemctl start concesionario${NC}"
fi

# ============================================================
# RESUMEN FINAL
# ============================================================
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║   DESPLIEGUE COMPLETADO                          ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  ${BOLD}Accede a la aplicación desde el cliente en:${NC}"
echo -e "  ${CYAN}http://$SERVER_IP${NC}         ← vía Apache (puerto 80)"
echo -e "  ${CYAN}http://$SERVER_IP:8088${NC}    ← Spring Boot directo"
echo ""
echo -e "  ${BOLD}Comandos útiles en el servidor:${NC}"
echo -e "  Ver logs:      ${CYAN}sudo journalctl -u concesionario -f${NC}"
echo -e "  Reiniciar app: ${CYAN}sudo systemctl restart concesionario${NC}"
echo -e "  Estado:        ${CYAN}sudo systemctl status concesionario${NC}"
echo ""
