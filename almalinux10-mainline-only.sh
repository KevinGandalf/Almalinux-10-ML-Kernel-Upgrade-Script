#!/usr/bin/env bash
# almalinux10-mainline-only.sh
#
# AlmaLinux 10: Stock-Kernel 6.12.x deaktivieren und nur den
# aktuellen Mainline-Kernel (ELRepo kernel-ml) zulassen.
#
# Phasen:
#   1. System prüfen
#   2. Optional ELRepo + kernel-ml installieren
#   3. Mainline als GRUB-Default setzen + DEFAULTKERNEL setzen
#   4. Stock-6.12-Pakete entfernen (nur wenn bereits Mainline läuft)
#   5. Distro-Kernel per DNF exclude sperren
#   6. Verwaiste BLS-/Boot-Einträge aufräumen
#
# Nutzung:
#   sudo ./almalinux10-mainline-only.sh --help
#   sudo ./almalinux10-mainline-only.sh --dry-run
#   sudo ./almalinux10-mainline-only.sh --install-ml --set-default
#   sudo ./almalinux10-mainline-only.sh --all          # nach Reboot in Mainline
#   sudo ./almalinux10-mainline-only.sh --remove-stock --exclude --cleanup
#
# Sicherheit:
#   - Entfernt niemals den laufenden Kernel
#   - Entfernt 6.12 erst, wenn uname -r kein 6.12 mehr ist
#   - --dry-run zeigt alles, ändert nichts
#   - Rescue-Einträge bleiben erhalten
#
# Hinweise AlmaLinux 10 / EL10:
#   - Stock-Kernel ist 6.12.x (nicht 5.14)
#   - Nur kernel-ml verfügbar (kein kernel-lt)
#   - Nur x86_64 (kein aarch64 für kernel-ml)
#   - ELRepo-Kernel sind nicht Secure-Boot-signiert → Secure Boot deaktivieren
#   - Nach Distro-Kernel-Updates kann Default zurückspringen → DEFAULTKERNEL=kernel-ml setzen

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
VERSION="1.0.0"

DRY_RUN=0
DO_INSTALL_ML=0
DO_SET_DEFAULT=0
DO_REMOVE_STOCK=0
DO_EXCLUDE=0
DO_CLEANUP=0
DO_ENABLE_ELREPO=0
FORCE=0
KEEP_ONE_STOCK=0
INSTALLONLY_LIMIT=""
YES=0

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
BLU='\033[0;34m'
NC='\033[0m'

log()  { printf '%b\n' "${BLU}[*]${NC} $*"; }
ok()   { printf '%b\n' "${GRN}[+]${NC} $*"; }
warn() { printf '%b\n' "${YLW}[!]${NC} $*" >&2; }
err()  { printf '%b\n' "${RED}[x]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '%b\n' "${YLW}[dry-run]${NC} $*"
        return 0
    fi
    log "\$ $*"
    eval "$@"
}

need_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Bitte als root ausführen: sudo $SCRIPT_NAME ..."
}

usage() {
    cat <<EOF
$SCRIPT_NAME v$VERSION
AlmaLinux 10: Kernel 6.12.x deaktivieren, nur Mainline (kernel-ml) zulassen.

Optionen:
  --install-ml         ELRepo einrichten und kernel-ml installieren
  --enable-elrepo      elrepo-kernel dauerhaft aktivieren (Updates)
  --set-default        Neuesten Mainline-/elrepo-Kernel als GRUB-Default setzen
                       und DEFAULTKERNEL=kernel-ml in /etc/sysconfig/kernel setzen
  --remove-stock       Alle Stock-Kernel 6.12.x entfernen
  --keep-one-stock     Bei --remove-stock den neuesten 6.12 als Fallback behalten
  --exclude            Distro-kernel* in DNF exclude (kommt nicht mehr zurück)
  --cleanup            Verwaiste /boot/loader/entries/*-6.12* entfernen
  --installonly N      installonly_limit in /etc/dnf/dnf.conf setzen (z.B. 2)
  --all                --install-ml --enable-elrepo --set-default
                       --remove-stock --exclude --cleanup
                       (Remove greift erst, wenn bereits Mainline läuft)
  --dry-run            Nichts ändern, nur anzeigen
  --force              Weniger Nachfragen / Warnungen überspringen
  --yes, -y            dnf ohne Rückfrage (-y)
  --help, -h           Diese Hilfe
  --version            Version anzeigen

Empfohlener Ablauf:
  1) sudo $SCRIPT_NAME --dry-run --all
  2) sudo $SCRIPT_NAME --install-ml --enable-elrepo --set-default -y
  3) reboot
  4) uname -r   # muss *.elrepo* oder 7.x (o.ä.) sein, nicht 6.12
  5) sudo $SCRIPT_NAME --remove-stock --exclude --cleanup -y

Wichtige Hinweise:
  - Secure Boot muss deaktiviert sein (ELRepo-Kernel sind nicht signiert).
  - Nur für x86_64. aarch64 wird von ELRepo kernel-ml auf EL10 nicht unterstützt.
  - Kein kernel-lt für AlmaLinux 10 verfügbar.

EOF
}

parse_args() {
    [[ $# -eq 0 ]] && { usage; exit 1; }
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install-ml)      DO_INSTALL_ML=1 ;;
            --enable-elrepo)   DO_ENABLE_ELREPO=1 ;;
            --set-default)     DO_SET_DEFAULT=1 ;;
            --remove-stock)    DO_REMOVE_STOCK=1 ;;
            --keep-one-stock)  KEEP_ONE_STOCK=1 ;;
            --exclude)         DO_EXCLUDE=1 ;;
            --cleanup)         DO_CLEANUP=1 ;;
            --installonly)
                shift
                [[ "${1:-}" =~ ^[0-9]+$ ]] || die "--installonly erwartet eine Zahl"
                INSTALLONLY_LIMIT="$1"
                ;;
            --all)
                DO_INSTALL_ML=1
                DO_ENABLE_ELREPO=1
                DO_SET_DEFAULT=1
                DO_REMOVE_STOCK=1
                DO_EXCLUDE=1
                DO_CLEANUP=1
                ;;
            --dry-run)         DRY_RUN=1 ;;
            --force)           FORCE=1 ;;
            --yes|-y)          YES=1 ;;
            --help|-h)         usage; exit 0 ;;
            --version)         echo "$VERSION"; exit 0 ;;
            *)                 die "Unbekannte Option: $1 (siehe --help)" ;;
        esac
        shift
    done
}

dnf_yes() {
    if [[ "$YES" -eq 1 ]]; then
        echo "-y"
    else
        echo ""
    fi
}

is_almalinux10() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [[ "${ID:-}" == "almalinux" && "${VERSION_ID:-}" == 10* ]]; then
            return 0
        fi
        if [[ "${ID_LIKE:-}" == *rhel* && "${VERSION_ID:-}" == 10* ]]; then
            warn "Kein AlmaLinux, aber RHEL-10-kompatibel (${ID:-} ${VERSION_ID:-}). Fahre fort."
            return 0
        fi
    fi
    return 1
}

running_kver() {
    uname -r
}

is_running_stock_612() {
    [[ "$(running_kver)" == 6.12.* ]]
}

is_running_mainline() {
    local k
    k="$(running_kver)"
    [[ "$k" == *elrepo* || "$k" == *mainline* || "$k" =~ ^[7-9][.] || "$k" =~ ^[1-9][0-9][.] ]]
}

list_vmlinuz_mainline() {
    shopt -s nullglob
    local f
    for f in /boot/vmlinuz-*elrepo* /boot/vmlinuz-*mainline*; do
        [[ -e "$f" ]] && printf '%s\n' "$f"
    done
    # selbst gebaute 7.x/6.x ohne elrepo-Tag, aber nicht Distro-6.12
    for f in /boot/vmlinuz-[6-9].* /boot/vmlinuz-[1-9][0-9].*; do
        [[ -e "$f" ]] || continue
        [[ "$f" == *el10_* && "$f" != *elrepo* ]] && continue
        printf '%s\n' "$f"
    done | sort -u
}

newest_mainline_vmlinuz() {
    list_vmlinuz_mainline | awk -F/ '{print $NF"\t"$0}' | sort -V | tail -1 | cut -f2-
}

list_stock_612_rpms() {
    rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' \
        kernel kernel-core kernel-modules kernel-modules-core \
        kernel-modules-extra kernel-devel kernel-modules-internal \
        2>/dev/null | grep -E '^kernel.*-6\.12\.' || true
}

newest_stock_612_core() {
    rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core 2>/dev/null \
        | grep '^6\.12\.' | sort -V | tail -1 || true
}

phase_check() {
    log "Systemprüfung"
    echo "    OS:           $(. /etc/os-release; echo "${PRETTY_NAME:-unbekannt}")"
    echo "    Laufender K.: $(running_kver)"
    echo "    Default GRUB: $(grubby --default-kernel 2>/dev/null || echo unbekannt)"
    echo "    /boot frei:   $(df -h /boot | awk 'NR==2{print $4}')"
    if command -v mokutil >/dev/null 2>&1; then
        echo "    Secure Boot:  $(mokutil --sb-state 2>/dev/null || echo unbekannt)"
    fi
    echo
    echo "    Installierte Kernel-RPMs:"
    rpm -qa --qf '      %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' \
        'kernel*' 2>/dev/null | sort | sed '/^$/d' || true
    echo
    echo "    GRUB/BLS-Einträge:"
    if command -v grubby >/dev/null 2>&1; then
        grubby --info=ALL 2>/dev/null | grep -E '^index|^kernel|^title' \
            | sed 's/^/      /' || true
    fi
    echo
}

phase_install_ml() {
    log "Phase: ELRepo + kernel-ml"
    if ! command -v dnf >/dev/null 2>&1; then
        die "dnf nicht gefunden"
    fi

    if ! rpm -q elrepo-release >/dev/null 2>&1; then
        # Für EL10 wird der v2-Key benötigt (älterer Key wird wegen SHA1 abgelehnt)
        run "rpm --import https://www.elrepo.org/RPM-GPG-KEY-v2-elrepo.org"
        run "dnf install $(dnf_yes) https://www.elrepo.org/elrepo-release-10.el10.elrepo.noarch.rpm"
    else
        ok "elrepo-release bereits installiert"
    fi

    if rpm -q kernel-ml >/dev/null 2>&1 || rpm -q kernel-ml-core >/dev/null 2>&1; then
        ok "kernel-ml bereits installiert: $(rpm -q kernel-ml-core 2>/dev/null || rpm -q kernel-ml)"
        run "dnf --enablerepo=elrepo-kernel upgrade $(dnf_yes) kernel-ml kernel-ml-core kernel-ml-modules || true"
    else
        run "dnf --enablerepo=elrepo-kernel install $(dnf_yes) kernel-ml kernel-ml-core kernel-ml-modules"
    fi
}

phase_enable_elrepo() {
    log "Phase: elrepo-kernel dauerhaft aktivieren"
    if command -v dnf >/dev/null 2>&1; then
        run "dnf config-manager --set-enabled elrepo-kernel"
        ok "elrepo-kernel enabled"
    fi
}

phase_set_default() {
    log "Phase: Mainline als GRUB-Default"
    command -v grubby >/dev/null 2>&1 || die "grubby fehlt (grub2-tools / grubby installieren)"

    local target
    target="$(newest_mainline_vmlinuz || true)"
    if [[ -z "$target" ]]; then
        die "Kein Mainline-/elrepo-vmlinuz unter /boot gefunden. Zuerst --install-ml oder Kernel manuell installieren."
    fi
    if [[ ! -e "$target" ]]; then
        die "vmlinuz nicht gefunden: $target"
    fi

    log "Setze Default auf: $target"
    run "grubby --set-default '$target'"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        ok "Default ist jetzt: $(grubby --default-kernel)"
    fi

    # Verhindere, dass Distro-Updates den Default zurück auf Stock setzen
    local sysconfig=/etc/sysconfig/kernel
    if [[ -f "$sysconfig" ]]; then
        if grep -q '^DEFAULTKERNEL=' "$sysconfig"; then
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo "[dry-run] sed -i 's/^DEFAULTKERNEL=.*/DEFAULTKERNEL=kernel-ml/' $sysconfig"
            else
                sed -i 's/^DEFAULTKERNEL=.*/DEFAULTKERNEL=kernel-ml/' "$sysconfig"
                ok "DEFAULTKERNEL=kernel-ml in $sysconfig gesetzt"
            fi
        else
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo "[dry-run] echo 'DEFAULTKERNEL=kernel-ml' >> $sysconfig"
            else
                echo 'DEFAULTKERNEL=kernel-ml' >> "$sysconfig"
                ok "DEFAULTKERNEL=kernel-ml in $sysconfig gesetzt"
            fi
        fi
    else
        warn "$sysconfig nicht gefunden – DEFAULTKERNEL nicht gesetzt"
    fi
}

rpm_running_matches() {
    local pkg="$1"
    local run
    run="$(running_kver)"
    [[ "$pkg" == *"${run}"* ]]
}

phase_remove_stock() {
    log "Phase: Stock-Kernel 6.12 entfernen"

    if is_running_stock_612; then
        err "Es läuft noch ein 6.12-Kernel ($(running_kver))."
        err "Zuerst --set-default, reboot, dann --remove-stock erneut ausführen."
        if [[ "$FORCE" -eq 1 ]]; then
            die "--force schützt nicht vor dem Entfernen des laufenden Kernels."
        fi
        return 1
    fi

    if ! is_running_mainline && [[ "$FORCE" -eq 0 ]]; then
        warn "Laufender Kernel sieht nicht nach Mainline aus: $(running_kver)"
        die "Zum Fortfahren nach Reboot in Mainline oder --force (nicht empfohlen)."
    fi

    local pkgs keep_ver keep_pkgs=() remove_pkgs=() p
    mapfile -t pkgs < <(list_stock_612_rpms)

    if [[ ${#pkgs[@]} -eq 0 ]]; then
        ok "Keine 6.12-Stock-Kernel-RPMs gefunden."
        return 0
    fi

    if [[ "$KEEP_ONE_STOCK" -eq 1 ]]; then
        keep_ver="$(newest_stock_612_core)"
        if [[ -n "$keep_ver" ]]; then
            log "Behalte neuesten Stock-Kernel als Fallback: $keep_ver"
        fi
    fi

    for p in "${pkgs[@]}"; do
        if rpm_running_matches "$p"; then
            warn "Überspringe laufenden Kernel-Teil: $p"
            continue
        fi
        if [[ "$KEEP_ONE_STOCK" -eq 1 && -n "${keep_ver:-}" && "$p" == *"$keep_ver"* ]]; then
            keep_pkgs+=("$p")
            continue
        fi
        remove_pkgs+=("$p")
    done

    if [[ ${#keep_pkgs[@]} -gt 0 ]]; then
        log "Fallback bleibt:"
        printf '      %s\n' "${keep_pkgs[@]}"
    fi

    if [[ ${#remove_pkgs[@]} -eq 0 ]]; then
        ok "Nichts zu entfernen."
        return 0
    fi

    log "Entferne:"
    printf '      %s\n' "${remove_pkgs[@]}"
    run "dnf remove $(dnf_yes) ${remove_pkgs[*]}"
}

phase_exclude() {
    log "Phase: Distro-Kernel per DNF exclude sperren"

    local conf=/etc/dnf/dnf.conf
    local exclude_pkgs="kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-devel"
    # kernel-headers bewusst nicht ausgeschlossen (glibc / Userspace)

    if [[ ! -f "$conf" ]]; then
        die "$conf fehlt"
    fi

    if grep -E '^exclude=.*\bkernel\b' "$conf" >/dev/null 2>&1; then
        ok "exclude= für kernel* bereits in $conf vorhanden"
    else
        if grep -E '^exclude=' "$conf" >/dev/null 2>&1; then
            warn "Es gibt bereits eine exclude=-Zeile in $conf – bitte manuell um kernel* ergänzen."
            grep -n '^exclude=' "$conf" || true
        else
            log "Schreibe exclude= nach $conf"
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo "[dry-run] echo exclude=$exclude_pkgs >> $conf"
            else
                printf '\n# %s: Distro-Kernel nicht mehr installieren (Mainline bleibt erlaubt)\nexclude=%s\n' \
                    "$SCRIPT_NAME" "$exclude_pkgs" >> "$conf"
                ok "exclude gesetzt"
            fi
        fi
    fi

    # Zusätzlich in Alma-Repos, falls config-manager verfügbar
    if command -v dnf >/dev/null 2>&1; then
        local repo
        for repo in baseos appstream; do
            if dnf repolist --enabled 2>/dev/null | awk '{print $1}' | grep -qx "$repo"; then
                run "dnf config-manager --save --setopt=${repo}.exclude=${exclude_pkgs// /,}"
            fi
        done
    fi

    if [[ -n "$INSTALLONLY_LIMIT" ]]; then
        if grep -q '^installonly_limit=' "$conf"; then
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo "[dry-run] sed -i installonly_limit=$INSTALLONLY_LIMIT $conf"
            else
                sed -i "s/^installonly_limit=.*/installonly_limit=${INSTALLONLY_LIMIT}/" "$conf"
            fi
        else
            if [[ "$DRY_RUN" -eq 1 ]]; then
                echo "[dry-run] echo installonly_limit=$INSTALLONLY_LIMIT >> $conf"
            else
                echo "installonly_limit=${INSTALLONLY_LIMIT}" >> "$conf"
            fi
        fi
        ok "installonly_limit=${INSTALLONLY_LIMIT}"
    fi
}

phase_cleanup() {
    log "Phase: verwaiste BLS-Einträge 6.12"

    shopt -s nullglob
    local e leftovers=()
    for e in /boot/loader/entries/*-6.12.0-*.conf /boot/loader/entries/*6.12.0*.conf; do
        [[ -f "$e" ]] || continue
        leftovers+=("$e")
    done

    if [[ ${#leftovers[@]} -eq 0 ]]; then
        ok "Keine 6.12-BLS-Einträge gefunden."
    else
        local running
        running="$(running_kver)"
        for e in "${leftovers[@]}"; do
            if [[ "$e" == *"$running"* ]]; then
                warn "Überspringe BLS des laufenden Kernels: $e"
                continue
            fi
            if [[ "$KEEP_ONE_STOCK" -eq 1 ]]; then
                local keep_ver
                keep_ver="$(newest_stock_612_core)"
                if [[ -n "$keep_ver" && "$e" == *"$keep_ver"* ]]; then
                    log "Behalte Fallback-BLS: $e"
                    continue
                fi
            fi
            run "rm -f '$e'"
        done
    fi

    # verwaiste 6.12-Images, wenn RPM schon weg
    local img
    for img in /boot/vmlinuz-6.12.0-* /boot/initramfs-6.12.0-*.img /boot/System.map-6.12.0-*; do
        [[ -e "$img" ]] || continue
        local base ver
        base="$(basename "$img")"
        ver="${base#vmlinuz-}"
        ver="${ver#initramfs-}"
        ver="${ver#System.map-}"
        ver="${ver%.img}"
        if rpm -q "kernel-core-${ver}" >/dev/null 2>&1 || rpm -q "kernel-${ver}" >/dev/null 2>&1; then
            continue
        fi
        if [[ "$img" == *"$(running_kver)"* ]]; then
            continue
        fi
        run "rm -f '$img'"
    done
}

print_next_steps() {
    echo
    log "Nächste Schritte"
    if is_running_stock_612; then
        echo "    Es läuft noch 6.12. Bitte rebooten, damit Mainline aktiv wird:"
        echo "      reboot"
        echo "    Danach prüfen:  uname -r"
        echo "    Dann Stock entfernen:"
        echo "      sudo $SCRIPT_NAME --remove-stock --exclude --cleanup -y"
    else
        echo "    Aktueller Kernel: $(running_kver)"
        echo "    Default GRUB:     $(grubby --default-kernel 2>/dev/null || echo '?')"
        echo "    Secure Boot: falls der neue Kernel nicht startet, Secure Boot deaktivieren"
        echo "      mokutil --sb-state"
        echo "    Out-of-tree-Module (NVIDIA, VirtualBox, ZFS) neu bauen."
    fi
}

main() {
    parse_args "$@"
    [[ "$DRY_RUN" -eq 1 ]] || need_root

    if ! is_almalinux10; then
        if [[ "$FORCE" -eq 1 ]]; then
            warn "Kein AlmaLinux 10 erkannt – fahre wegen --force fort."
        else
            die "Dieses Skript ist für AlmaLinux 10 gedacht. --force zum Überschreiben."
        fi
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        warn "DRY-RUN: es werden keine Änderungen geschrieben."
    fi

    phase_check

    [[ "$DO_INSTALL_ML" -eq 1 ]]    && phase_install_ml
    [[ "$DO_ENABLE_ELREPO" -eq 1 ]] && phase_enable_elrepo
    [[ "$DO_SET_DEFAULT" -eq 1 ]]   && phase_set_default
    if [[ "$DO_REMOVE_STOCK" -eq 1 ]]; then
        phase_remove_stock || true
    fi
    [[ "$DO_EXCLUDE" -eq 1 ]]       && phase_exclude
    [[ "$DO_CLEANUP" -eq 1 ]]       && phase_cleanup

    echo
    ok "Fertig ($SCRIPT_NAME v$VERSION)."
    print_next_steps
}

main "$@"
