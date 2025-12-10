#!/bin/bash
#############################################
# Script de conversion XLSX vers CSV
# Filtre les lignes avec CSV_State=OK
# Upload automatique via SCP
# Scan Nextcloud automatique
#
# Usage: convert_xlsxtocsv.sh <fichier.xlsx>
#############################################

set -euo pipefail

# ===========================================
# CONFIGURATION
# ===========================================
PHP="/usr/bin/php"
NEXTCLOUD_ROOT="/srv/nextcloud/html"
OCC_CMD="${PHP} -f ${NEXTCLOUD_ROOT}/occ"
LOG_DIR="/srv/nextcloud/scripts/logs"

# Créer le dossier de logs si nécessaire
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/convert_xlstocsv_$(date '+%Y%m%d').log"

# ===========================================
# FONCTIONS DE LOG
# ===========================================
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" | tee -a "$LOG_FILE"
}

# ===========================================
# PARSING DES ARGUMENTS
# ===========================================
INPUT_FILE=""
SCP_DESTINATION=""

# Premier argument = fichier (obligatoire)
if [ $# -lt 1 ]; then
    log_error "Usage: $0 <fichier.xlsx> [--scp destination]"
    exit 1
fi

INPUT_FILE="$1"
shift

# Arguments optionnels
while [[ $# -gt 0 ]]; do
    case $1 in
        --scp)
            SCP_DESTINATION="$2"
            shift 2
            ;;
        *)
            log_error "Option inconnue: $1"
            log_error "Usage: $(basename $0) <fichier.xlsx> [--scp destination]"
            exit 1
            ;;
    esac
done

OUTPUT_FILE="${INPUT_FILE%.xlsx}.csv"

# Vérifier que le fichier existe
if [ ! -f "$INPUT_FILE" ]; then
    log_error "Fichier introuvable: $INPUT_FILE"
    exit 1
fi

# Vérifier que c'est bien un .xlsx
if [[ ! "$INPUT_FILE" =~ \.xlsx$ ]]; then
    log_error "Le fichier doit être au format .xlsx"
    exit 1
fi

log_info "=========================================="
log_info "Début du traitement: $(basename "$INPUT_FILE")"
log_info "=========================================="

# ===========================================
# CONVERSION XLSX → CSV
# ===========================================
TMPFILE_RAW=$(mktemp)
TMPFILE_FILTERED=$(mktemp)

# Fonction de nettoyage en cas d'erreur
cleanup() {
    rm -f "$TMPFILE_RAW" "$TMPFILE_FILTERED"
}
trap cleanup EXIT

log_info "Conversion XLSX → CSV..."

if /usr/bin/python3 -W ignore /usr/bin/xlsx2csv "$INPUT_FILE" -s 1 -i -d ';' > "$TMPFILE_RAW" 2>&1; then
    log_info "✓ Conversion brute réussie"
else
    log_error "Échec de la conversion XLSX → CSV"
    exit 1
fi

# ===========================================
# EXTRACTION DE L'INDEX CSV_State
# ===========================================
log_info "Recherche de la colonne CSV_State..."

HEADER=$(head -n1 "$TMPFILE_RAW")
COL_INDEX=$(echo "$HEADER" | awk -F';' '{
    for(i=1; i<=NF; i++){
        if($i=="CSV_State"){ print i; exit }
    }
}')

if [ -z "$COL_INDEX" ]; then
    log_error "Colonne CSV_State introuvable dans le fichier"
    exit 1
fi

log_info "✓ Colonne CSV_State trouvée en position $COL_INDEX"

# ===========================================
# FILTRAGE DES LIGNES OK
# ===========================================
log_info "Filtrage des lignes avec CSV_State=OK..."

TOTAL_LINES=$(wc -l < "$TMPFILE_RAW")
awk -F';' -v idx="$COL_INDEX" 'NR==1 || $idx=="OK"' "$TMPFILE_RAW" > "$TMPFILE_FILTERED"
FILTERED_LINES=$(wc -l < "$TMPFILE_FILTERED")

log_info "Lignes totales: $((TOTAL_LINES - 1))"
log_info "Lignes conservées: $((FILTERED_LINES - 1))"

# Déplacer le fichier filtré vers la destination
mv "$TMPFILE_FILTERED" "$OUTPUT_FILE"

log_info "✓ CSV généré: $OUTPUT_FILE"

# ===========================================
# UPLOAD SCP (optionnel)
# ===========================================
if [ -n "$SCP_DESTINATION" ]; then
    log_info "Upload SCP vers $SCP_DESTINATION..."
    
    if scp "$OUTPUT_FILE" "$SCP_DESTINATION" >> "$LOG_FILE" 2>&1; then
        log_info "✓ Upload SCP réussi"
    else
        log_warn "Échec de l'upload SCP (non bloquant)"
    fi
else
    log_info "Pas d'upload SCP demandé"
fi

# ===========================================
# SCAN NEXTCLOUD
# ===========================================
log_info "Scan Nextcloud..."

# Cas 1 : GroupFolder
if [[ "$OUTPUT_FILE" =~ /__groupfolders/([0-9]+)/files/(.*) ]]; then
    GF_ID="${BASH_REMATCH[1]}"
    REL_PATH="${BASH_REMATCH[2]}"
    
    log_info "Détection GroupFolder ID=$GF_ID, path=$REL_PATH"
    
    if ${OCC_CMD} groupfolders:scan "$GF_ID" --path="$REL_PATH" >> "$LOG_FILE" 2>&1; then
        log_info "✓ Scan GroupFolder réussi"
    else
        log_warn "Échec du scan GroupFolder"
    fi
    
# Cas 2 : Espace utilisateur
elif [[ "$OUTPUT_FILE" =~ /data/([^/]+)/files/(.*) ]]; then
    USER_ID="${BASH_REMATCH[1]}"
    FILE_PATH="${BASH_REMATCH[2]}"
    
    log_info "Détection espace utilisateur: $USER_ID"
    
    if ${OCC_CMD} files:scan --path="/$USER_ID/files/$FILE_PATH" >> "$LOG_FILE" 2>&1; then
        log_info "✓ Scan utilisateur réussi"
    else
        log_warn "Échec du scan utilisateur"
    fi
    
# Cas inconnu
else
    log_warn "Chemin non reconnu, aucun scan effectué"
fi

log_info "=========================================="
log_info "Traitement terminé avec succès"
log_info "=========================================="

exit 0
