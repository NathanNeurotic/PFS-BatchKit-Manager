# APA/PFS Toolchain Baseline & Inventory

## 1. Repository Inventory & Baseline Commit References

### 1.1 `NathanNeurotic/pfsshell`
- **Location**: `C:\Users\natha\Github\pfsshell`
- **Current HEAD**: `7586a0dfd764c2154e044034d6b7f39eafdfb098` (branch `ext2`)
- **Default Branch**: `master` (`8192de3907a05bb1844afcb1ae490179a38d4ed6`)
- **Authoritative Upstream**: `ps2homebrew/master` at `8c92467b7e0c4632eaec55b4105b452813589b21`
- **Remotes**:
  - `origin`: `https://github.com/NathanNeurotic/pfsshell.git`
  - `akuhak`: `https://github.com/AKuHAK/pfsshell.git`
  - `ps2homebrew`: `https://github.com/ps2homebrew/pfsshell.git`
- **Historical Branch**: `origin/8Mb` (HEAD commit `cc230c3`, containing `9ec999a Add support for 8Mb, 16Mb, 32Mb, 64Mb sizes`)
- **Audit Findings on Historical 8Mb Branch**:
  - The expansion of `sizesString` and `sizesMB` to 13 entries (`8M` .. `32G`) in `src/shell.c` left the search loop index initialization at `int i = 9;`. This caused partition sizes greater than 4 GB to bypass the initial 1-entry partition creation branch, creating smaller partitions than requested.
  - Fix requirement: Dynamically derive loop bounds using `sizeof(sizesMB) / sizeof(sizesMB[0])` and validate all 13 sizes (`8M`, `16M`, `32M`, `64M`, `128M`, `256M`, `512M`, `1G`, `2G`, `4G`, `8G`, `16G`, `32G`).

---

### 1.2 `NathanNeurotic/hdl-dump`
- **Location**: `C:\Users\natha\Github\hdl-dump`
- **Current HEAD**: `ab3eed6c49da4517a31313830f2bb39fece0d063` (branch `8M_ext2`)
- **Default Branch**: `master` (`32c296c09b83b381a177218698ee07955519171f`)
- **Authoritative Upstream**: `ps2homebrew/master` at `32c296c09b83b381a177218698ee07955519171f`
- **Remotes**:
  - `origin`: `https://github.com/NathanNeurotic/hdl-dump.git`
  - `akuhak`: `https://github.com/AKuHAK/hdl-dump.git`
  - `ps2homebrew`: `https://github.com/ps2homebrew/hdl-dump.git`
- **Historical References**:
  - `origin/8M` (HEAD commit `ef543b2`, containing `9400399`, `e3b6980`, `cf85464`, `6f7ecb2`, `b12cf60`)
  - GDX DVD9 stable reference: `f976afefd2cec50d4574f76a598da73c4e99d703`
  - Upstream DVD9 layer_break fix: `fd285d00ba97612e479f135faeb848e70e677504` (`strlen(input) - 4` fix)
- **Audit Findings on Historical 8M Branch**:
  - **Critical Boundary Issue**: Historical commit `9400399` erroneously substituted the 128 GiB primary APA slice boundary (`EXACTLY_128MB = 128 * 1024 * 1024 KB = 128 GiB`) in `apa_slice_read()` with `8 * 1024 * 1024 KB` (8 GB), confusing allocation chunk granularity with the LBA28 primary slice boundary.
  - **Classification Requirement**:
    - *Allocation / Chunk Granularity*: 8 MiB = 16,384 sectors (`((8 _MB) / 512)`). Used for slice chunk map, free space, partition length validation, and TOC step size.
    - *APA Primary Slice Boundary*: 128 GiB = 2^28 sectors = `0x10000000` sectors. Must remain strictly `128 * 1024 * 1024 KB`. Renamed to `EXACTLY_128GB_KB` to prevent accidental mutation.

---

### 1.3 `NathanNeurotic/PFS-BatchKit-Manager`
- **Location**: `C:\Users\natha\Github\PFS-BatchKit-Manager`
- **Current HEAD**: `5e7e835ced587bb4784fe24489e0918ca0d44e2c` (branch `main`)
- **Remotes**:
  - `origin`: `https://github.com/NathanNeurotic/PFS-BatchKit-Manager.git`
  - `gdx`: `https://github.com/GDX-X/PFS-BatchKit-Manager.git`

---

## 2. Bundled Tool Binaries & PE Architecture Inspection

Inspection of PE machine type headers (`0x3C -> +0x04`) in `PFS-BatchKit-Manager/BAT/`:

| Executable | Architecture | Size (Bytes) | Role / Invocation Context |
| :--- | :--- | :--- | :--- |
| `pfsshell.exe` | **x86 (32-bit)** | 907,318 | Primary PFS filesystem tool: `mkpart`, `mount`, `umount`, `put`, `get`, `mkdir`, `ls`, `rmpart`, `rm`. |
| `hdl_dump.exe` | **x86 (32-bit)** | 403,848 | Primary APA tool: `query`, `hdl_toc`, `toc`, `modify_header` (games), `extract`, `diag`, `inject_mbr`. |
| `hdl_dump_stable.exe` | **x86 (32-bit)** | 402,824 | Legacy fallback: specifically used for non-ZSO DVD9 installs (line 1680) and `copy_hdd` (line 2069). |
| `hdl_dump_fix_header.exe`| **x86 (32-bit)** | 787,998 | Specialized tool: used for `dump_header` and `modify_header` on non-game PFS partitions (`__.POPS`, `PP.UAPP...`). |
| `genvmc.exe` | **x86 (32-bit)** | 54,325 | VMC generator. |
| `pfsfuse.exe` | **x86 (32-bit)** | 624,508 | PFS Dokan/FUSE driver. |

*Finding*: PBKM tooling operates in 32-bit x86 Windows PE mode. All newly built binaries must match or be verified against this architecture.

---

## 3. Tool Invocation Mapping in PFS-BatchKit-Manager

### 3.1 `pfsshell` Invocation Sites
- **`!PFS-BatchKit-Manager.bat`**:
  - Line 239: Sets drive target: `@pfsshell_path=\\.\PhysicalDrive%NumberPS2HDD%`
  - Line 1748: OPL config directory and file sync.
  - Line 2484: Apps directory listing and sync (`pfs-apps.txt`).
  - Lines 2518, 2547, 2576, 2604, 2633, 2696: Syncing ART, CFG, CHT, LNG, VMC, and THM resources.
  - Line 2840, 3022, 3427, 3509, 4245: POPS game VCD listing, installation, and verification.
  - Line 3140-3184: POPS VMC folder creation and save data sync.
  - Line 3738: POPS binary verification (`POPS.ELF`, `IOPRP252.IMG`).
  - Line 4078, 4174: Partition creation (`mkpart "!PartName!" !PartSize! PFS`) and deletion (`rmpart`).
  - Line 8773: POPS single-game partition creation (`mkpart "!PartName!" !PartSize!M PFS`).
  - Line 9182: Homebrew app partition creation (`mkpart !PPName! !partsize! PFS`).
  - Line 10035: Header update partition creation (`mkpart "!PartName!" 128M PFS`).
- **`BAT/APPS.BAT`**:
  - Line 805-806: Application partition creation (`mkpart !PartName! !partsize! PFS`).

### 3.2 `hdl_dump` Invocation Sites
- **`!PFS-BatchKit-Manager.bat`**:
  - Line 182, 185, 222, 243, 1268, 1783, 1797, 1846, 1856, 1974, 1984, 2138, 2726, 3059, 3219, 3381, 3541, 3619, 3795, 3916, 4110, 4205, 4320, 4697, 5115, 5375, 5495, 5533: Drive scanning and validation (`hdl_dump query`).
  - Line 1469: Game list enumeration (`hdl_dump hdl_toc !@hdl_path!`).
  - Line 1532: Disc metadata query (`hdl_dump cdvd_info2 ".\\!fname!.!ext!"`).
  - Line 1682: Game installation (`!hdl_dump! inject_!disctype! !@hdl_path! "!title!" "!fname!.!ext!" !gameid! *u4 !GameHide!`).
  - Line 1690, 2103, 5460: Game header update (`hdl_dump modify_header !@hdl_path! "!GPartName!"`).
  - Line 2002, 2083: Partition TOC query (`hdl_dump toc !hdlhdd2!`).
  - Line 3877: Game ISO extraction (`hdl_dump extract !@hdl_path! "!pname!" "!HDDPATHOUTPUT!\\!GameName! - [!fname:~0,11!].iso"`).
  - Line 4080: Partition visibility unhiding (`hdl_dump modify !@hdl_path! "__.!PartName:~3!" -unhide`).
  - Line 4301: Partition scan / diagnosis (`hdl_dump diag %@hdl_path%`).
  - Line 4346: MBR injection/dump (`hdl_dump %MBR%_mbr %@hdl_path% "%~dp0\\__MBR.KELF"`).

### 3.3 `hdl_dump_stable.exe` Specific Call Sites
- Line 1680: Fallback for non-ZSO DVD installations (`if exist !fname!.zso (set hdl_dump=hdl_dump) else (set hdl_dump=hdl_dump_stable)`).
- Line 2069: Drive-to-drive game copying (`hdl_dump_stable copy_hdd !hdlhdd! !hdlhdd2! !GameSelected!`).

### 3.4 `hdl_dump_fix_header.exe` Specific Call Sites
- Lines 2100, 5663, 7361, 9761: Dumping headers (`dump_header !@hdl_path! "!PartName!"`).
- Lines 5721, 5724, 7438, 10111: Modifying headers on non-game partitions (`modify_header !@hdl_path! "__.!PartName:~3!"`).

---

## 4. Implemented Command Tables in Built Tools

### 4.1 `pfsshell` (`src/shell.c`)
Commands verified directly in `CMD[]` table:
1. `device <path>`: Opens raw disk device or disk image file.
2. `initialize [yes]`: Formats drive with standard APA structure (`__mbr`, `__net`, `__system`, `__sysconf`, `__common`).
3. `mkpart <name> <size> <fstype>`: Creates APA partition of specified size (`8M`..`32G`) and filesystem type (`PFS`, `CFS`, `HDL`, `REISER`, `EXT2`, `EXT2SWAP`, `MBR`).
4. `mount <partition>`: Mounts PFS filesystem on partition.
5. `umount`: Unmounts currently mounted PFS partition.
6. `ls [path]`: Lists files and subdirectories.
7. `mkdir <path>`: Creates a directory on mounted PFS partition.
8. `rmdir <path>`: Removes a directory.
9. `pwd`: Displays current PFS working directory.
10. `cd <path>`: Changes PFS working directory.
11. `get <remote> [local]`: Extracts file from PFS to host.
12. `put <local> [remote]`: Writes file from host into PFS.
13. `rm <path>`: Deletes file from PFS.
14. `rmpart <partition>`: Deletes APA partition.
15. `df`: Displays free space on mounted partition or entire HDD.
16. `rename <old> <new>`: Renames an APA partition.
17. `lcd [path]`: Changes local host working directory.
18. `help`: Lists available commands.

### 4.2 `hdl-dump` (`hdl_dump.c`)
Commands verified directly in dispatch table:
1. `query`: Scans host system and lists attached PS2-formatted hard drives (`\\.\PhysicalDriveN` / `hddN:`).
2. `toc <device>`: Dumps full partition TOC including raw APA headers.
3. `hdl_toc <device>`: Lists installed HDL game partitions with sizes, startup ELFs, and flags.
4. `extract <device> <game> <iso_file>`: Extracts game partition to ISO.
5. `inject_cd <device> <name> <iso_file> <startup_elf> [dma] [-hide]`: Installs CD game.
6. `inject_dvd <device> <name> <iso_file> <startup_elf> [dma] [-hide]`: Installs DVD5/DVD9 game.
7. `install <device> <ps2_app_dir>`: Installs game from local folder.
8. `cdvd_info <file>` / `cdvd_info2 <file>`: Reads game ID, title, and volume descriptor from ISO.
9. `power_off <ip>`: Sends power-off signal to remote PS2.
10. `inject_mbr <device> <mbr_kelf>`: Writes MBR kelf program.
11. `dump_mbr <device> <mbr_kelf>`: Dumps current MBR.
12. `backup_toc <device> <file>`: Dumps partition table to backup file.
13. `restore_toc <device> <file>`: Restores partition table from backup.
14. `diag <device>`: Scans and reports partition table inconsistencies.
15. `modify <device> <game> [new_name] [new_flags] [dma] [-hide/-unhide]`: Updates game name, flags, and visibility.
16. `modify_header <device> <partition_name>`: Injects custom icon/system headers into partition.
17. `dump_header <device> <partition_name>`: Dumps partition header contents.
18. `copy_hdd <src_device> <dst_device> [flags]`: Copies games directly between two PS2 HDDs.

---

## 5. Platform Differences: Windows vs. Linux

1. **Device Path Resolution**:
   - *Windows*: Raw physical disks are accessed via `\\.\PhysicalDriveN`. `hdl-dump` accepts `hddN:` and resolves it via Win32 `CreateFile` in `hio_win32.c` / `iin_spti.c`. `pfsshell` takes `\\.\PhysicalDriveN` or virtual image file paths.
   - *Linux*: Raw disks are accessed via `/dev/sdX` or `/dev/loopX`.
2. **File Stream Binary Modes**:
   - *Windows*: Standard streams and file descriptors require `_O_BINARY` or `"rb"/"wb"` flags to prevent `\r\n` CRLF translation from corrupting binary APA/PFS sector structures.
   - *Linux*: All I/O is raw binary by default.
3. **Privilege Requirements**:
   - *Windows*: Raw disk access (`\\.\PhysicalDriveN`) requires elevated Administrator privileges.
4. **Filesystem Independence**:
   - Windows cannot natively mount or format APA/PFS partitions or mixed exFAT/APA drives. All operations must route strictly through raw sector access in `pfsshell` and `hdl_dump`.

---

## 6. Partition Size Assumptions in PFS-BatchKit-Manager

Prior to this integration, PBKM batch scripts assumed:
1. Minimum user-created partition size was **128 MiB**.
2. Menu prompts in `!PFS-BatchKit-Manager.bat` (lines 4041-4059, 9028-9039) instructed users that partition sizes "must be multiplied by 128" and gave examples starting at `128M`.
3. Default app partition allocation in `BAT/APPS.BAT` (lines 88, 102, 138, 152, 392, 440, 454, 806) defaulted to `128M`.

*Integration Goal*: Expose `8M`, `16M`, `32M`, `64M` choices in partition creation menus while maintaining full backward compatibility with all existing `128M`+ options.
