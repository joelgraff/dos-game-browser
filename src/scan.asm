;==============================================================================
; SCAN.COM — build GAMES.LST on the DOS machine itself
;
; Use case 1: no modern PC involved. Copy the launcher from a floppy, put the
; games somewhere, then run this from the launcher directory:
;
;   C:\DGB> SCAN C:\GAMES
;
; Writes GAMES.LST and DGB.CFG into the current directory.
;
; Mirrors dgb/scan.py for the cases that matter on DOS:
;   - game directories 1 to 3 levels below the root
;   - a directory holding a launchable file IS a game and is not descended into
;   - .BAT beats .EXE beats .COM; alphabetically first within an extension
;   - setup/install/config and the launcher's own files are skipped
;   - GAME.TXT supplies title and may override exe
;   - output sorted by title, CRLF, ASCII
;
; Deliberately NOT mirrored (do these on a modern machine if you want them):
;   - the curated preferred-executable list
;   - DOSBox wrapper-script detection
;   - genre headers and the sample catalog
;
; nasm -f bin -o SCAN.COM scan.asm
;==============================================================================

        bits    16
        cpu     8086
        org     100h

MAX_GAMES       equ     256
MAX_DEPTH       equ     3               ; levels below the games root
PATH_MAX        equ     128
; Field widths match dgb/scan.py's ascii_clean() limits, so both scanners
; truncate identically.
DIRLEN          equ     40
EXELEN          equ     12
TITLELEN        equ     40
YEARLEN         equ     4
GENRELEN        equ     16
PUBLEN          equ     20
NOTELEN         equ     40

; 41 + 13 + 41 + 5 + 17 + 21 + 41 = 179 -> 180 keeps records even-aligned
REC_SIZE        equ     180
OFF_DIR         equ     0
OFF_EXE         equ     41
OFF_TITLE       equ     54
OFF_YEAR        equ     95
OFF_GENRE       equ     100
OFF_PUB         equ     117
OFF_NOTE        equ     138

DTA_SIZE        equ     43
DTA_ATTR        equ     15h
DTA_NAME        equ     1Eh
ATTR_DIR        equ     10h

start:
        mov     ax, cs
        mov     ds, ax
        mov     es, ax
        cli
        mov     ss, ax
        mov     sp, stack_top
        sti

        call    shrink_mem
        call    parse_cmdline
        jnc     .have_root

        mov     dx, msg_usage
        call    dos_print
        mov     ax, 4C01h
        int     21h

.have_root:
        mov     dx, msg_scanning
        call    dos_print
        mov     si, root
        call    dos_print_z             ; root is ASCIIZ, not '$'-terminated
        call    dos_crlf

        ; curpath starts as the games root; root_len marks where the
        ; relative part begins when a game is recorded.
        mov     si, root
        mov     di, curpath
        call    strcpy
        mov     ax, di
        sub     ax, curpath
        mov     [root_len], ax

        xor     ax, ax
        mov     [n_games], ax
        xor     ax, ax                  ; depth 0
        call    scan_dir

        cmp     word [n_games], 0
        jne     .found
        mov     dx, msg_none
        call    dos_print
        mov     ax, 4C01h
        int     21h

.found:
        call    sort_games
        call    write_lst
        jnc     .wrote
        mov     dx, msg_werr
        call    dos_print
        mov     ax, 4C02h
        int     21h
.wrote:
        call    write_cfg

        mov     ax, [n_games]
        mov     di, numbuf
        call    putdec
        mov     byte [di], '$'
        mov     dx, msg_wrote
        call    dos_print
        mov     dx, numbuf
        call    dos_print
        mov     dx, msg_wrote2
        call    dos_print

        mov     ax, 4C00h
        int     21h

;------------------------------------------------------------------------------
; Command line: SCAN <games-root>
; The root is never assumed — the same rule the Python tooling follows.
; CF=1 when nothing usable was given.
;------------------------------------------------------------------------------
parse_cmdline:
        xor     cx, cx
        mov     cl, [80h]
        or      cl, cl
        jz      .bad

        mov     si, 81h
.skip:  mov     al, [si]
        cmp     al, ' '
        je      .adv
        cmp     al, 9
        jne     .copy
.adv:   inc     si
        dec     cx
        jnz     .skip
        jmp     .bad

.copy:  mov     di, root
        xor     dx, dx
.c1:    mov     al, [si]
        cmp     al, 0
        je      .done
        cmp     al, 13
        je      .done
        cmp     al, ' '
        je      .done
        cmp     al, 9
        je      .done
        cmp     al, '/'                 ; accept either separator
        jne     .c2
        mov     al, '\'
.c2:    cmp     al, 'a'
        jb      .c3
        cmp     al, 'z'
        ja      .c3
        sub     al, 20h                 ; DOS paths are conventionally upper
.c3:    mov     [di], al
        inc     di
        inc     dx
        cmp     dx, PATH_MAX-16
        jae     .done
        inc     si
        dec     cx
        jnz     .c1
.done:
        mov     byte [di], 0
        or      dx, dx
        jz      .bad
        ; a trailing separator would double up when we append
        cmp     byte [di-1], '\'
        jne     .ok
        mov     byte [di-1], 0
.ok:    clc
        ret
.bad:   stc
        ret

;------------------------------------------------------------------------------
; scan_dir — AX = depth. curpath holds the directory to examine.
;
; A directory containing a launchable file is a game and is not descended
; into, so a game's own UTILS or DATA subfolders never become entries.
;------------------------------------------------------------------------------
scan_dir:
        push    bp
        mov     bp, sp
        sub     sp, 4                   ; [bp-2] depth, [bp-4] this level's DTA
        mov     [bp-2], ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        cmp     word [bp-2], 0
        je      .descend                ; the root itself is never a game

        call    pick_exe
        jc      .descend                ; nothing launchable here
        call    record_game
        jmp     .out

.descend:
        mov     ax, [bp-2]
        cmp     ax, MAX_DEPTH
        jae     .out

        ; One DTA per level: recursion would otherwise clobber the enumeration
        ; this level is in the middle of.
        mov     bx, DTA_SIZE
        mul     bx
        add     ax, dta_table
        mov     [bp-4], ax
        mov     dx, ax
        mov     ah, 1Ah
        int     21h

        call    path_end
        mov     si, pat_all
        call    strcpy                  ; curpath + "\*.*"

        mov     ah, 4Eh
        mov     cx, ATTR_DIR
        mov     dx, curpath
        int     21h
        pushf
        call    path_trim               ; drop the pattern once, right here:
        popf                            ; trimming per iteration would eat a
        jc      .out                    ; real component on the second pass

.each:
        mov     bx, [bp-4]
        test    byte [bx+DTA_ATTR], ATTR_DIR
        jz      .next
        cmp     byte [bx+DTA_NAME], '.' ; covers both "." and ".."
        je      .next

        call    path_end                ; curpath = curpath + "\" + name
        mov     al, '\'
        mov     [di], al
        inc     di
        mov     bx, [bp-4]
        lea     si, [bx+DTA_NAME]
        call    strcpy

        mov     ax, [bp-2]
        inc     ax
        call    scan_dir

        call    path_trim

.next:
        mov     dx, [bp-4]              ; our DTA must be current for FindNext
        mov     ah, 1Ah
        int     21h
        mov     ah, 4Fh
        int     21h
        jnc     .each

.out:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        mov     sp, bp
        pop     bp
        ret

;------------------------------------------------------------------------------
; pick_exe — best launchable directly inside curpath.
; Result in exebuf. CF=1 if there is none.
; .BAT beats .EXE beats .COM; alphabetically first within an extension.
;------------------------------------------------------------------------------
pick_exe:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        mov     byte [exebuf], 0

        mov     si, ext_bat
        call    try_ext
        jnc     .hit
        mov     si, ext_exe
        call    try_ext
        jnc     .hit
        mov     si, ext_com
        call    try_ext
        jnc     .hit

        stc
        jmp     .out
.hit:   clc
.out:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; try_ext — SI = "\*.BAT" style pattern. Best match into exebuf. CF=1 = none.
try_ext:
        push    ax
        push    bx
        push    cx
        push    dx
        push    di

        call    path_end
        call    strcpy                  ; curpath + pattern

        mov     dx, dta_pick
        mov     ah, 1Ah
        int     21h

        mov     ah, 4Eh
        xor     cx, cx                  ; normal files only
        mov     dx, curpath
        int     21h
        jc      .none

        mov     byte [bestbuf], 0
.loop:
        mov     si, dta_pick + DTA_NAME
        call    is_skipped
        jc      .adv
        cmp     byte [bestbuf], 0
        je      .take
        mov     si, dta_pick + DTA_NAME
        mov     di, bestbuf
        call    stricmp
        jnc     .adv                    ; current best is <= this name
.take:
        mov     si, dta_pick + DTA_NAME
        mov     di, bestbuf
        call    strcpy
.adv:
        mov     dx, dta_pick
        mov     ah, 1Ah
        int     21h
        mov     ah, 4Fh
        int     21h
        jnc     .loop

        cmp     byte [bestbuf], 0
        je      .none
        mov     si, bestbuf
        mov     di, exebuf
        call    strcpy
        call    path_trim
        clc
        jmp     .out
.none:
        call    path_trim
        stc
.out:
        pop     di
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; is_skipped — SI = filename. CF=1 when it must not be treated as a game.
is_skipped:
        push    ax
        push    si
        push    di
        mov     di, skip_list
.next:
        cmp     byte [di], 0
        je      .no
        push    si
        push    di
        call    stricmp_eq
        pop     di
        pop     si
        jc      .yes
        ; advance past this entry
.adv:   cmp     byte [di], 0
        je      .adv2
        inc     di
        jmp     .adv
.adv2:  inc     di
        jmp     .next
.yes:
        pop     di
        pop     si
        pop     ax
        stc
        ret
.no:
        pop     di
        pop     si
        pop     ax
        clc
        ret

;------------------------------------------------------------------------------
; record_game — store the current directory, its exe, and a title.
;------------------------------------------------------------------------------
record_game:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        mov     ax, [n_games]
        cmp     ax, MAX_GAMES
        jae     .full

        call    read_game_txt           ; fills titlebuf, may override exebuf

        mov     ax, [n_games]
        mov     bx, REC_SIZE
        mul     bx
        mov     bx, games
        add     bx, ax                  ; BX = record base

        mov     di, bx                  ; dir, relative to the games root
        mov     si, curpath
        add     si, [root_len]
        cmp     byte [si], '\'
        jne     .nolead
        inc     si
.nolead:
        mov     cx, DIRLEN
        call    strcpyn

        mov     di, bx
        add     di, OFF_EXE
        mov     si, exebuf
        mov     cx, EXELEN
        call    strcpyn

        mov     di, bx
        add     di, OFF_TITLE
        mov     si, titlebuf
        mov     cx, TITLELEN
        call    strcpyn

        mov     di, bx
        add     di, OFF_YEAR
        mov     si, yearbuf
        mov     cx, YEARLEN
        call    strcpyn

        mov     di, bx
        add     di, OFF_GENRE
        mov     si, genrebuf
        mov     cx, GENRELEN
        call    strcpyn

        mov     di, bx
        add     di, OFF_PUB
        mov     si, pubbuf
        mov     cx, PUBLEN
        call    strcpyn

        mov     di, bx
        add     di, OFF_NOTE
        mov     si, notebuf
        mov     cx, NOTELEN
        call    strcpyn

        inc     word [n_games]
.full:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

;------------------------------------------------------------------------------
; read_game_txt — parse curpath\GAME.TXT for title= and exe=.
; titlebuf always ends up with something; exebuf is only overwritten when the
; file names an executable.
;------------------------------------------------------------------------------
read_game_txt:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        mov     byte [yearbuf], 0
        mov     byte [genrebuf], 0
        mov     byte [pubbuf], 0
        mov     byte [notebuf], 0

        ; Default title is the directory name, title-cased the way
        ; dgb/scan.py's title_from_path does it.
        call    last_component
        mov     di, titlebuf
        mov     cx, TITLELEN
        call    strcpyn
        mov     si, titlebuf
        call    title_case

        call    path_end
        mov     si, gametxt
        call    strcpy

        mov     ax, 3D00h
        mov     dx, curpath
        int     21h
        jc      .no_file
        mov     [gfh], ax

        mov     ah, 3Fh
        mov     bx, [gfh]
        mov     cx, GBUF_MAX
        mov     dx, gbuf
        int     21h
        jc      .close
        mov     si, gbuf
        add     si, ax
        mov     byte [si], 0
.close:
        mov     ah, 3Eh
        mov     bx, [gfh]
        int     21h

        mov     si, gbuf
.line:
        cmp     byte [si], 0
        je      .done
        ; skip leading blanks
.lsp:   mov     al, [si]
        cmp     al, ' '
        je      .lsp_adv
        cmp     al, 9
        jne     .lchk
.lsp_adv:
        inc     si
        jmp     .lsp
.lchk:
        cmp     al, '#'
        je      .skipline
        cmp     al, ';'
        je      .skipline

        push    si
        mov     di, key_title
        call    match_key
        jc      .got_title
        pop     si
        push    si
        mov     di, key_exe
        call    match_key
        jc      .got_exe
        pop     si
        push    si
        mov     di, key_year
        call    match_key
        jc      .got_year
        pop     si
        push    si
        mov     di, key_genre
        call    match_key
        jc      .got_genre
        pop     si
        push    si
        mov     di, key_pub
        call    match_key
        jc      .got_pub
        pop     si
        push    si
        mov     di, key_note
        call    match_key
        jc      .got_note
        pop     si
        jmp     .skipline

.got_title:
        add     sp, 2
        mov     di, titlebuf
        mov     cx, TITLELEN
        call    copy_value
        jmp     .skipline

.got_exe:
        add     sp, 2
        mov     di, exebuf
        mov     cx, EXELEN
        call    copy_value
        jmp     .skipline

.got_year:
        add     sp, 2
        mov     di, yearbuf
        mov     cx, YEARLEN
        call    copy_value
        jmp     .skipline

.got_genre:
        add     sp, 2
        mov     di, genrebuf
        mov     cx, GENRELEN
        call    copy_value
        jmp     .skipline

.got_pub:
        add     sp, 2
        mov     di, pubbuf
        mov     cx, PUBLEN
        call    copy_value
        jmp     .skipline

.got_note:
        add     sp, 2
        mov     di, notebuf
        mov     cx, NOTELEN
        call    copy_value
        jmp     .skipline

.skipline:
        mov     al, [si]
        cmp     al, 0
        je      .done
        inc     si
        cmp     al, 10
        je      .line
        jmp     .skipline

.done:
        call    path_trim
        jmp     .out
.no_file:
        call    path_trim
.out:
        cmp     byte [genrebuf], 0      ; scan.py defaults an absent genre
        jne     .have_genre
        mov     si, def_genre
        mov     di, genrebuf
        call    strcpy
.have_genre:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; match_key — DI = "title=" style literal, SI = text. CF=1 and SI advanced on
; a case-insensitive match.
match_key:
        push    ax
        push    bx
.m1:    mov     al, [di]
        cmp     al, 0
        je      .ok
        mov     bl, [si]
        or      al, 20h
        or      bl, 20h
        cmp     bl, al
        jne     .bad
        inc     si
        inc     di
        jmp     .m1
.ok:    stc
        pop     bx
        pop     ax
        ret
.bad:   clc
        pop     bx
        pop     ax
        ret

; copy_value — SI = after '=', DI = dest, CX = max. Stops at CR/LF/NUL,
; trims trailing blanks.
copy_value:
        push    ax
        push    bx
        push    dx
        xor     dx, dx
        mov     bx, di
.skip:  mov     al, [si]
        cmp     al, ' '
        je      .skip_adv
        cmp     al, 9
        jne     .cp
.skip_adv:
        inc     si
        jmp     .skip
.cp:    mov     al, [si]
        cmp     al, 0
        je      .end
        cmp     al, 13
        je      .end
        cmp     al, 10
        je      .end
        cmp     al, '|'                 ; would corrupt the index format
        jne     .cp2
        mov     al, '/'
.cp2:   cmp     dx, cx
        jae     .adv
        mov     [di], al
        inc     di
        inc     dx
.adv:   inc     si
        jmp     .cp
.end:
        ; trim trailing blanks
.tr:    cmp     di, bx
        jbe     .fin
        cmp     byte [di-1], ' '
        je      .tr_del
        cmp     byte [di-1], 9
        jne     .fin
.tr_del:
        dec     di
        jmp     .tr
.fin:
        mov     byte [di], 0
        pop     dx
        pop     bx
        pop     ax
        ret

;------------------------------------------------------------------------------
; sort_games — insertion sort by title, so the menu reads alphabetically.
;------------------------------------------------------------------------------
sort_games:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        mov     cx, 1
.outer:
        cmp     cx, [n_games]
        jae     .done

        mov     ax, cx
        call    rec_addr                ; SI = record cx
        mov     di, tmprec
        push    cx
        mov     cx, REC_SIZE
        call    memcpy
        pop     cx

        mov     dx, cx                  ; dx = j
.inner:
        or      dx, dx
        jz      .place
        mov     ax, dx
        dec     ax
        call    rec_addr                ; SI = record j-1
        push    si
        add     si, OFF_TITLE
        mov     di, tmprec + OFF_TITLE
        call    stricmp                 ; CF=1 when [si] > [di]
        pop     si
        jnc     .place

        push    si                      ; shift record j-1 up into slot j
        mov     ax, dx
        call    rec_addr
        mov     di, si
        pop     si
        push    cx
        mov     cx, REC_SIZE
        call    memcpy
        pop     cx
        dec     dx
        jmp     .inner

.place:
        mov     ax, dx
        call    rec_addr
        mov     di, si
        mov     si, tmprec
        push    cx
        mov     cx, REC_SIZE
        call    memcpy
        pop     cx

        inc     cx
        jmp     .outer
.done:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; rec_addr — AX = index, returns SI = record address.
rec_addr:
        push    ax
        push    bx
        push    dx
        mov     bx, REC_SIZE
        mul     bx
        mov     si, games
        add     si, ax
        pop     dx
        pop     bx
        pop     ax
        ret

;------------------------------------------------------------------------------
; write_lst — GAMES.LST in the current directory. CF=1 on failure.
;------------------------------------------------------------------------------
write_lst:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, lst_name
        int     21h
        jc      .fail
        mov     [ofh], ax

        mov     si, hdr_text
        call    out_str

        xor     bx, bx                  ; index
.each:
        cmp     bx, [n_games]
        jae     .close

        mov     di, linebuf
        mov     al, 'G'
        stosb
        mov     al, '|'
        stosb

        push    bx
        mov     ax, bx
        call    rec_addr
        push    si
        call    cpy_field               ; dir
        mov     al, '|'
        stosb
        pop     si
        push    si
        add     si, OFF_EXE
        call    cpy_field               ; exe
        mov     al, '|'
        stosb
        pop     si
        push    si
        add     si, OFF_TITLE
        call    cpy_field               ; title
        mov     al, '|'
        stosb
        pop     si
        push    si
        add     si, OFF_YEAR
        call    cpy_field
        mov     al, '|'
        stosb
        pop     si
        push    si
        add     si, OFF_GENRE
        call    cpy_field
        mov     al, '|'
        stosb
        pop     si
        push    si
        add     si, OFF_PUB
        call    cpy_field
        mov     al, '|'
        stosb
        pop     si
        add     si, OFF_NOTE
        call    cpy_field
        pop     bx

        mov     al, 13
        stosb
        mov     al, 10
        stosb
        mov     byte [di], 0

        mov     si, linebuf
        call    out_str

        inc     bx
        jmp     .each

.close:
        mov     ah, 3Eh
        mov     bx, [ofh]
        int     21h
        clc
        jmp     .out
.fail:
        stc
.out:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; keep_cfg_lines — read DGB.CFG into cfgkeep, dropping comments and the
; GAMES_ROOT line we are about to rewrite. Everything else is carried across:
; ABORT_KEY is edited by hand here, and rewriting the file wholesale would
; delete it on the next scan without saying so.
keep_cfg_lines:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        mov     byte [cfgkeep], 0
        mov     ax, 3D00h
        mov     dx, cfg_name
        int     21h
        jc      .out
        mov     bx, ax

        push    bx
        mov     ah, 3Fh
        mov     cx, CFGBUF_MAX
        mov     dx, cfgbuf
        int     21h
        pop     bx
        jc      .close
        mov     si, cfgbuf
        add     si, ax
        mov     byte [si], 0
.close:
        mov     ah, 3Eh
        int     21h

        mov     si, cfgbuf
        mov     di, cfgkeep
.line:  cmp     byte [si], 0
        je      .done
        mov     bx, si                  ; start of this line

        ; comment or blank?
        mov     al, [si]
        cmp     al, ';'
        je      .skip
        cmp     al, '#'
        je      .skip
        cmp     al, 13
        je      .skip
        cmp     al, 10
        je      .skip

        push    si
        push    di
        mov     di, cfg_key             ; "GAMES_ROOT="
        call    match_lit
        pop     di
        pop     si
        jc      .skip                   ; ours; we rewrite it

        ; copy the line through, terminating at CR/LF
.cp:    mov     al, [si]
        cmp     al, 0
        je      .eol
        cmp     al, 13
        je      .eol
        cmp     al, 10
        je      .eol
        mov     [di], al
        inc     di
        inc     si
        jmp     .cp
.eol:   mov     byte [di], 13
        inc     di
        mov     byte [di], 10
        inc     di
        mov     byte [di], 0

.skip:  mov     si, bx                  ; advance to the next line
.adv:   mov     al, [si]
        cmp     al, 0
        je      .done
        inc     si
        cmp     al, 10
        je      .line
        jmp     .adv
.done:
.out:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; write_cfg — DGB.CFG recording where the games are, drive letter stripped.
write_cfg:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        call    keep_cfg_lines          ; before we truncate it

        mov     ah, 3Ch
        xor     cx, cx
        mov     dx, cfg_name
        int     21h
        jc      .out
        mov     [ofh], ax

        mov     si, cfg_hdr
        call    out_str

        mov     di, linebuf
        mov     si, cfg_key
        call    cpy_lit

        mov     si, root
        cmp     byte [si+1], ':'        ; drop "C:"
        jne     .nodrive
        add     si, 2
.nodrive:
        cmp     byte [si], '\'
        je      .abs
        mov     al, '\'
        stosb
.abs:
        call    cpy_field
        mov     al, 13
        stosb
        mov     al, 10
        stosb
        mov     byte [di], 0
        mov     si, linebuf
        call    out_str

        ; If nobody has set ABORT_KEY, leave the option visible. A shipped
        ; template's comments do not survive this rewrite.
        mov     si, cfgkeep
        mov     di, cfg_akey
        call    find_lit
        jc      .have_key
        mov     si, cfg_akey_hint
        call    out_str
.have_key:

        mov     si, cfgkeep             ; settings we do not own
        call    out_str

        mov     ah, 3Eh
        mov     bx, [ofh]
        int     21h
.out:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; out_str — SI = asciiz, write to [ofh]
out_str:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        mov     dx, si
        xor     cx, cx
.len:   cmp     byte [si], 0
        je      .go
        inc     si
        inc     cx
        jmp     .len
.go:    or      cx, cx
        jz      .out
        mov     ah, 40h
        mov     bx, [ofh]
        int     21h
.out:
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; cpy_field / cpy_lit — SI asciiz -> DI, DI advanced, no terminator written
cpy_field:
cpy_lit:
        push    ax
.c1:    mov     al, [si]
        cmp     al, 0
        je      .done
        mov     [di], al
        inc     di
        inc     si
        jmp     .c1
.done:  pop     ax
        ret

;------------------------------------------------------------------------------
; String and path helpers
;------------------------------------------------------------------------------

; strcpy — SI -> DI including terminator; DI left on the terminator.
strcpy:
        push    ax
.s1:    mov     al, [si]
        mov     [di], al
        inc     si
        cmp     al, 0
        je      .done
        inc     di
        jmp     .s1
.done:  pop     ax
        ret

; strcpyn — SI -> DI, at most CX characters, always terminated.
strcpyn:
        push    ax
        push    dx
        xor     dx, dx
.s1:    mov     al, [si]
        cmp     al, 0
        je      .done
        cmp     dx, cx
        jae     .adv
        mov     [di], al
        inc     di
        inc     dx
.adv:   inc     si
        jmp     .s1
.done:  mov     byte [di], 0
        pop     dx
        pop     ax
        ret

; memcpy — SI -> DI, CX bytes
memcpy:
        push    ax
        push    cx
        push    si
        push    di
.m1:    or      cx, cx
        jz      .done
        mov     al, [si]
        mov     [di], al
        inc     si
        inc     di
        dec     cx
        jmp     .m1
.done:  pop     di
        pop     si
        pop     cx
        pop     ax
        ret

; stricmp — CF=1 when string at SI sorts after string at DI (case-insensitive)
stricmp:
        push    ax
        push    bx
        push    si
        push    di
.c1:    mov     al, [si]
        mov     bl, [di]
        cmp     al, 'a'
        jb      .u1
        cmp     al, 'z'
        ja      .u1
        sub     al, 20h
.u1:    cmp     bl, 'a'
        jb      .u2
        cmp     bl, 'z'
        ja      .u2
        sub     bl, 20h
.u2:    cmp     al, bl
        ja      .after
        jb      .before
        or      al, al
        jz      .before                 ; equal strings: not "after"
        inc     si
        inc     di
        jmp     .c1
.after: pop     di
        pop     si
        pop     bx
        pop     ax
        stc
        ret
.before:
        pop     di
        pop     si
        pop     bx
        pop     ax
        clc
        ret

; find_lit — CF=1 if the literal at DI appears anywhere in the string at SI.
find_lit:
        push    ax
        push    bx
        push    si
        push    di
.f1:    cmp     byte [si], 0
        je      .no
        push    si
        push    di
        call    match_lit
        pop     di
        pop     si
        jc      .yes
        inc     si
        jmp     .f1
.yes:   pop     di
        pop     si
        pop     bx
        pop     ax
        stc
        ret
.no:    pop     di
        pop     si
        pop     bx
        pop     ax
        clc
        ret

; match_lit — DI = literal, SI = text. CF=1 and SI advanced on a
; case-insensitive match; SI is left alone otherwise.
match_lit:
        push    ax
        push    bx
        push    si
.m1:    mov     al, [di]
        cmp     al, 0
        je      .ok
        mov     bl, [si]
        or      al, 20h
        or      bl, 20h
        cmp     bl, al
        jne     .bad
        inc     si
        inc     di
        jmp     .m1
.ok:    add     sp, 2                   ; keep the advanced SI
        pop     bx
        pop     ax
        stc
        ret
.bad:   pop     si
        pop     bx
        pop     ax
        clc
        ret

; stricmp_eq — CF=1 when the strings match case-insensitively
stricmp_eq:
        push    ax
        push    bx
.c1:    mov     al, [si]
        mov     bl, [di]
        cmp     al, 'a'
        jb      .u1
        cmp     al, 'z'
        ja      .u1
        sub     al, 20h
.u1:    cmp     bl, 'a'
        jb      .u2
        cmp     bl, 'z'
        ja      .u2
        sub     bl, 20h
.u2:    cmp     al, bl
        jne     .no
        or      al, al
        jz      .yes
        inc     si
        inc     di
        jmp     .c1
.yes:   pop     bx
        pop     ax
        stc
        ret
.no:    pop     bx
        pop     ax
        clc
        ret

; path_end — DI = the terminator of curpath
path_end:
        mov     di, curpath
.p1:    cmp     byte [di], 0
        je      .done
        inc     di
        jmp     .p1
.done:  ret

; path_trim — remove the last "\component" from curpath
path_trim:
        push    ax
        push    di
        call    path_end
.t1:    cmp     di, curpath
        jbe     .done
        dec     di
        cmp     byte [di], '\'
        jne     .t1
        mov     byte [di], 0
.done:  pop     di
        pop     ax
        ret

; last_component — SI = the final component of curpath
last_component:
        push    ax
        push    di
        call    path_end
        mov     si, curpath
.l1:    cmp     di, curpath
        jbe     .done
        dec     di
        cmp     byte [di], '\'
        jne     .l1
        mov     si, di
        inc     si
.done:  pop     di
        pop     ax
        ret

; title_case — SI = asciiz, first letter of each word upper, rest lower.
; Matches str.title() closely enough for 8.3 directory names.
title_case:
        push    ax
        push    bx
        push    si
        mov     bl, 1                   ; at a word boundary
.t1:    mov     al, [si]
        cmp     al, 0
        je      .done
        cmp     al, 'a'
        jb      .isupper_check
        cmp     al, 'z'
        ja      .isupper_check
        ; lowercase letter
        or      bl, bl
        jz      .next
        sub     al, 20h
        mov     [si], al
        jmp     .letter
.isupper_check:
        cmp     al, 'A'
        jb      .nonletter
        cmp     al, 'Z'
        ja      .nonletter
        or      bl, bl
        jnz     .letter
        add     al, 20h
        mov     [si], al
        jmp     .letter
.nonletter:
        ; Any non-letter starts a new word, digits included: Python's
        ; str.title() uses isalpha(), so "2FAST4YO" becomes "2Fast4Yo".
        jmp     .boundary
.letter:
        mov     bl, 0
        jmp     .next
.boundary:
        mov     bl, 1
.next:  inc     si
        jmp     .t1
.done:  pop     si
        pop     bx
        pop     ax
        ret

; putdec — AX -> decimal at DI, DI advanced
putdec:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
.d1:    xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     .d1
.d2:    pop     ax
        add     al, '0'
        mov     [di], al
        inc     di
        dec     cx
        jnz     .d2
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

dos_print:
        push    ax
        mov     ah, 09h
        int     21h
        pop     ax
        ret

; dos_print_z — SI = ASCIIZ string, written to stdout. Function 09h stops at
; '$', which none of our path buffers contain, so they need this instead.
dos_print_z:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        mov     dx, si
        xor     cx, cx
.z1:    cmp     byte [si], 0
        je      .z2
        inc     si
        inc     cx
        jmp     .z1
.z2:    or      cx, cx
        jz      .z3
        mov     ah, 40h
        mov     bx, 1
        int     21h
.z3:    pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

dos_crlf:
        push    dx
        mov     dx, crlf_msg
        call    dos_print
        pop     dx
        ret

shrink_mem:
        push    ax
        push    bx
        push    cx
        push    es
        mov     ax, cs
        mov     es, ax
        mov     bx, end_prog + MAX_GAMES*REC_SIZE
        add     bx, 15
        mov     cl, 4
        shr     bx, cl
        add     bx, 16
        mov     ah, 4Ah
        int     21h
        pop     es
        pop     cx
        pop     bx
        pop     ax
        ret

;------------------------------------------------------------------------------
; Data
;------------------------------------------------------------------------------
        align   2
stack_bytes     times 512 dw 0
stack_top:

msg_usage       db 'SCAN - build GAMES.LST for DOS Game Browser',13,10
                db 13,10
                db 'Usage:  SCAN <games-root>',13,10
                db 13,10
                db 'Run it from the launcher directory, naming the directory',13,10
                db 'your games are under. For example:',13,10
                db 13,10
                db '    C:',13,10
                db '    CD \DGB',13,10
                db '    SCAN C:\GAMES',13,10
                db 13,10
                db 'Writes GAMES.LST and DGB.CFG here.',13,10,'$'
msg_scanning    db 'Scanning $'
msg_none        db 'No games found. Each game needs its own directory holding',13,10
                db 'a .BAT, .EXE or .COM, at most 3 levels below the root.',13,10,'$'
msg_wrote       db 'Wrote GAMES.LST with $'
msg_wrote2      db ' games, and DGB.CFG.',13,10,'$'
msg_werr        db 'ERROR: could not write GAMES.LST here.',13,10,'$'
crlf_msg        db 13,10,'$'

hdr_text        db '# GAMES.LST - generated by SCAN.COM on the DOS machine',13,10
                db '# Edit GAME.TXT in a game folder, then re-run SCAN.',13,10
                db 13,10,0

cfg_hdr         db '; DOS Game Browser runtime config',13,10
                db '; Written by SCAN.COM',13,10,0
cfg_key         db 'GAMES_ROOT=',0
cfg_akey        db 'ABORT_KEY=',0
cfg_akey_hint   db ';',13,10
                db '; ABORT_KEY is the single key that force-exits a stuck game.',13,10
                db '; F1-F12, or a raw make-code in hex. Defaults to F12. Change it if',13,10
                db '; a game needs that key for play.',13,10
                db ';ABORT_KEY=F12',13,10,0

lst_name        db 'GAMES.LST',0
cfg_name        db 'DGB.CFG',0
gametxt         db '\GAME.TXT',0
pat_all         db '\*.*',0
ext_bat         db '\*.BAT',0
ext_exe         db '\*.EXE',0
ext_com         db '\*.COM',0
key_title       db 'title=',0
key_exe         db 'exe=',0
key_year        db 'year=',0
key_genre       db 'genre=',0
key_pub         db 'publisher=',0
key_note        db 'note=',0
def_genre       db 'Other',0

; Not games: installers, DPMI stubs, archivers, and our own files.
skip_list       db 'SETUP.EXE',0
                db 'INSTALL.EXE',0
                db 'CONFIG.EXE',0
                db 'CWSDPMI.EXE',0
                db 'UNZIP.EXE',0
                db 'PKUNZIP.EXE',0
                db 'CATALOG.EXE',0
                db 'ABORT.COM',0
                db 'VDETECT.COM',0
                db 'BROWSER.COM',0
                db 'SCAN.COM',0
                db 0

n_games         dw 0
root_len        dw 0
gfh             dw 0
ofh             dw 0
dta_depth       dw 0

root            times PATH_MAX db 0
curpath         times PATH_MAX+16 db 0
exebuf          times EXELEN+2 db 0
bestbuf         times EXELEN+2 db 0
titlebuf        times TITLELEN+2 db 0
yearbuf         times YEARLEN+2 db 0
genrebuf        times GENRELEN+2 db 0
pubbuf          times PUBLEN+2 db 0
notebuf         times NOTELEN+2 db 0
linebuf         times 160 db 0
numbuf          times 8 db 0
tmprec          times REC_SIZE db 0

GBUF_MAX        equ 512
gbuf            times GBUF_MAX+2 db 0
CFGBUF_MAX      equ 2048
cfgbuf          times CFGBUF_MAX+2 db 0
cfgkeep         times CFGBUF_MAX+2 db 0

dta_table       times (MAX_DEPTH+1)*DTA_SIZE db 0
dta_pick        times DTA_SIZE db 0

        align   16
end_prog:
; The record table lives past the image, as in BROWSER.COM: a .COM owns its
; whole segment, so MAX_GAMES costs address space and nothing on disk.
games:
