# elilo 3.17 — EFI Linux Loader

elilo is an EFI/UEFI bootloader for Linux. It loads the kernel and initrd
directly from the EFI System Partition (ESP) and passes control to the kernel
via the EFI Handover Protocol.

This is version 3.17, updated in 2026 to boot Linux 6.x on modern UEFI
firmware. See the [Changes from 3.14](#changes-from-314) section for a full
account of what was fixed and why.

elilo is distributed under the GNU General Public License version 2 (or, at
your option, any later version). See [License & Credits](#license--credits)
for the full list of copyright holders.

---

## Table of Contents

1. [Requirements](#requirements)
2. [Building from Source](#building-from-source)
3. [Installation](#installation)
   - [Coexisting with GRUB](#coexisting-with-grub)
   - [Finding Your EFI System Partition](#finding-your-efi-system-partition)
   - [Installing the Bootloader Files](#installing-the-bootloader-files)
   - [Writing elilo.conf](#writing-eliloconf)
   - [Registering with the UEFI Boot Manager](#registering-with-the-uefi-boot-manager)
4. [Keeping elilo Up to Date After a Kernel Upgrade](#keeping-elilo-up-to-date-after-a-kernel-upgrade)
5. [Partition Naming Reference](#partition-naming-reference)
6. [Changes from 3.14](#changes-from-314)
7. [Comparison with Slackware 15.0](#comparison-with-slackware-150)
8. [License & Credits](#license--credits)

---

## Requirements

- x86_64 UEFI firmware (version 2.0 or later)
- Linux kernel 3.3 or later (boot protocol 2.12+, EFI Handover Protocol)
- Tested with Linux 6.12 on Devuan Excalibur / Debian Trixie

To build from source:

- `gnu-efi` >= 3.0.18 (tested with `gnu-efi_3.0.18-1+deb13u1` from Debian Trixie)
- GCC 12 or later
- binutils with x86_64 EFI support

---

## Building from Source

```bash
sudo apt-get install gnu-efi build-essential

cd elilo
make ARCH=x86_64
```

This produces `elilo.efi` in the top-level directory.

---

## Installation

### Coexisting with GRUB

**You do not need to remove GRUB to install elilo.** UEFI firmware maintains an
ordered list of boot entries. You can add elilo as an additional entry and keep
GRUB intact. If elilo fails to boot, simply select GRUB from the UEFI boot menu
(usually reached by pressing F12, F9, Esc, or Del at startup depending on your
firmware).

To set the default boot entry back to GRUB at any time:

```bash
# List all boot entries
efibootmgr

# Set GRUB as default (replace XXXX with GRUB's entry number)
sudo efibootmgr --bootorder XXXX,YYYY,...
```

It is strongly recommended to verify elilo boots correctly before removing any
existing GRUB entry.

---

### Finding Your EFI System Partition

The EFI System Partition (ESP) is a FAT32 partition with the EFI System
partition type flag. Find it with:

```bash
lsblk -o NAME,FSTYPE,PARTTYPE,MOUNTPOINT
```

or:

```bash
sudo fdisk -l | grep -i efi
```

Common locations:

| Device type | Typical ESP device |
|---|---|
| SATA / SCSI SSD or HDD | `/dev/sda1` |
| Second SATA drive | `/dev/sdb1` |
| NVMe SSD | `/dev/nvme0n1p1` |
| Second NVMe | `/dev/nvme1n1p1` |
| eMMC (embedded, tablets/netbooks) | `/dev/mmcblk0p1` |
| SD card | `/dev/mmcblk1p1` |

The ESP is almost always the first partition. If you are unsure, check that the
partition is FAT32 and is mounted at `/boot/efi`:

```bash
mount | grep efi
# or
cat /etc/fstab | grep efi
```

If the ESP is not already mounted, mount it:

```bash
sudo mount /dev/sdXY /boot/efi
```

---

### Installing the Bootloader Files

Create a directory for elilo on the ESP and install the files:

```bash
sudo mkdir -p /boot/efi/EFI/elilo

# Install the bootloader binary
sudo cp elilo.efi /boot/efi/EFI/elilo/elilo.efi

# Copy the kernel and initrd to the ESP, keeping the versioned filename
# Replace the version string with the output of: uname -r
sudo cp /boot/vmlinuz-6.12.90+deb13-amd64    /boot/efi/EFI/elilo/vmlinuz-6.12.90+deb13-amd64
sudo cp /boot/initrd.img-6.12.90+deb13-amd64 /boot/efi/EFI/elilo/initrd.img-6.12.90+deb13-amd64
```

> **Note:** elilo reads the kernel and initrd from the ESP (FAT32). The files
> must be copied there — symlinks are not supported on FAT32. Use the versioned
> filename (e.g. `vmlinuz-6.12.90+deb13-amd64`) rather than a generic name so
> it is always clear which kernel version is on the ESP. When the kernel is
> upgraded, you must copy the new files and update `elilo.conf` manually (see
> [Keeping elilo Up to Date](#keeping-elilo-up-to-date-after-a-kernel-upgrade)).

Then write the config file (see next section) and copy it:

```bash
sudo cp elilo.conf /boot/efi/EFI/elilo/elilo.conf
```

elilo looks for `elilo.conf` in the same directory as `elilo.efi` by default.

---

### Writing elilo.conf

The `image=` and `initrd=` paths are relative to the root of the ESP. The
`root=` value is the Linux device name of your root filesystem partition — this
is the partition elilo tells the kernel to mount as `/`, not the ESP itself.

**Identify your root partition:**

```bash
df -h /
# or
lsblk
```

Below are complete example configs for different hardware. Copy the one that
matches your setup, adjust the `root=` device and `append=` line as needed,
then save as `/boot/efi/EFI/elilo/elilo.conf`.

---

#### SATA / SCSI drive (sda, sdb, ...)

```
# elilo.conf — SATA/SCSI example
# ESP:  /dev/sda1
# Root: /dev/sda2

prompt
timeout=50
default=linux

image=/EFI/elilo/vmlinuz-6.12.90+deb13-amd64
  label=linux
  initrd=/EFI/elilo/initrd.img-6.12.90+deb13-amd64
  root=/dev/sda2
  append="ro quiet"
```

Replace `6.12.90+deb13-amd64` with your actual kernel version (`uname -r`).
If your root partition is on a second drive or a different partition number,
change `root=` accordingly — for example `root=/dev/sdb3`.

---

#### NVMe SSD (nvme0n1, nvme1n1, ...)

NVMe devices use a different naming scheme: the drive is `nvme0n1` and
partitions are `nvme0n1p1`, `nvme0n1p2`, etc.

```
# elilo.conf — NVMe example
# ESP:  /dev/nvme0n1p1
# Root: /dev/nvme0n1p2

prompt
timeout=50
default=linux

image=/EFI/elilo/vmlinuz-6.12.90+deb13-amd64
  label=linux
  initrd=/EFI/elilo/initrd.img-6.12.90+deb13-amd64
  root=/dev/nvme0n1p2
  append="ro quiet"
```

Replace `6.12.90+deb13-amd64` with your actual kernel version (`uname -r`).
For a second NVMe drive use `nvme1n1p2`, and so on. If your root partition is
on a different partition number, change `root=` accordingly — for example
`root=/dev/nvme0n1p3`.

---

#### eMMC storage (mmcblk0, mmcblk1, ...)

eMMC devices follow the same `pN` suffix pattern as NVMe.

```
# elilo.conf — eMMC example
# ESP:  /dev/mmcblk0p1
# Root: /dev/mmcblk0p2

prompt
timeout=50
default=linux

image=/EFI/elilo/vmlinuz-6.12.90+deb13-amd64
  label=linux
  initrd=/EFI/elilo/initrd.img-6.12.90+deb13-amd64
  root=/dev/mmcblk0p2
  append="ro quiet"
```

Replace `6.12.90+deb13-amd64` with your actual kernel version (`uname -r`).
For a second eMMC device use `mmcblk1p2`. If your root partition is on a
different partition number, change `root=` accordingly — for example
`root=/dev/mmcblk0p3`.

---

#### Multiple boot entries (e.g. fallback kernel)

```
# elilo.conf — multiple kernels
prompt
timeout=50
default=linux

image=/EFI/elilo/vmlinuz-6.13.5+deb13-amd64
  label=linux
  description="Devuan Linux 6.13 (current)"
  initrd=/EFI/elilo/initrd.img-6.13.5+deb13-amd64
  root=/dev/sda2
  append="ro quiet"

image=/EFI/elilo/vmlinuz-6.12.90+deb13-amd64
  label=linux.old
  description="Devuan Linux 6.12 (previous)"
  initrd=/EFI/elilo/initrd.img-6.12.90+deb13-amd64
  root=/dev/sda2
  append="ro quiet"
```

Replace the version strings with your current and previous kernel versions
(`uname -r` gives the running version). Change `root=` to match your actual
root partition — for example `root=/dev/nvme0n1p2` or `root=/dev/mmcblk0p2`
for NVMe or eMMC systems.

---

#### Common append options

| Option | Effect |
|---|---|
| `ro` | Mount root read-only at boot (standard) |
| `quiet` | Suppress most kernel messages |
| `nomodeset` | Disable kernel modesetting (safe fallback if display is blank) |
| `rootfstype=ext4` | Explicitly set root filesystem type |
| `init=/sbin/init` | Use sysvinit explicitly (Devuan/Artix) |
| `single` | Boot to single-user mode |

---

### Registering with the UEFI Boot Manager

After copying the files, register elilo as a UEFI boot entry. Replace
`/dev/sdX` and the partition number with your actual ESP device.

**SATA example (ESP on /dev/sda1):**

```bash
sudo efibootmgr --create \
  --disk /dev/sda \
  --part 1 \
  --label "elilo" \
  --loader "\\EFI\\elilo\\elilo.efi"
```

**NVMe example (ESP on /dev/nvme0n1p1):**

```bash
sudo efibootmgr --create \
  --disk /dev/nvme0n1 \
  --part 1 \
  --label "elilo" \
  --loader "\\EFI\\elilo\\elilo.efi"
```

**eMMC example (ESP on /dev/mmcblk0p1):**

```bash
sudo efibootmgr --create \
  --disk /dev/mmcblk0 \
  --part 1 \
  --label "elilo" \
  --loader "\\EFI\\elilo\\elilo.efi"
```

Verify the entry was added:

```bash
efibootmgr -v
```

The new entry will appear in the boot order list. On the next reboot your
firmware will offer both elilo and any existing entries (e.g. GRUB).

---

## Keeping elilo Up to Date After a Kernel Upgrade

> **Warning:** elilo reads the kernel and initrd by filename from the ESP.
> Unlike GRUB, it does not use symlinks or automatically find new kernels.
> After every kernel upgrade you must manually copy the new files to the ESP
> and update `elilo.conf` if the filename changes. Failure to do this will
> cause elilo to boot the old kernel or fail to find the kernel entirely.

After a kernel upgrade (e.g. via `apt upgrade`):

**Step 1 — Identify the new kernel:**

```bash
ls /boot/vmlinuz-* /boot/initrd.img-*
```

You will see both the old and new versions, for example:

```
/boot/vmlinuz-6.12.90+deb13-amd64
/boot/vmlinuz-6.13.5+deb13-amd64   ← new
/boot/initrd.img-6.12.90+deb13-amd64
/boot/initrd.img-6.13.5+deb13-amd64 ← new
```

**Step 2 — Copy the new kernel to the ESP:**

```bash
# Copy the new kernel using the versioned filename (replace version string with your actual new version)
sudo cp /boot/vmlinuz-6.13.5+deb13-amd64    /boot/efi/EFI/elilo/vmlinuz-6.13.5+deb13-amd64
sudo cp /boot/initrd.img-6.13.5+deb13-amd64 /boot/efi/EFI/elilo/initrd.img-6.13.5+deb13-amd64
```

**Step 3 — Verify the copy succeeded:**

```bash
ls -lh /boot/efi/EFI/elilo/
```

Confirm the file sizes match:

```bash
ls -lh /boot/vmlinuz-6.13.5+deb13-amd64 /boot/efi/EFI/elilo/vmlinuz-6.13.5+deb13-amd64
```

**Step 4 — Update elilo.conf:**

Update the `image=` and `initrd=` lines in `/boot/efi/EFI/elilo/elilo.conf` to
point to the new versioned filenames:

```
image=/EFI/elilo/vmlinuz-6.13.5+deb13-amd64
  label=linux
  initrd=/EFI/elilo/initrd.img-6.13.5+deb13-amd64
  root=/dev/sda2
  append="ro quiet"
```

You can keep the old kernel as a second entry (change `label=` to something like
`linux.old`) until you are confident the new kernel boots correctly, then remove
it on the next upgrade.

> **If elilo fails to boot after a kernel upgrade:** select GRUB (or your
> previous boot entry) from the UEFI firmware menu to boot the old kernel while
> you diagnose the problem.

---

## Partition Naming Reference

| Hardware | Drive | ESP (partition 1) | Root (partition 2) |
|---|---|---|---|
| SATA SSD / HDD, first drive | `/dev/sda` | `/dev/sda1` | `/dev/sda2` |
| SATA SSD / HDD, second drive | `/dev/sdb` | `/dev/sdb1` | `/dev/sdb2` |
| NVMe SSD, first drive | `/dev/nvme0n1` | `/dev/nvme0n1p1` | `/dev/nvme0n1p2` |
| NVMe SSD, second drive | `/dev/nvme1n1` | `/dev/nvme1n1p1` | `/dev/nvme1n1p2` |
| eMMC (built-in), first device | `/dev/mmcblk0` | `/dev/mmcblk0p1` | `/dev/mmcblk0p2` |
| SD card | `/dev/mmcblk1` | `/dev/mmcblk1p1` | `/dev/mmcblk1p2` |

The partition numbers above assume a standard layout (ESP first, root second).
Your layout may differ — always verify with `lsblk` or `fdisk -l`.

---

## Changes from 3.14

elilo 3.14 was last updated in January 2011. It was written against gnu-efi 3.0
and Linux boot protocol 2.09. The fixes below make it build and boot correctly
on modern UEFI firmware with Linux kernels in the 6.x series (tested with
Debian/Devuan 6.12).

---

### Fix 1 — Build: Add `.rodata` to objcopy sections

**File:** `Make.rules`

Modern GCC places string literals in `.rodata`, a section separate from `.text`.
The original objcopy invocation did not include `-j .rodata`, so all `Print()`
strings were silently dropped from the EFI binary. The resulting elilo.efi had
no visible output at all.

```makefile
# Before:
$(OBJCOPY) -j .text -j .sdata -j .data -j .dynamic ...

# After:
$(OBJCOPY) -j .text -j .sdata -j .data -j .rodata -j .dynamic ...
```

---

### Fix 2 — Compile: Remove conflicting `StrnCpy` declaration

**Files:** `strops.h`, `strops.c`

gnu-efi 3.0.18 declares `StrnCpy` as returning `VOID`. elilo 3.14 declares it
as returning `CHAR16 *`. GCC 12+ treats this as a hard type-conflict error.

Since no call site in elilo uses the return value, elilo's shadow declaration
and implementation were removed. gnu-efi's version is used instead.

---

### Fix 3 — Compile: `HandleProtocol` void-pointer cast

**File:** `x86_64/system.c`

`HandleProtocol` expects a `VOID **` but elilo passed a typed pointer directly.
Added the required `(VOID **)` cast.

---

### Fix 4 — ABI bug: `SetMem` zeroed 0 bytes (config parse failure)

**File:** `x86_64/sysdeps.h`

This was the root cause of the `(null) already defined` error during config
parsing.

elilo is compiled with SysV ABI (`-DEFI_FUNCTION_WRAPPER`). `SetMem` in
`libefi.a` is declared `EFIAPI` (Microsoft x64 ABI), meaning its `Size`
argument is passed in `RCX`. When called from SysV code, the compiler puts
`Size` in `RDX` (the second SysV register), not `RCX`. `SetMem` reads zero
from `RCX` and zeroes nothing. The config parser then found every label
"already defined" because its lookup table was never cleared.

Fix: replace `Memset(a,v,n)` with `ZeroMem((a),(n))`. `ZeroMem` in the
installed gnu-efi does not carry `EFIAPI`, so it uses SysV ABI and the call is
correct without any wrapper.

---

### Fix 5 — ABI bug: `CopyMem` corrupted boot_params copy

**File:** `x86_64/sysdeps.h`

The same MS-ABI problem affects `CopyMem`. It is declared `EFIAPI` in
`libefi.a`. A direct call from SysV code passes arguments in the wrong
registers, silently corrupting the copy of the kernel setup header into
boot_params.

Fix: route all `CopyMem` calls through `uefi_call_wrapper(CopyMem, 3, ...)`,
which is the SysV→MS ABI trampoline already provided by gnu-efi for exactly
this purpose.

---

### Fix 6 — Bug: `config_error()` printed `(null)` for all messages

**File:** `config.c`

`config_error()` was calling `IPrint` without passing its `va_list`, so the
format string was evaluated against garbage stack data. Changed to use `VPrint`
with a proper `va_list`.

---

### Fix 7 — Bug: File-read retry triggered on every successful read

**File:** (file operations layer)

The retry condition was `ret != EFI_SUCCESS`, which fired on every successful
read that returned fewer bytes than requested (a normal short-read condition).
The file was re-read from the beginning repeatedly. Changed to retry only on
`EFI_NOT_FOUND` or `EFI_TFTP_ERROR`.

---

### Fix 8 — Bug: `cmdline_addr` always zero

**File:** `x86_64/system.c`

Boot protocol 2.06+ locates the kernel command line via the absolute address in
`cmdline_addr`. elilo was setting it to 0. The kernel therefore booted without
any command-line arguments.

```c
/* Before */
bp->s.cmdline_addr = 0x0;

/* After */
bp->s.cmdline_addr = (UINT32)(UINT64)cmdline;
```

Also added `bp->s.loader_flags |= LDRFLAG_CAN_USE_HEAP` so the kernel knows
it may use the heap area.

---

### Fix 9 — Bug: Kernel size ceiling too small for 6.x kernels

**File:** `x86_64/bzimage.c`

The original ceiling was `kernel_size = 0x800000` (8 MB). The Debian 6.12
bzImage body is approximately 11.5 MB. The kernel body was truncated at 8 MB,
meaning the EFI stub — which is appended at body offset ~11.4 MB — was never
loaded into memory. Jumping to the handover entry address therefore landed in
uninitialised memory.

Rather than guessing a new fixed limit, we read `init_size` from the kernel
setup header and use it when it exceeds the default:

```c
UINT32 init_sz = ps->s.pad_9[10];
if (init_sz > (UINT32)kernel_size)
    kernel_size = (UINTN)init_sz;
```

For the Debian 6.12 kernel `init_size` is 56 MB, which covers the full
11.5 MB compressed image with room to spare.

Slackware's patch instead increases the fixed limit to 16 MB. That is not
enough for a 6.12 bzImage and would still truncate the EFI stub.

---

### Fix 10 — Core boot fix: EFI Handover Protocol

**Files:** `x86_64/sysdeps.h`, `elilo.c`

elilo 3.14 boots by calling `ExitBootServices()` itself and then jumping
directly to the kernel's protected-mode entry point. On modern UEFI firmware
this fails: the kernel expects to manage EFI shutdown through its own stub,
which sets up memory descriptors, tears down Boot Services, and transitions
cleanly.

The EFI Handover Protocol (Linux boot protocol 2.12+, kernels >= 3.3) solves
this. The bootloader keeps Boot Services active and calls the kernel's EFI stub
entry point directly, passing `(image_handle, efi_system_table, boot_params)`.
The stub takes over from there.

Entry-point location:

- `handover_offset` (boot params field at offset `0x264`) is the offset from
  the start of the compressed kernel body to the 32-bit EFI entry point.
- The 64-bit entry is always `handover_offset + 512`.
- `kernel_load_address` is where elilo loaded the body, so the entry address is:

```c
(UINT8 *)kernel_load_address + BP_HANDOVER_OFFSET(bp) + 512
```

The handover is attempted before the legacy `ExitBootServices` + `start_kernel`
fallback, which is kept for kernels older than 3.3.

---

### Fix 11 — Critical ABI fix: handover entry uses SysV, not MS ABI

**File:** `x86_64/sysdeps.h`

This was the fix that made the kernel actually boot. In older kernels (up to
approximately 5.x), `efi64_stub_entry` began with an explicit MS→SysV argument
translation:

```asm
mov %rcx, %rdi   ; handle:     MS arg1 → SysV arg1
mov %rdx, %rsi   ; sys_table:  MS arg2 → SysV arg2
mov %r8,  %rdx   ; boot_params: MS arg3 → SysV arg3
```

Linux 6.x removed this shim. `efi64_stub_entry` is now a one-instruction JMP
trampoline landing directly in SysV code that reads `rdi`, `rsi`, and `rdx`.

The handover function pointer was originally declared with
`__attribute__((ms_abi))`. That caused GCC to place arguments in `rcx`/`rdx`/
`r8`, which the kernel never reads. The kernel received garbage for `handle` and
`sys_table`, crashed immediately, and the result looked like a freeze.

Verified by disassembling the JMP target in the Debian 6.12 bzImage:

```
41 54        push r12
49 89 d4     mov  r12, rdx    ← saves rdx = 3rd SysV arg (boot_params)
55           push rbp
48 89 f5     mov  rbp, rsi    ← saves rsi = 2nd SysV arg (sys_table)
53           push rbx
48 89 fb     mov  rbx, rdi    ← saves rdi = 1st SysV arg (handle)
```

Fix: remove `__attribute__((ms_abi))` from the handover function pointer
typedef. Since elilo is compiled with SysV ABI throughout (via
`-DEFI_FUNCTION_WRAPPER`), a plain call already places arguments in the correct
registers.

---

### Fix 12 — Portability: arch guard for handover call in elilo.c

**File:** `elilo.c`

The `efi_handover_64()` function and its supporting macros are defined only in
`x86_64/sysdeps.h`. The call site in `elilo.c` is now wrapped in
`#ifdef CONFIG_x86_64` so that ia32 and ia64 builds compile cleanly without the
handover code, falling through to the legacy boot path.

---

## Comparison with Slackware 15.0

Slackware 15.0 ships elilo 3.16 but does **not rebuild it from source** with a
modern compiler. Their SlackBuild uses pre-compiled EFI binaries from a 2022
Slackware 14.2 build. They apply two patches to the source tree (which only
affects the tools/ component they do compile):

- `elilo.double.kernel.size.limit.diff.gz` — bumps the 8 MB kernel size ceiling
  to 16 MB.
- `elilo.zeroes.cc_blob_address.diff.gz` — adds the `cc_blob_address` field to
  the boot_params struct and zeroes it before boot, preventing a crash on
  kernels that check for an AMD SEV/TDX confidential-computing blob.

Everything above goes beyond what Slackware does. The pre-built binary approach
sidesteps the compiler and ABI issues entirely; rebuilding from source with
GCC 12+ exposes all of them.

| Area | Slackware 15.0 | This patch set |
|---|---|---|
| Build from source | No — ships 2022 prebuilt binary | Yes |
| `.rodata` in objcopy | N/A (prebuilt) | Fixed |
| StrnCpy conflict | Renamed to `elilo_StrnCpy` | Removed |
| SetMem ABI (config parse) | N/A (prebuilt) | Fixed |
| CopyMem ABI (boot_params) | N/A (prebuilt) | Fixed |
| config_error null output | N/A (prebuilt) | Fixed |
| File-read retry loop | N/A (prebuilt) | Fixed |
| cmdline_addr zero | N/A (prebuilt) | Fixed |
| Kernel size ceiling | 16 MB fixed limit | `init_size` from header |
| cc_blob_address | Explicitly zeroed | Template zeroed by ZeroMem |
| EFI Handover Protocol | Not implemented | Implemented |
| Handover ABI (SysV vs MS) | N/A | Fixed for Linux 6.x |
| ia32/ia64 build guard | N/A | Fixed |

---

## License & Credits

elilo is free software distributed under the **GNU General Public License
version 2**, or (at your option) any later version. The full license text
should accompany this source as the file `COPYING`. If it is absent, the
canonical text is available at https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

### Copyright holders

The following copyright notices appear in the source tree and must be
preserved in any redistribution:

| Years | Holder | Files / Notes |
|---|---|---|
| 1992–1997 | Werner Almesberger | `elf.h`, `config.c` (config parser originally from lilo) |
| 1999–2000 | VA Linux Systems | `elilo.c` — contributed by Johannes Erdfelt |
| 1999–2003 | Hewlett-Packard Co. | `elilo.c` — contributed by David Mosberger, Stephane Eranian |
| 2000 | Stephane Eranian `<eranian@hpl.hp.com>` | (individual contribution) |
| 2001 | Silicon Graphics, Inc. | `elilo.h` — contributed by Brent Casavant |
| 2001–2003 | Hewlett-Packard Co. | `elilo.h`, `x86_64/sysdeps.h`, and others |
| 2001–2009 | Hewlett-Packard Co. | Various files |
| 2002–2003 | Hewlett-Packard Co. | `bootparams.c` and related |
| 2005 | Hewlett-Packard Development Company, L.P. | Later HP entity name |
| 2006 | Christoph Pfisterer | `console.c`, `console.h` |
| 2006–2009 | Intel Corporation | `elilo.c`, `x86_64/sysdeps.h`, and others — contributed by Fenghua Yu, Bibo Mao, Chandramouli Narayanan, Mike Johnston, Chris Ahna |
| 2026 | rations `<ehqcar@proton.me>` | Modernisation for Linux 6.x / modern UEFI (fixes 1–12) |

### Individual contributors credited in source headers

- David Mosberger (HP) — original IA-64 work, `elilo.c`
- Stephane Eranian (HP) — original architecture, numerous files
- Brent Casavant (SGI) — `elilo.h`
- Johannes Erdfelt (VA Linux) — `elilo.c`
- Mike Johnston (Intel) — `x86_64/sysdeps.h`
- Chris Ahna (Intel) — `x86_64/sysdeps.h`
- Fenghua Yu (Intel) — `elilo.c`, `x86_64/sysdeps.h`
- Bibo Mao (Intel) — `elilo.c`, `x86_64/sysdeps.h`
- Chandramouli Narayanan (Intel) — `elilo.c`, `x86_64/sysdeps.h`
- Christoph Pfisterer — `console.c`, `console.h`
- Werner Almesberger — config parser (via lilo lineage)

### Development tools

Version 3.17 modernisation developed with
[Claude Sonnet 4.6](https://www.anthropic.com) (Anthropic) as AI development
assistant.
