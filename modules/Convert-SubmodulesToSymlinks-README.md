# Convert-SubmodulesToSymlinks PowerShell Module

Dieses Modul konvertiert Git-Submodule zu Symlinks, um Festplattenspeicher zu sparen und die Performance zu verbessern.

## Funktionen

### `Convert-AllSubmodulesToSymlinks`
Konvertiert alle Submodule in einem Repository zu Symlinks.

```powershell
# Basic usage - konvertiert alle Submodule im aktuellen Verzeichnis
Convert-AllSubmodulesToSymlinks

# Mit spezifischem Repository-Pfad
Convert-AllSubmodulesToSymlinks -RepositoryPath "C:\projects\my-repo"

# Mit benutzerdefiniertem Central-Repository-Pfad (überschreibt $ROOTPATH)
Convert-AllSubmodulesToSymlinks -CentralPath "C:\central-repos"

# Dry-run - zeigt was gemacht würde ohne Änderungen
Convert-AllSubmodulesToSymlinks -WhatIf
```

### `Get-SymlinkStatus`
Zeigt den Status aller Submodule (Symlink vs. Regular).

```powershell
Get-SymlinkStatus
```

### `Restore-SubmodulesFromSymlinks`
Stellt Symlinks zurück zu regulären Git-Submodulen.

```powershell
Restore-SubmodulesFromSymlinks
Restore-SubmodulesFromSymlinks -WhatIf  # Dry-run
```

### `Set-CentralRepositoryPath`
Setzt den Pfad für zentrale Repository-Speicherung.

```powershell
Set-CentralRepositoryPath -Path "D:\central-repos"
```

## Workflow

1. **Backup erstellen** (empfohlen):
   ```powershell
   git stash
   ```

2. **Status prüfen**:
   ```powershell
   Get-SymlinkStatus
   ```

3. **Dry-run** um zu sehen was passiert:
   ```powershell
   Convert-AllSubmodulesToSymlinks -WhatIf
   ```

4. **Konvertierung durchführen**:
   ```powershell
   Convert-AllSubmodulesToSymlinks
   ```

5. **Ergebnis prüfen**:
   ```powershell
   Get-SymlinkStatus
   ```

## Verhalten

- **Nutzt bereits vorhandene Repositories in `$ROOTPATH`** - kein zusätzliches Klonen!
- Sucht automatisch nach existierenden Repositories mit verschiedenen Namensmustern
- Bestehende Submodule werden zuerst deinitializiert und entfernt
- Symlinks zeigen auf die bereits vorhandenen Repositories in `$ROOTPATH`
- `.gitmodules` bleibt unverändert
- Funktioniert auf Windows (SymbolicLink) und Unix/macOS (ln -s)
- Klont nur falls Repository nicht in `$ROOTPATH` gefunden wird

## Rückgängig machen

```powershell
Restore-SubmodulesFromSymlinks
```

## Beispiel-Output

```
Converting submodules to symlinks...
Repository: C:\projects\my-repo
Central repository storage: C:\temp\octo-central-repos

Found 3 submodule(s):

Processing submodule: shared-lib
  Path: libs/shared
  URL: https://github.com/company/shared-lib.git
  Cloning to central location...
  Deinitializing submodule...
  Creating symlink...
  ✓ Successfully converted to symlink
```
