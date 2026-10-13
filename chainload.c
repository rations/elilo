/*
 *  Copyright (C) 2026 rations <ehqcar@proton.me>
 *
 * This file is part of the ELILO, the EFI Linux boot loader.
 *
 *  ELILO is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2, or (at your option)
 *  any later version.
 *
 *  ELILO is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with ELILO; see the file COPYING.  If not, write to the Free
 *  Software Foundation, 59 Temple Place - Suite 330, Boston, MA
 *  02111-1307, USA.
 *
 * Chainloading of other EFI binaries (Windows Boot Manager, GRUB,
 * systemd-boot, Limine, the Haiku loader, ...).
 *
 * The image is either on the device elilo was loaded from, or on the
 * partition named by device=<PARTUUID> in elilo.conf. Both GPT
 * (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx) and MBR (xxxxxxxx-NN) PARTUUIDs,
 * as printed by blkid/lsblk, are accepted.
 */

#include <efi.h>
#include <efilib.h>

#include "elilo.h"

typedef struct {
	UINT8	sig_type;	/* SIGNATURE_TYPE_GUID or SIGNATURE_TYPE_MBR */
	UINT8	sig[16];	/* as stored in the HARDDRIVE_DEVICE_PATH node */
	UINT32	partno;		/* MBR only */
} partid_t;

/* LoadOptions must stay valid while the child image runs */
static CHAR16 chain_opts[CMDLINE_MAXLEN];

static INTN
hexval(CHAR16 c)
{
	if (c >= L'0' && c <= L'9') return c - L'0';
	if (c >= L'a' && c <= L'f') return c - L'a' + 10;
	if (c >= L'A' && c <= L'F') return c - L'A' + 10;
	return -1;
}

/*
 * parse exactly n hex digits at *s, advance *s
 */
static INTN
parse_hex(CHAR16 **s, UINTN n, UINT64 *val)
{
	UINT64 v = 0;
	INTN d;

	while (n--) {
		if ((d = hexval(**s)) < 0) return -1;
		v = (v << 4) | (UINT64)d;
		(*s)++;
	}
	*val = v;
	return 0;
}

static INTN
expect_dash(CHAR16 **s)
{
	if (**s != L'-') return -1;
	(*s)++;
	return 0;
}

static INTN
parse_partuuid(CHAR16 *str, partid_t *id)
{
	CHAR16 *s = str;
	UINT64 v;
	UINTN i;

	ZeroMem(id, sizeof(*id));

	if (StrLen(str) == 36) {
		EFI_GUID g;
		UINT8 *p = (UINT8 *)&g;

		/* EFI_GUID memory layout: first three fields little-endian */
		if (parse_hex(&s, 8, &v) || expect_dash(&s)) return -1;
		g.Data1 = (UINT32)v;
		if (parse_hex(&s, 4, &v) || expect_dash(&s)) return -1;
		g.Data2 = (UINT16)v;
		if (parse_hex(&s, 4, &v) || expect_dash(&s)) return -1;
		g.Data3 = (UINT16)v;
		for (i = 0; i < 2; i++) {
			if (parse_hex(&s, 2, &v)) return -1;
			g.Data4[i] = (UINT8)v;
		}
		if (expect_dash(&s)) return -1;
		for (i = 2; i < 8; i++) {
			if (parse_hex(&s, 2, &v)) return -1;
			g.Data4[i] = (UINT8)v;
		}
		for (i = 0; i < 16; i++) id->sig[i] = p[i];
		id->sig_type = SIGNATURE_TYPE_GUID;
		return 0;
	}

	/* MBR: <disk signature>-<partition number>, both hex */
	if (parse_hex(&s, 8, &v) || expect_dash(&s)) return -1;
	for (i = 0; i < 4; i++) id->sig[i] = (UINT8)(v >> (8 * i));

	if (*s == CHAR_NULL) return -1;
	id->partno = 0;
	while (*s) {
		INTN d = hexval(*s++);
		if (d < 0) return -1;
		id->partno = (id->partno << 4) | (UINT32)d;
	}
	id->sig_type = SIGNATURE_TYPE_MBR;
	return 0;
}

static BOOLEAN
handle_matches(EFI_HANDLE h, partid_t *id)
{
	EFI_DEVICE_PATH *dp;
	HARDDRIVE_DEVICE_PATH *hd;
	UINTN i, n;

	for (dp = DevicePathFromHandle(h); dp && !IsDevicePathEnd(dp); dp = NextDevicePathNode(dp)) {
		if (DevicePathType(dp) != MEDIA_DEVICE_PATH || DevicePathSubType(dp) != MEDIA_HARDDRIVE_DP)
			continue;

		hd = (HARDDRIVE_DEVICE_PATH *)dp;
		if (hd->SignatureType != id->sig_type) return FALSE;

		n = id->sig_type == SIGNATURE_TYPE_GUID ? 16 : 4;
		for (i = 0; i < n; i++)
			if (hd->Signature[i] != id->sig[i]) return FALSE;

		if (id->sig_type == SIGNATURE_TYPE_MBR && hd->PartitionNumber != id->partno)
			return FALSE;

		return TRUE;
	}
	return FALSE;
}

static EFI_HANDLE
find_fs_handle(partid_t *id)
{
	EFI_HANDLE *buf = NULL, found = NULL;
	UINTN i, n = 0;

	if (EFI_ERROR(LibLocateHandle(ByProtocol, &FileSystemProtocol, NULL, &n, &buf)))
		return NULL;

	for (i = 0; i < n; i++) {
		if (handle_matches(buf[i], id)) {
			found = buf[i];
			break;
		}
	}
	if (buf) FreePool(buf);

	return found;
}

/*
 * Firmware with "fast boot" enabled may only connect the boot disk, so
 * the file system on another disk does not exist yet. Connect everything.
 */
static VOID
connect_all_controllers(VOID)
{
	EFI_HANDLE *buf = NULL;
	UINTN i, n = 0;

	if (EFI_ERROR(LibLocateHandle(AllHandles, NULL, NULL, &n, &buf)))
		return;

	for (i = 0; i < n; i++)
		uefi_call_wrapper(BS->ConnectController, 4, buf[i], NULL, NULL, TRUE);

	if (buf) FreePool(buf);
}

/*
 * Load and start an EFI binary.
 *
 * Return:
 * 	-1: could not be loaded, or it returned an error
 * 	 0: it ran and returned (e.g. the user left its menu)
 * Does not return if the image boots an OS.
 */
INTN
chainload_image(EFI_HANDLE dev, EFI_HANDLE parent, CHAR16 *path, CHAR16 *device, CHAR16 *opts)
{
	CHAR16 fname[FILENAME_MAXLEN];
	EFI_HANDLE fs = dev, child = NULL;
	EFI_DEVICE_PATH *dp;
	EFI_LOADED_IMAGE *li = NULL;
	EFI_STATUS status;
	partid_t id;
	UINTN i, j;

	if (device && device[0]) {
		if (parse_partuuid(device, &id) == -1) {
			ERR_PRT((L"chainload: invalid device=%s (expected a PARTUUID)", device));
			return -1;
		}
		fs = find_fs_handle(&id);
		if (fs == NULL) {
			connect_all_controllers();
			fs = find_fs_handle(&id);
		}
		if (fs == NULL) {
			ERR_PRT((L"chainload: no readable partition with PARTUUID %s", device));
			return -1;
		}
	}

	/* device paths use backslashes and are absolute */
	j = 0;
	if (path[0] != L'/' && path[0] != L'\\') fname[j++] = L'\\';
	for (i = 0; path[i] && j < FILENAME_MAXLEN - 1; i++)
		fname[j++] = path[i] == L'/' ? L'\\' : path[i];
	fname[j] = CHAR_NULL;

	dp = FileDevicePath(fs, fname);
	if (dp == NULL) {
		ERR_PRT((L"chainload: cannot build device path for %s", fname));
		return -1;
	}

	VERB_PRT(1, Print(L"chainloading %s%s%s\n", device && device[0] ? device : L"", device && device[0] ? L":" : L"", fname));

	status = uefi_call_wrapper(BS->LoadImage, 6, FALSE, parent, dp, NULL, 0, &child);
	FreePool(dp);
	if (EFI_ERROR(status)) {
		ERR_PRT((L"chainload: cannot load %s: %r", fname, status));
		return -1;
	}

	if (opts && opts[0]) {
		status = uefi_call_wrapper(BS->HandleProtocol, 3, child, &LoadedImageProtocol, (VOID **)&li);
		if (!EFI_ERROR(status) && li) {
			StrnCpy(chain_opts, opts, CMDLINE_MAXLEN - 1);
			chain_opts[CMDLINE_MAXLEN - 1] = CHAR_NULL;
			li->LoadOptions     = chain_opts;
			li->LoadOptionsSize = (UINT32)((StrLen(chain_opts) + 1) * sizeof(CHAR16));
		}
	}

	status = uefi_call_wrapper(BS->StartImage, 3, child, NULL, NULL);
	if (EFI_ERROR(status)) {
		ERR_PRT((L"chainload: %s returned %r", fname, status));
		return -1;
	}
	return 0;
}
