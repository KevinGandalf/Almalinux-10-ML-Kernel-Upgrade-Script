# AlmaLinux 10 Mainline Kernel Upgrade Script

**Skript für die sichere Installation des aktuellen Mainline-Kernels (ELRepo `kernel-ml`) auf AlmaLinux 10 und die Deaktivierung des Stock-Kernels 6.12.x.**

Dieses Skript ist die AlmaLinux-10-Portierung des [AlmaLinux-9-Scripts](https://github.com/KevinGandalf/Almalinux-9-ML-Kernel-Upgrade-Script).

## Warum ein Mainline-Kernel?

AlmaLinux 10 (basierend auf RHEL 10) liefert den Kernel in der Linie **6.12.x**. Red Hat/AlmaLinux backporten Sicherheitsfixes und ausgewählte Features, aber neuere Hardware-Unterstützung, Dateisystem-Features (z.B. erweiterte Btrfs-Unterstützung) oder aktuelle Kernel-Entwicklungen fehlen.

Der ELRepo-`kernel-ml` trackt die **mainline stable** Branch von kernel.org (aktuell typischerweise 7.x) und kann parallel zum Distro-Kernel installiert werden.

**Wichtige Einschränkungen:**
- ELRepo-Kernel sind **nicht** von AlmaLinux supportet.
- **Nicht** für Secure Boot signiert → Secure Boot muss deaktiviert sein.
- Nur **x86_64**. Kein `kernel-ml` für aarch64 auf EL10.
- Kein `kernel-lt` (Longterm) für AlmaLinux 10 verfügbar (nur für EL9).

## Unterschiede zu AlmaLinux 9

| Aspekt              | AlmaLinux 9                  | AlmaLinux 10                  |
|---------------------|------------------------------|-------------------------------|
| Stock-Kernel        | 5.14.x                       | 6.12.x                        |
| ELRepo Release      | `elrepo-release-9.el9...`    | `elrepo-release-10.el10...`   |
| GPG-Key             | beide Keys                   | bevorzugt `RPM-GPG-KEY-v2`    |
| Verfügbare Kernel   | `kernel-ml` + `kernel-lt`    | nur `kernel-ml`               |
| Architekturen       | x86_64 + aarch64             | nur x86_64 für kernel-ml      |

## Voraussetzungen

- AlmaLinux 10 (oder RHEL-10-kompatibel) auf **x86_64**
- Root-Rechte
- Ausreichend freier Speicher unter `/boot` (mind. 500 MB empfohlen)
- **Secure Boot deaktiviert** (prüfen mit `mokutil --sb-state`)
- Internetzugang für ELRepo

## Installation & Nutzung

```bash
# Skript herunterladen
curl -O https://raw.githubusercontent.com/KevinGandalf/Almalinux-10-ML-Kernel-Upgrade-Script/main/almalinux10-mainline-only.sh
chmod +x almalinux10-mainline-only.sh

# 1. Trockenlauf (empfohlen)
sudo ./almalinux10-mainline-only.sh --dry-run --all

# 2. Mainline installieren und als Default setzen
sudo ./almalinux10-mainline-only.sh --install-ml --enable-elrepo --set-default -y

# 3. Neustart
sudo reboot

# 4. Prüfen
uname -r          # sollte *.elrepo* oder 7.x sein, nicht 6.12.*
grubby --default-kernel

# 5. Stock-Kernel entfernen und sperren
sudo ./almalinux10-mainline-only.sh --remove-stock --exclude --cleanup -y
```

### Alle Optionen

```bash
sudo ./almalinux10-mainline-only.sh --help
```

Wichtige Optionen:
- `--install-ml` – ELRepo einrichten + `kernel-ml` installieren
- `--enable-elrepo` – `elrepo-kernel` dauerhaft aktivieren (für automatische Updates)
- `--set-default` – Neuesten Mainline als GRUB-Default setzen **und** `DEFAULTKERNEL=kernel-ml` in `/etc/sysconfig/kernel` schreiben
- `--remove-stock` – Alle 6.12-Stock-Kernel-Pakete entfernen (nur wenn bereits Mainline läuft)
- `--keep-one-stock` – Neuesten 6.12 als Fallback behalten
- `--exclude` – Distro-Kernel in DNF `exclude=` sperren
- `--cleanup` – Verwaiste BLS-Einträge und Images entfernen
- `--all` – Alle Phasen (Remove greift erst nach Reboot in Mainline)
- `--dry-run` – Nur anzeigen, nichts ändern
- `--yes` / `-y` – DNF ohne Rückfrage

## Sicherheit

Das Skript ist defensiv gebaut:

- Entfernt **niemals** den aktuell laufenden Kernel.
- Entfernt Stock-Kernel erst, wenn `uname -r` nicht mehr `6.12.*` ist.
- `--dry-run` ändert nichts.
- Rescue-Kernel bleiben erhalten.
- `--force` schützt nicht vor dem Löschen des laufenden Kernels.

## Nach der Installation

1. **Secure Boot prüfen** – muss aus sein, sonst bootet der ELRepo-Kernel nicht.
2. **Out-of-tree Module** (NVIDIA, VirtualBox, ZFS, DKMS etc.) müssen für den neuen Kernel neu gebaut werden.
3. Nach zukünftigen AlmaLinux-Kernel-Updates kann der Default zurückspringen. Das Skript setzt `DEFAULTKERNEL=kernel-ml`, was das in den meisten Fällen verhindert. Trotzdem nach größeren Updates prüfen:
   ```bash
   grubby --default-kernel
   ```
4. Updates des Mainline-Kernels:
   ```bash
   sudo dnf --enablerepo=elrepo-kernel upgrade kernel-ml
   ```
   Oder dauerhaft mit `--enable-elrepo`.

## Rückgängig machen

1. In den Stock-Kernel booten (GRUB-Menü oder `grubby --set-default` auf einen 6.12).
2. Mainline entfernen:
   ```bash
   sudo dnf remove 'kernel-ml*'
   ```
3. `exclude=` Zeile in `/etc/dnf/dnf.conf` und ggf. Repo-Optionen entfernen.
4. `DEFAULTKERNEL` in `/etc/sysconfig/kernel` zurücksetzen.

## Quellen & Weiterführendes

- [ELRepo kernel-ml Wiki](https://elrepo.org/wiki/doku.php?id=kernel-ml)
- [Installing the Mainline kernel on AlmaLinux (ELRepo)](https://www.awh.hu/en/kb/linux/installing-the-mainline-kernel-on-almalinux-from-elrepo)
- Original AlmaLinux 9 Script: https://github.com/KevinGandalf/Almalinux-9-ML-Kernel-Upgrade-Script

## Lizenz

Dieses Skript basiert auf dem AlmaLinux-9-Script des gleichen Autors. Nutzung auf eigene Gefahr. Keine Garantie auf Bootfähigkeit oder Stabilität.

**Immer Backup / Snapshot vor der Ausführung machen!**
