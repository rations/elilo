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
 * Arrow-key boot menu (chooser=menu).
 *
 * Every image in elilo.conf is listed while the timeout counts down.
 * Any key stops the countdown. Up/Down/Home/End/PgUp/PgDn and 1-9 move
 * the selection, Enter boots it, 'e' edits its options before booting
 * and 'c' (or Tab) switches to the classic "ELILO boot:" prompt.
 * No message files are needed; the layout follows the console size.
 */

#include <efi.h>
#include <efilib.h>

#include "elilo.h"
#include "console.h"

#ifdef CONFIG_CHOOSER_SIMPLE
#include "simple.h"
#endif

#define MAX_ENTRIES	64
#define LINE_MAX	256
#define TENTH_SEC	1000000		/* 1/10th second in 100ns unit */

#define LIST_TOP	2		/* first screen row of the entry list */

#define ATTR_NORMAL	EFI_TEXT_ATTR(EFI_LIGHTGRAY, EFI_BLACK)
#define ATTR_TITLE	EFI_TEXT_ATTR(EFI_WHITE, EFI_BLACK)
#define ATTR_SELECT	EFI_TEXT_ATTR(EFI_BLACK, EFI_LIGHTGRAY)

#define CHAR_CTRL_U	L'\025'
#define CHAR_DEL	L'\177'

#define ClearScreen()	uefi_call_wrapper(systab->ConOut->ClearScreen, 1, systab->ConOut)
#define SetTextAttr(a)	uefi_call_wrapper(systab->ConOut->SetAttribute, 2, systab->ConOut, (a))
#define GotoXY(c, r)	uefi_call_wrapper(systab->ConOut->SetCursorPosition, 3, systab->ConOut, (c), (r))
#define ShowCursor(b)	uefi_call_wrapper(systab->ConOut->EnableCursor, 2, systab->ConOut, (b))

typedef enum {
	MENU_BOOT,		/* boot the selected entry */
	MENU_PROMPT,		/* switch to the classic prompt */
} menu_result_t;

static CHAR16 *labels[MAX_ENTRIES];
static CHAR16 *descriptions[MAX_ENTRIES];
static INTN nentries;

static UINTN cols, rows;
static UINTN help_row, status_row;
static INTN list_height, first;

static VOID
query_screen(VOID)
{
	SIMPLE_TEXT_OUTPUT_INTERFACE *out = systab->ConOut;

	if (EFI_ERROR(uefi_call_wrapper(out->QueryMode, 4, out, out->Mode->Mode, &cols, &rows))) {
		cols = 80;
		rows = 25;
	}
	if (cols > LINE_MAX) cols = LINE_MAX;

	/* title, blank, list, blank, help, status, and the last row unused */
	list_height = (INTN)rows - 6;
	if (list_height < 1) list_height = 1;
	if (list_height > nentries) list_height = nentries;

	/* help and countdown just below the list */
	help_row   = LIST_TOP + list_height + 1;
	status_row = help_row + 2;
	if (status_row > rows - 2) status_row = rows - 2;
	if (help_row >= status_row) help_row = status_row - 1;
}

/*
 * print s at (col,row), truncated or space padded to width.
 * Never writes the last column so the console does not scroll.
 */
static VOID
put_line(UINTN col, UINTN row, UINTN attr, CHAR16 *s, UINTN width)
{
	CHAR16 buf[LINE_MAX + 1];
	UINTN i;

	if (col + width >= cols) width = cols - col - 1;
	if (width > LINE_MAX) width = LINE_MAX;

	for (i = 0; i < width && s[i]; i++) buf[i] = s[i];
	for (; i < width; i++) buf[i] = L' ';
	buf[i] = CHAR_NULL;

	GotoXY(col, row);
	SetTextAttr(attr);
	Print(L"%s", buf);
}

static VOID
draw_entry(INTN i, INTN selected)
{
	CHAR16 line[LINE_MAX];

	if (i < first || i >= first + list_height) return;

	if (i < 9)
		UnicodeSPrint(line, sizeof(line), L" %d. %s", i + 1, descriptions[i]);
	else
		UnicodeSPrint(line, sizeof(line), L"    %s", descriptions[i]);

	put_line(2, LIST_TOP + (i - first), i == selected ? ATTR_SELECT : ATTR_NORMAL, line, cols - 6);
}

static VOID
draw_list(INTN selected)
{
	CHAR16 mark[2] = { CHAR_NULL, CHAR_NULL };
	INTN i;

	for (i = first; i < first + list_height; i++) draw_entry(i, selected);

	/* scroll indicators in the right margin */
	mark[0] = first > 0 ? ARROW_UP : L' ';
	put_line(cols - 3, LIST_TOP, ATTR_NORMAL, mark, 1);
	mark[0] = first + list_height < nentries ? ARROW_DOWN : L' ';
	put_line(cols - 3, LIST_TOP + list_height - 1, ATTR_NORMAL, mark, 1);
}

static VOID
draw_status(INTN selected, INTN countdown)
{
	CHAR16 line[LINE_MAX];

	if (countdown >= 0)
		UnicodeSPrint(line, sizeof(line), L"Booting \"%s\" in %d s. Press any key to stop.",
			      descriptions[selected], (countdown + 9) / 10);
	else
		line[0] = CHAR_NULL;

	put_line(0, status_row, ATTR_NORMAL, line, cols);
}

static VOID
draw_screen(INTN selected, INTN countdown)
{
	CHAR16 line[LINE_MAX];

	SetTextAttr(ATTR_NORMAL);
	ClearScreen();
	ShowCursor(FALSE);

	UnicodeSPrint(line, sizeof(line), L"ELILO %s boot menu", ELILO_VERSION);
	put_line(0, 0, ATTR_TITLE, line, cols);

	draw_list(selected);

#ifdef CONFIG_CHOOSER_SIMPLE
	UnicodeSPrint(line, sizeof(line), L"%c/%c select   Enter boot   e edit options   c command line",
		      ARROW_UP, ARROW_DOWN);
#else
	UnicodeSPrint(line, sizeof(line), L"%c/%c select   Enter boot   e edit options",
		      ARROW_UP, ARROW_DOWN);
#endif
	put_line(0, help_row, ATTR_NORMAL, line, cols);

	draw_status(selected, countdown);
}

/*
 * move the selection, scrolling the list when needed
 */
static VOID
select_entry(INTN *selected, INTN to)
{
	INTN old = *selected, old_first = first;

	if (to < 0) to = 0;
	if (to >= nentries) to = nentries - 1;
	if (to == old) return;

	if (to < first) first = to;
	if (to >= first + list_height) first = to - list_height + 1;

	*selected = to;
	if (first != old_first) {
		draw_list(to);
	} else {
		draw_entry(old, to);
		draw_entry(to, to);
	}
}

/*
 * single-line editor for the options of the selected entry.
 * Return 1 to boot with buf, 0 if cancelled with Esc.
 */
static INTN
edit_options(CHAR16 *buf, UINTN max, CHAR16 *what)
{
	SIMPLE_INPUT_INTERFACE *ip = systab->ConIn;
	CHAR16 line[LINE_MAX];
	EFI_INPUT_KEY key;
	UINTN len = StrLen(buf), width, row, i, idx, shown = 0;

	SetTextAttr(ATTR_NORMAL);
	ClearScreen();
	ShowCursor(TRUE);

	UnicodeSPrint(line, sizeof(line), L"Options for \"%s\"", what);
	put_line(0, 0, ATTR_TITLE, line, cols);
	put_line(0, 1, ATTR_NORMAL, L"Enter boots with these options, Esc cancels, Ctrl-U clears the line.", cols);

	width = cols - 1;

	for (;;) {
		/* redraw the buffer wrapped by hand, clearing what was shown before */
		for (i = 0, row = 3; i < len || i < shown || i == 0; i += width, row++) {
			UINTN n;

			if (row >= rows - 1) break;
			for (n = 0; n < width; n++)
				line[n] = (i + n < len) ? buf[i + n] : L' ';
			line[n] = CHAR_NULL;
			put_line(0, row, ATTR_NORMAL, line, width);
		}
		shown = len;
		if (3 + len / width < rows - 1) GotoXY(len % width, 3 + len / width);

		uefi_call_wrapper(BS->WaitForEvent, 3, 1, &ip->WaitForKey, &idx);
		if (EFI_ERROR(uefi_call_wrapper(ip->ReadKeyStroke, 2, ip, &key))) continue;

		if (key.ScanCode == SCAN_ESC) {
			ShowCursor(FALSE);
			return 0;
		}
		switch (key.UnicodeChar) {
			case CHAR_CARRIAGE_RETURN:
			case CHAR_LINEFEED:
				ShowCursor(FALSE);
				return 1;
			case CHAR_BACKSPACE:
			case CHAR_DEL:
				if (len) buf[--len] = CHAR_NULL;
				break;
			case CHAR_CTRL_U:
				len = 0;
				buf[0] = CHAR_NULL;
				break;
			default:
				if (key.UnicodeChar < L' ' || key.UnicodeChar > 0x7e) break;
				if (len >= max - 1) break;
				/* keep within the visible area */
				if (3 + (len + 1) / width >= rows - 1) break;
				buf[len++] = key.UnicodeChar;
				buf[len]   = CHAR_NULL;
		}
	}
}

/*
 * show the menu and wait for a choice.
 * *interacted is set once the user pressed any key.
 */
static menu_result_t
run_menu(INTN *selected, CHAR16 *edit_buf, INTN *edited, INTN *interacted)
{
	SIMPLE_INPUT_INTERFACE *ip = systab->ConIn;
	CHAR16 initrd_name[PATHNAME_MAXLEN], vmcode_name[PATHNAME_MAXLEN], kname[FILENAME_MAXLEN];
	EFI_EVENT timer = NULL, list[2];
	EFI_INPUT_KEY key;
	EFI_STATUS status;
	INTN countdown = -1;
	UINTN idx;
	menu_result_t result = MENU_BOOT;

	*edited = *interacted = 0;

	query_screen();

	first = 0;
	if (*selected >= list_height) first = *selected - list_height + 1;

	if (elilo_opt.timeout != ELILO_TIMEOUT_INFINITY) {
		countdown = (INTN)elilo_opt.timeout;
		status = uefi_call_wrapper(BS->CreateEvent, 5, EVT_TIMER, 0, NULL, NULL, &timer);
		if (EFI_ERROR(status) ||
		    EFI_ERROR(uefi_call_wrapper(BS->SetTimer, 3, timer, TimerPeriodic, TENTH_SEC))) {
			/* no timer: wait for the user rather than boot blindly */
			if (timer) uefi_call_wrapper(BS->CloseEvent, 1, timer);
			timer = NULL;
			countdown = -1;
		}
	}

	draw_screen(*selected, countdown);

	for (;;) {
		if (countdown == 0) break;

		list[0] = ip->WaitForKey;
		list[1] = timer;
		status = uefi_call_wrapper(BS->WaitForEvent, 3, timer ? 2 : 1, list, &idx);
		if (EFI_ERROR(status)) break;

		if (idx == 1) {
			if (countdown > 0) {
				countdown--;
				if (countdown % 10 == 0) draw_status(*selected, countdown);
			}
			continue;
		}

		if (EFI_ERROR(uefi_call_wrapper(ip->ReadKeyStroke, 2, ip, &key))) continue;

		*interacted = 1;
		if (countdown >= 0) {
			countdown = -1;
			draw_status(*selected, countdown);
		}

		switch (key.ScanCode) {
			case SCAN_UP:		select_entry(selected, *selected - 1); continue;
			case SCAN_DOWN:		select_entry(selected, *selected + 1); continue;
			case SCAN_HOME:		select_entry(selected, 0); continue;
			case SCAN_END:		select_entry(selected, nentries - 1); continue;
			case SCAN_PAGE_UP:	select_entry(selected, *selected - list_height); continue;
			case SCAN_PAGE_DOWN:	select_entry(selected, *selected + list_height); continue;
		}

		if (key.UnicodeChar >= L'1' && key.UnicodeChar <= L'9') {
			select_entry(selected, key.UnicodeChar - L'1');
			continue;
		}

		switch (key.UnicodeChar) {
			case CHAR_CARRIAGE_RETURN:
			case CHAR_LINEFEED:
				goto done;
			case L'e':
			case L'E': {
				CHAR16 *p;

				initrd_name[0] = vmcode_name[0] = kname[0] = CHAR_NULL;
				find_label(labels[*selected], kname, edit_buf, initrd_name, vmcode_name);
				for (p = edit_buf; *p == L' '; p++);
				if (p != edit_buf) StrCpy(edit_buf, p);

				if (edit_options(edit_buf, CMDLINE_MAXLEN, descriptions[*selected])) {
					*edited = 1;
					goto done;
				}
				draw_screen(*selected, countdown);
				continue;
			}
#ifdef CONFIG_CHOOSER_SIMPLE
			case L'c':
			case L'C':
			case CHAR_TAB:
				result = MENU_PROMPT;
				goto done;
#endif
		}
	}
done:
	if (timer) {
		uefi_call_wrapper(BS->SetTimer, 3, timer, TimerCancel, 0);
		uefi_call_wrapper(BS->CloseEvent, 1, timer);
	}
	SetTextAttr(ATTR_NORMAL);
	ClearScreen();
	ShowCursor(TRUE);

	return result;
}

static INTN
menu_choose(CHAR16 **argv, INTN argc, INTN index, CHAR16 *kname, CHAR16 *cmdline)
{
	CHAR16 args[CMDLINE_MAXLEN];
	CHAR16 edit_buf[CMDLINE_MAXLEN];
	CHAR16 alt_buffer[CMDLINE_MAXLEN];
	CHAR16 initrd_name[PATHNAME_MAXLEN];
	CHAR16 vmcode_name[PATHNAME_MAXLEN];
	CHAR16 *dfl;
	INTN selected = 0, edited = 0, interacted = 0, use_alt = 0, i;
	VOID *handle = NULL;

	nentries = 0;
	while (nentries < MAX_ENTRIES &&
	       (handle = get_next_description(handle, labels + nentries, descriptions + nentries))) {
		if (descriptions[nentries][0] == CHAR_NULL)
			descriptions[nentries] = labels[nentries];
		nentries++;
	}

	if (nentries == 0) {
#ifdef CONFIG_CHOOSER_SIMPLE
		/* nothing to list: the prompt still accepts a kernel path */
		return simple_chooser.chooser_func(argv, argc, index, kname, cmdline);
#else
		ERR_PRT((L"menu: no image defined in the config file"));
		return -1;
#endif
	}

	dfl = get_default_label();
	for (i = 0; dfl && i < nentries; i++) {
		if (StriCmp(labels[i], dfl) == 0) {
			selected = i;
			break;
		}
	}

	/*
	 * alternate kernel (eliloalt) boots instead of the default unless
	 * the user picks something; preselect it when it names a label
	 */
	alt_buffer[0] = CHAR_NULL;
	if (elilo_opt.alt_check && alternate_kernel(alt_buffer, sizeof(alt_buffer)) == 0) {
		CHAR16 *alt_argv[MAX_ARGS];

		use_alt = 1;
		/* the variable is deleted after the first access */
		elilo_opt.alt_check = 0;

		StrCpy(edit_buf, alt_buffer);
		if (argify(edit_buf, sizeof(edit_buf), alt_argv) > 0) {
			for (i = 0; i < nentries; i++) {
				if (StriCmp(labels[i], alt_argv[0]) == 0) {
					selected = i;
					break;
				}
			}
		}
	}

	/* reset per image loader options */
	Memset(&elilo_opt.img_opt, 0, sizeof(elilo_opt.img_opt));

	if (elilo_opt.prompt == 0) {
		/* minimal printing */
		Print(L"ELILO v%s for EFI/%a\n", ELILO_VERSION, ELILO_ARCH);
		if (wait_timeout(elilo_opt.delay) != 0) {
			elilo_opt.prompt  = 1;
			elilo_opt.timeout = ELILO_TIMEOUT_INFINITY;
		}
	}

	if (elilo_opt.prompt) {
		console_textmode();
		if (run_menu(&selected, edit_buf, &edited, &interacted) == MENU_PROMPT) {
#ifdef CONFIG_CHOOSER_SIMPLE
			elilo_opt.timeout = ELILO_TIMEOUT_INFINITY;
			return simple_chooser.chooser_func(argv, argc, index, kname, cmdline);
#endif
		}
		if (interacted) use_alt = 0;
	}

	kname[0] = args[0] = initrd_name[0] = vmcode_name[0] = CHAR_NULL;

	if (use_alt) {
		INTN alt_argc;

		alt_argc = argify(alt_buffer, sizeof(alt_buffer), argv);
		if (alt_argc == 0 || find_label(argv[0], kname, args, initrd_name, vmcode_name) == -1) {
			/* not a label: a kernel file name */
			StrCpy(kname, alt_argc ? argv[0] : elilo_opt.default_kernel);
		}
		for (i = 1; i < alt_argc; i++) {
			StrCat(args, L" ");
			StrCat(args, argv[i]);
		}
	} else {
		find_label(labels[selected], kname, args, initrd_name, vmcode_name);
		if (edited) StrCpy(args, edit_buf);
	}

	/*
	 * if initrd specified on command line, it overrides
	 * the one defined in config file, if any
	 */
	if (elilo_opt.initrd[0] == CHAR_NULL && initrd_name[0] != CHAR_NULL)
		StrCpy(elilo_opt.initrd, initrd_name);

	if (elilo_opt.vmcode[0] == CHAR_NULL && vmcode_name[0] != CHAR_NULL)
		StrCpy(elilo_opt.vmcode, vmcode_name);

	VERB_PRT(1,  { Print(L"kernel     is  '%s'\n", kname);
		       Print(L"arguments  are '%s'\n", args);
			if (elilo_opt.initrd[0]) Print(L"initrd      is '%s'\n", elilo_opt.initrd);
			if (elilo_opt.vmcode[0]) Print(L"vmm         is '%s'\n", elilo_opt.vmcode);
		      });

	return chooser_build_cmdline(kname, args, cmdline);
}

static INTN
menu_probe(EFI_HANDLE dev)
{
	/* this chooser always works */
	return 0;
}

chooser_t menu_chooser={
	L"menu",
	menu_probe,
	menu_choose
};
