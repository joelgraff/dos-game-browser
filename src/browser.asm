;==============================================================================
; BROWSER.COM — DOS game browser (direct text VRAM, 8086-safe)
;
; GAMES.LST:
;   H|Section
;   G|dir|exe|title|year|genre|publisher|note
;
; Keys: Up/Down/PgUp/PgDn/Home/End, Enter, Esc, F1=Help, A-Z jump
; nasm -f bin -o BROWSER.COM browser.asm
;==============================================================================

        bits    16
        cpu     8086
        org     100h

; Entry table holds only what the list view and A-Z jump need resident:
; type, title, and the file offset of the originating GAMES.LST line. Year,
; genre, publisher, note, dir and exe are re-read on demand (see fetch_rec),
; which keeps 320 slots cheaper than the old 64 and leaves more conventional
; memory free for the game that BROWSER.COM stays resident behind.
MAX_ENT         equ     320             ; slots, including headers and spacers
MAXLINE         equ     160             ; longest GAMES.LST line handled
TLEN            equ     32
YLEN            equ     4
GLEN            equ     12
PLEN            equ     16
NLEN            equ     32
DLEN            equ     32
ELEN            equ     12

; type:1 title:33 file offset:2 = 36
ENT_SIZE        equ     36
OFF_TYPE        equ     0
OFF_TITLE       equ     1
OFF_OFS         equ     34

VIEW_ROWS       equ     14
COLS            equ     80
LIST_WIDTH      equ     50              ; padded list line width for select bar

start:
        mov     ax, cs
        mov     ds, ax
        mov     es, ax
        cli
        mov     ss, ax
        mov     sp, stack_top
        sti

        call    check_selftest          ; read PSP tail before anything disturbs it

        call    shrink_mem

        cmp     byte [selftest_f], 0
        je      .normal
        cmp     byte [selftest_f], 2
        je      .runexec
        call    selftest
        mov     ax, 4C00h
        int     21h
.runexec:
        call    selftest_exec
        mov     ax, 4C00h
        int     21h
.normal:

        call    detect_video
        call    set_text_mode
        call    detect_abort
        call    init_paths

        call    load_list
        jnc     .loaded
        mov     si, msg_noload
        call    dos_print
        mov     ax, 4C01h
        int     21h
.loaded:
        cmp     word [n_ent], 0
        jne     .has
        mov     si, msg_empty
        call    dos_print
        mov     ax, 4C01h
        int     21h
.has:
        ; Snapshot INT vectors with ABORT already resident (autoexec loads it first)
        call    save_vectors

        call    first_game
        mov     [cur], ax
        call    show_with_header        ; scr so genre header above is visible

main:
        call    draw
        call    getkey
        cmp     al, 1
        je      .up
        cmp     al, 2
        je      .dn
        cmp     al, 3
        je      .go
        cmp     al, 4
        je      .esc
        cmp     al, 5
        je      .pu
        cmp     al, 6
        je      .pd
        cmp     al, 7
        je      .home
        cmp     al, 8
        je      .end
        cmp     al, 9
        je      .let
        cmp     al, 10
        je      .xesc
        jmp     main

.up:    mov     ax, [cur]
        call    prev_game
        mov     [cur], ax
        call    scroll_fix
        jmp     main
.dn:    mov     ax, [cur]
        call    next_game
        cmp     ax, 0FFFFh
        je      main
        mov     [cur], ax
        call    scroll_fix
        jmp     main
.pu:    mov     cx, 10
.pu1:   push    cx
        mov     ax, [cur]
        call    prev_game
        mov     [cur], ax
        pop     cx
        loop    .pu1
        call    scroll_fix
        jmp     main
.pd:    mov     cx, 10
.pd1:   push    cx
        mov     ax, [cur]
        call    next_game
        cmp     ax, 0FFFFh
        je      .pd2
        mov     [cur], ax
.pd2:   pop     cx
        loop    .pd1
        call    scroll_fix
        jmp     main
.home:  call    first_game
        mov     [cur], ax
        call    show_with_header
        jmp     main
.end:   call    last_game
        mov     [cur], ax
        call    scroll_fix
        jmp     main
.let:   call    jump_let
        jmp     main
.go:    mov     bx, [cur]
        call    is_hdr
        jc      main
        call    launch
        ; Always full recovery after game (normal exit or ABORT)
        call    reinit_after_game
        jmp     main
.esc:   call    set_text_mode
        mov     ax, 4C00h
        int     21h
.xesc:  call    set_text_mode
        mov     ax, 4C2Ah             ; hidden maintenance exit (ERRORLEVEL 42)
        int     21h

;------------------------------------------------------------------------------
; Video
;------------------------------------------------------------------------------
detect_video:
        mov     word [vseg], 0B800h
        mov     byte [attr_norm], 1Fh
        mov     byte [attr_title], 1Eh
        mov     byte [attr_dim], 17h
        mov     byte [attr_hdr], 1Eh
        mov     byte [attr_sel], 70h
        mov     byte [attr_abort], 1Ch  ; bright red on blue
        mov     byte [attr_err], 4Fh

        mov     ah, 0Fh
        int     10h
        cmp     al, 7
        je      .mono
        int     11h
        and     al, 30h
        cmp     al, 30h
        jne     .done
.mono:
        mov     word [vseg], 0B000h
        mov     byte [attr_norm], 07h
        mov     byte [attr_title], 0Fh
        mov     byte [attr_dim], 07h
        mov     byte [attr_hdr], 0Fh
        mov     byte [attr_sel], 70h
        mov     byte [attr_abort], 0Fh  ; bright on mono
        mov     byte [attr_err], 70h
.done:  ret

set_text_mode:
        mov     ax, [vseg]
        cmp     ax, 0B000h
        je      .m
        mov     ax, 0003h
        int     10h
        ret
.m:     mov     ax, 0007h
        int     10h
        ret

;------------------------------------------------------------------------------
; Is ABORT.COM resident? Same INT 2Fh multiplex signature ABORT.COM installs
; with (AX=AB00h -> AL=ABh).
;------------------------------------------------------------------------------
detect_abort:
        push    ax
        mov     byte [abort_res], 0
        mov     ax, 0AB00h
        int     2Fh
        cmp     al, 0ABh
        jne     .da_done
        mov     byte [abort_res], 1
.da_done:
        pop     ax
        ret

;------------------------------------------------------------------------------
; Optional path config (DGB.CFG)
;   GAMES_ROOT=GAMES
;   GAMES_ROOT=\GAMES
;------------------------------------------------------------------------------
init_paths:
        ; Defaults preserve legacy behavior.
        mov     byte [cfg_found], 0
        mov     di, pfx
        mov     si, pfx_def
        call    cpy
        mov     di, pfx_abs
        mov     si, pfx_abs_def
        call    cpy

        mov     ax, 3D00h
        mov     dx, cfg_name
        int     21h
        jc      .ip_done

        mov     byte [cfg_found], 1
        mov     [fh], ax
        mov     ah, 3Fh
        mov     bx, [fh]
        mov     cx, 240
        mov     dx, cfg_buf
        int     21h
        jc      .ip_close

        mov     si, cfg_buf
        add     si, ax
        mov     byte [si], 0

.ip_close:
        mov     ah, 3Eh
        mov     bx, [fh]
        int     21h

        ; Scan line by line. The key is only honored at the start of a line so
        ; that a commented-out GAMES_ROOT= cannot override the real one.
        mov     si, cfg_buf
.ip_line:
        cmp     byte [si], 0
        je      .ip_done
.ip_lsp:                                ; skip leading blanks
        mov     al, [si]
        cmp     al, ' '
        je      .ip_lsp_adv
        cmp     al, 9
        jne     .ip_lchk
.ip_lsp_adv:
        inc     si
        jmp     .ip_lsp
.ip_lchk:
        cmp     al, 0
        je      .ip_done
        cmp     al, ';'                 ; comment
        je      .ip_next
        cmp     al, '#'                 ; comment
        je      .ip_next
        cmp     al, 13                  ; blank line
        je      .ip_next
        cmp     al, 10
        je      .ip_next
        mov     di, games_key
        push    si
        call    match_lit
        jc      .ip_found
        pop     si
.ip_next:                               ; advance past end of this line
        mov     al, [si]
        cmp     al, 0
        je      .ip_done
        inc     si
        cmp     al, 10
        je      .ip_line
        jmp     .ip_next

.ip_found:
        add     sp, 2
        ; SI now points to value after key.
.ip_skip:
        cmp     byte [si], ' '
        je      .ip_skip_adv
        cmp     byte [si], 9
        jne     .ip_copy
.ip_skip_adv:
        inc     si
        jmp     .ip_skip

.ip_copy:
        mov     di, root_val
        mov     cx, 60
.ip_c1:
        cmp     cx, 0
        je      .ip_cend
        mov     al, [si]
        cmp     al, 0
        je      .ip_cend
        cmp     al, 13
        je      .ip_cend
        cmp     al, 10
        je      .ip_cend
        cmp     al, ';'
        je      .ip_cend
        cmp     al, '/'
        jne     .ip_c2
        mov     al, 5Ch
.ip_c2:
        stosb
        inc     si
        dec     cx
        jmp     .ip_c1

.ip_cend:
        mov     byte [di], 0
        cmp     byte [root_val], 0
        je      .ip_done

        ; pfx = root value without leading '\\', with trailing '\\'
        mov     si, root_val
        cmp     byte [si], 5Ch
        jne     .ip_rel
        inc     si
.ip_rel:
        mov     di, pfx
        call    copy_root_rel

        ; pfx_abs = '\\' + root value without leading '\\', trailing '\\'
        mov     si, root_val
        cmp     byte [si], 5Ch
        jne     .ip_abs1
        inc     si
.ip_abs1:
        mov     di, pfx_abs
        mov     al, 5Ch
        stosb
        call    copy_root_tail

.ip_done:
        ret

; Compare literal DI with string at SI. On match, CF=1 and SI advanced.
match_lit:
        push    ax
        push    bx
.ml1:   mov     al, [di]
        cmp     al, 0
        je      .ml_ok
        mov     bl, [si]
        or      al, 20h                 ; fold case; safe for the key charset
        or      bl, 20h                 ; (A-Z already fold, '_' and '=' unchanged)
        cmp     bl, al
        jne     .ml_bad
        inc     si
        inc     di
        jmp     .ml1
.ml_ok: stc
        pop     bx
        pop     ax
        ret
.ml_bad:
        clc
        pop     bx
        pop     ax
        ret

; DI destination, SI source root (no leading '\\'). Writes trailing '\\'.
copy_root_rel:
        cmp     byte [si], 0
        je      .crr_done
.crr1:  mov     al, [si]
        cmp     al, 0
        je      .crr2
        stosb
        inc     si
        jmp     .crr1
.crr2:  cmp     byte [di-1], 5Ch
        je      .crr_done
        mov     al, 5Ch
        stosb
.crr_done:
        mov     byte [di], 0
        ret

; DI destination (after optional prefix), SI source root body.
copy_root_tail:
        cmp     byte [si], 0
        je      .crt_only
.crt1:  mov     al, [si]
        cmp     al, 0
        je      .crt2
        stosb
        inc     si
        jmp     .crt1
.crt2:  cmp     byte [di-1], 5Ch
        je      .crt_done
        mov     al, 5Ch
        stosb
        jmp     .crt_done
.crt_only:
        cmp     byte [di-1], 5Ch
        je      .crt_done
        mov     al, 5Ch
        stosb
.crt_done:
        mov     byte [di], 0
        ret

;------------------------------------------------------------------------------
; GAMES.LST access
;
; The index is parsed by walking the file one line at a time and recording each
; line's file offset in the entry table. The same read_line_at primitive is
; reused by fetch_rec to pull a full record back on demand, so only one piece of
; file-positioning logic exists.
;
; The handle stays open while browsing and is closed around EXEC so the child
; never inherits it.
;------------------------------------------------------------------------------

; Open the index, remembering which path resolved. CF=1 on failure.
; Idempotent: launch can bail out before closing, so drop any live handle first
; rather than leaking one per failed launch.
open_lst:
        call    close_lst
        mov     ax, 3D00h
        mov     dx, [lst_path]
        int     21h
        jc      .ol_bad
        mov     [fh], ax
        clc
        ret
.ol_bad:
        mov     word [fh], 0FFFFh
        stc
        ret

close_lst:
        push    ax
        push    bx
        cmp     word [fh], 0FFFFh
        je      .cl_done
        mov     ah, 3Eh
        mov     bx, [fh]
        int     21h
        mov     word [fh], 0FFFFh
.cl_done:
        pop     bx
        pop     ax
        ret

; DX = file offset. Reads that line into linebuf (NUL terminated, CR/LF
; stripped) and sets [line_len] to the bytes consumed including terminators.
; CF=1 at EOF or on error.
read_line_at:
        push    ax
        push    bx
        push    cx
        push    si
        cmp     word [fh], 0FFFFh
        je      .rl_bad

        mov     ax, 4200h               ; LSEEK from start
        mov     bx, [fh]
        xor     cx, cx
        int     21h
        jc      .rl_bad

        mov     ah, 3Fh
        mov     bx, [fh]
        mov     cx, MAXLINE
        mov     dx, linebuf
        int     21h
        jc      .rl_bad
        or      ax, ax
        jz      .rl_bad                 ; EOF

        mov     si, linebuf
        add     si, ax
        mov     byte [si], 0

        mov     si, linebuf
        xor     cx, cx
.rl_scan:
        mov     al, [si]
        cmp     al, 0
        je      .rl_end
        cmp     al, 13
        je      .rl_cr
        cmp     al, 10
        je      .rl_lf
        inc     si
        inc     cx
        jmp     .rl_scan
.rl_cr:
        mov     byte [si], 0
        inc     cx
        inc     si
        cmp     byte [si], 10           ; CRLF consumes both
        jne     .rl_end
        inc     cx
        jmp     .rl_end
.rl_lf:
        mov     byte [si], 0
        inc     cx
.rl_end:
        or      cx, cx                  ; never advance by zero
        jnz     .rl_ok
        inc     cx
.rl_ok:
        mov     [line_len], cx
        pop     si
        pop     cx
        pop     bx
        pop     ax
        clc
        ret
.rl_bad:
        pop     si
        pop     cx
        pop     bx
        pop     ax
        stc
        ret

; Advance SI past the next '|' (or to the NUL).
skip_field:
.sf1:   mov     al, [si]
        cmp     al, 0
        je      .sf_done
        inc     si
        cmp     al, '|'
        je      .sf_done
        jmp     .sf1
.sf_done:
        ret

;------------------------------------------------------------------------------
; LOAD GAMES.LST — record type, title and file offset per line
;------------------------------------------------------------------------------
load_list:
        mov     word [fh], 0FFFFh
        mov     word [lst_path], fname
        call    open_lst
        jnc     .ok
        mov     word [lst_path], fname2
        call    open_lst
        jnc     .ok
        stc
        ret
.ok:
        mov     word [n_ent], 0
        mov     word [cur_ofs], 0

.loop:
        mov     ax, [n_ent]
        cmp     ax, MAX_ENT
        jae     .done                   ; table full; tooling guards against this

        mov     dx, [cur_ofs]
        mov     [line_ofs], dx
        call    read_line_at
        jc      .done

        mov     ax, [cur_ofs]
        add     ax, [line_len]
        mov     [cur_ofs], ax

        mov     si, linebuf
        cmp     byte [si], 0
        je      .loop
        cmp     byte [si], '#'
        je      .loop
        mov     al, [si]
        or      al, 20h
        cmp     al, 'h'
        je      .H
        cmp     al, 'g'
        je      .G
        jmp     .loop

.H:     cmp     byte [si+1], '|'
        jne     .loop
        ; blank spacer between the previous category and this header
        mov     ax, [n_ent]
        or      ax, ax
        jz      .Hadd
        cmp     ax, MAX_ENT
        jae     .done
        call    ent_addr_ax             ; DI = slot
        mov     byte [di], 2            ; type 2 = blank spacer
        inc     word [n_ent]
.Hadd:
        mov     ax, [n_ent]
        cmp     ax, MAX_ENT
        jae     .done
        call    ent_addr_ax
        mov     byte [di], 1            ; type 1 = section header
        push    di
        add     di, OFF_TITLE
        mov     si, linebuf
        add     si, 2
        mov     cx, TLEN
        call    store_pipe
        pop     di
        mov     ax, [line_ofs]
        mov     [di+OFF_OFS], ax
        inc     word [n_ent]
        jmp     .loop

.G:     cmp     byte [si+1], '|'
        jne     .loop
        mov     ax, [n_ent]
        cmp     ax, MAX_ENT
        jae     .done
        call    ent_addr_ax
        mov     byte [di], 0            ; type 0 = game
        push    di
        mov     si, linebuf
        add     si, 2
        call    skip_field              ; dir
        call    skip_field              ; exe
        pop     di
        push    di
        add     di, OFF_TITLE
        mov     cx, TLEN
        call    store_pipe
        pop     di
        mov     ax, [line_ofs]
        mov     [di+OFF_OFS], ax
        inc     word [n_ent]
        jmp     .loop

.done:
        clc
        ret

;------------------------------------------------------------------------------
; Re-read one full record from GAMES.LST into the r_* scratch buffers.
; BX = entry index. CF=1 if the entry has no record (header/spacer) or the
; read failed; scratch buffers are blanked in that case so callers render
; empty rather than stale text.
;------------------------------------------------------------------------------
fetch_rec:
        push    ax
        push    cx
        push    dx
        push    si
        push    di

        call    blank_rec

        mov     ax, bx
        mov     cx, ENT_SIZE
        mul     cx
        mov     si, entries
        add     si, ax
        cmp     byte [si], 0            ; games only
        jne     .fr_bad

        mov     dx, [si+OFF_OFS]
        call    read_line_at
        jc      .fr_bad

        mov     si, linebuf
        mov     al, [si]
        or      al, 20h
        cmp     al, 'g'
        jne     .fr_bad
        cmp     byte [si+1], '|'
        jne     .fr_bad
        add     si, 2

        mov     di, r_dir
        mov     cx, DLEN
        call    store_pipe
        mov     di, r_exe
        mov     cx, ELEN
        call    store_pipe
        mov     di, r_title
        mov     cx, TLEN
        call    store_pipe
        mov     di, r_year
        mov     cx, YLEN
        call    store_pipe
        mov     di, r_genre
        mov     cx, GLEN
        call    store_pipe
        mov     di, r_pub
        mov     cx, PLEN
        call    store_pipe
        mov     di, r_note
        mov     cx, NLEN
        call    store_str

        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     ax
        clc
        ret

.fr_bad:
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     ax
        stc
        ret

blank_rec:
        push    ax
        mov     byte [r_dir], 0
        mov     byte [r_exe], 0
        mov     byte [r_title], 0
        mov     byte [r_year], 0
        mov     byte [r_genre], 0
        mov     byte [r_pub], 0
        mov     byte [r_note], 0
        pop     ax
        ret

ent_addr_ax:
        push    ax
        push    cx
        push    dx
        mov     cx, ENT_SIZE
        mul     cx
        mov     di, entries
        add     di, ax
        push    di
        mov     cx, ENT_SIZE
        xor     al, al
        rep     stosb
        pop     di
        pop     dx
        pop     cx
        pop     ax
        ret


store_str:
        xor     dx, dx
.ss1:   lodsb
        cmp     al, 0
        je      .ss2
        cmp     dx, cx
        jae     .ss1
        stosb
        inc     dx
        jmp     .ss1
.ss2:   xor     al, al
        stosb
        ret

store_pipe:
        xor     dx, dx
.sp1:   lodsb
        cmp     al, 0
        je      .sp2
        cmp     al, '|'
        je      .sp3
        cmp     dx, cx
        jae     .sp1
        stosb
        inc     dx
        jmp     .sp1
.sp2:   dec     si                      ; stay on the NUL so a short line leaves
        xor     al, al                  ; the remaining fields empty, not garbage
        stosb
        ret
.sp3:   xor     al, al
        stosb
        ret

;------------------------------------------------------------------------------
; Navigation
;------------------------------------------------------------------------------
; CF=1 if not a playable game (section header type 1 or blank spacer type 2)
is_hdr:
        push    ax
        push    cx
        push    dx
        push    si
        mov     ax, bx
        mov     cx, ENT_SIZE
        mul     cx
        mov     si, entries
        add     si, ax
        cmp     byte [si], 0
        pop     si
        pop     dx
        pop     cx
        pop     ax
        je      .ih0
        stc
        ret
.ih0:   clc
        ret

; CF=1 if section header (type 1) — for yellow label / show_with_header
is_sect:
        push    ax
        push    cx
        push    dx
        push    si
        mov     ax, bx
        mov     cx, ENT_SIZE
        mul     cx
        mov     si, entries
        add     si, ax
        cmp     byte [si], 1
        pop     si
        pop     dx
        pop     cx
        pop     ax
        jne     .is0
        stc
        ret
.is0:   clc
        ret

first_game:
        xor     ax, ax
.fg:    cmp     ax, [n_ent]
        jae     .fgn
        mov     bx, ax
        call    is_hdr
        jnc     .fgo
        inc     ax
        jmp     .fg
.fgn:   xor     ax, ax
.fgo:   ret

next_game:
.ng:    inc     ax
        cmp     ax, [n_ent]
        jae     .ngn
        mov     bx, ax
        call    is_hdr
        jnc     .ngo
        jmp     .ng
.ngn:   mov     ax, 0FFFFh
.ngo:   ret

prev_game:
.pg:    cmp     ax, 0
        je      .pgf
        dec     ax
        mov     bx, ax
        call    is_hdr
        jnc     .pgo
        jmp     .pg
.pgf:   call    first_game
.pgo:   ret

last_game:
        mov     ax, [n_ent]
        or      ax, ax
        jz      .lgn
        dec     ax
.lg:    mov     bx, ax
        call    is_hdr
        jnc     .lgo
        or      ax, ax
        jz      .lgn
        dec     ax
        jmp     .lg
.lgn:   call    first_game
.lgo:   ret

jump_let:
        mov     dl, [jch]
        and     dl, 0DFh
        xor     ax, ax
.jl:    cmp     ax, [n_ent]
        jae     .jld
        mov     bx, ax
        call    is_hdr
        jc      .jln
        push    ax
        push    dx
        mov     ax, bx
        mov     cx, ENT_SIZE
        mul     cx
        mov     si, entries
        add     si, ax
        mov     al, [si+OFF_TITLE]
        and     al, 0DFh
        pop     dx
        cmp     al, dl
        pop     ax
        jne     .jln
        mov     [cur], bx
        call    show_with_header
        ret
.jln:   inc     ax
        jmp     .jl
.jld:   ret

; Include blank spacer + section header above current game when possible
show_with_header:
        mov     ax, [cur]
        or      ax, ax
        jz      .sw0
        call    find_sect_above         ; BX = header index or FFFF
        cmp     bx, 0FFFFh
        je      .sw1
        ; prefer blank spacer just above header
        or      bx, bx
        jz      .swh
        push    bx
        dec     bx
        call    entry_type              ; AL = type
        pop     bx
        cmp     al, 2
        jne     .swh
        dec     bx
.swh:   mov     [scr], bx
        call    scroll_fix
        ret
.sw1:   mov     ax, [cur]
        mov     [scr], ax
        call    scroll_fix
        ret
.sw0:   mov     word [scr], 0
        ret

; AX=cur -> BX=nearest section header index above, or FFFF
find_sect_above:
        push    ax
        mov     bx, ax
.fsa:   or      bx, bx
        jz      .fsn
        dec     bx
        call    is_sect
        jc      .fsy
        jmp     .fsa
.fsn:   mov     bx, 0FFFFh
.fsy:   pop     ax
        ret

; BX=index -> AL=type byte
entry_type:
        push    bx
        push    cx
        push    dx
        push    si
        mov     ax, bx
        mov     cx, ENT_SIZE
        mul     cx
        mov     si, entries
        add     si, ax
        mov     al, [si]
        pop     si
        pop     dx
        pop     cx
        pop     bx
        ret

scroll_fix:
        mov     ax, [cur]
        cmp     ax, [scr]
        jae     .sf1
        mov     [scr], ax
        call    find_sect_above
        cmp     bx, 0FFFFh
        je      .sf2
        or      bx, bx
        jz      .sfh
        push    bx
        dec     bx
        call    entry_type
        pop     bx
        cmp     al, 2
        jne     .sfh
        dec     bx
.sfh:   mov     [scr], bx
        ret
.sf1:   mov     bx, [scr]
        add     bx, VIEW_ROWS
        cmp     ax, bx
        jb      .sf2
        mov     bx, ax
        sub     bx, VIEW_ROWS
        inc     bx
        mov     [scr], bx
.sf2:   ret

;------------------------------------------------------------------------------
; DRAW
;------------------------------------------------------------------------------
draw:
        call    clr_scr

        ; row 0: title
        mov     dh, 0
        mov     dl, 2
        mov     bl, [attr_title]
        mov     si, s_title
        call    vputs

        ; row 1: commands (top) + red abort hint
        mov     dh, 1
        mov     dl, 2
        mov     bl, [attr_dim]
        mov     si, s_keys
        call    vputs
        ; Only advertise the abort chord when the TSR is actually resident —
        ; otherwise the hint is a lie and there is no way to tell from the UI.
        mov     dh, 1
        mov     dl, 38
        mov     bl, [attr_abort]
        mov     si, s_abort
        cmp     byte [abort_res], 0
        jne     .ab1
        mov     bl, [attr_dim]
        mov     si, s_noabort
.ab1:
        call    vputs

        ; list starts at row 3
        mov     ax, [scr]
        mov     [row_idx], ax
        xor     cx, cx
.drow:
        cmp     cx, VIEW_ROWS
        jae     .ddet
        mov     ax, [row_idx]
        cmp     ax, [n_ent]
        jae     .ddet

        push    cx

        mov     di, outbuf
        mov     ax, [row_idx]
        cmp     ax, [cur]
        jne     .mk
        mov     al, 16                  ; CP437 right triangle
        jmp     .mk2
.mk:    mov     al, ' '
.mk2:   stosb
        mov     al, ' '
        stosb

        mov     ax, [row_idx]
        push    cx
        mov     cx, ENT_SIZE
        mul     cx
        pop     cx
        mov     si, entries
        add     si, ax
        mov     [ent_ptr], si

        mov     al, [si]
        cmp     al, 2
        je      .dsp                    ; blank spacer between categories
        cmp     al, 1
        jne     .dg
        ; header: "* Section"
        mov     al, '*'
        stosb
        mov     al, ' '
        stosb
        add     si, OFF_TITLE
        call    cpy
        jmp     .dl
.dsp:   ; leave rest of line blank (spacer)
        jmp     .dl
.dg:    ; games indented under section headers
        mov     al, ' '
        stosb
        mov     al, ' '
        stosb
        add     si, OFF_TITLE
        call    cpy
.dl:
        mov     ax, di
        sub     ax, outbuf
        cmp     ax, LIST_WIDTH
        jae     .dpad
        mov     cx, LIST_WIDTH
        sub     cx, ax
        mov     al, ' '
        rep     stosb
.dpad:  xor     al, al
        stosb

        pop     cx
        mov     si, [ent_ptr]
        mov     al, [si]
        cmp     al, 1
        jne     .da
        mov     bl, [attr_hdr]
        jmp     .db
.da:    mov     bl, [attr_norm]
.db:    mov     ax, [row_idx]
        cmp     ax, [cur]
        jne     .dc
        cmp     byte [si], 0            ; only highlight real games
        jne     .dc
        mov     bl, [attr_sel]
.dc:
        mov     si, outbuf
        mov     dh, cl
        add     dh, 3
        mov     dl, 1
        call    vputs

        inc     word [row_idx]
        inc     cx
        jmp     .drow

.ddet:
        mov     dh, 18
        mov     dl, 1
        mov     bl, [attr_dim]
        mov     si, s_rule
        call    vputs

        ; detail: Title (year) / developer / note (description last)
        mov     bx, [cur]
        call    is_hdr
        jc      .dhdr

        call    fetch_rec               ; BX = cur; fills r_* from GAMES.LST

        mov     byte [det_row], 19

        ; Title (year)
        mov     di, outbuf
        mov     si, r_title
        call    cpy
        mov     al, ' '
        stosb
        mov     al, '('
        stosb
        mov     si, r_year
        call    cpy
        mov     al, ')'
        stosb
        xor     al, al
        stosb
        mov     si, outbuf
        mov     dh, [det_row]
        mov     dl, 2
        mov     bl, [attr_title]
        call    vputs
        inc     byte [det_row]

        ; developer / publisher
        mov     si, r_pub
        cmp     byte [si], 0
        je      .dnote
        mov     dh, [det_row]
        mov     dl, 2
        mov     bl, [attr_norm]
        call    vputs
        inc     byte [det_row]

.dnote:
        ; description / note below title and author
        mov     si, r_note
        cmp     byte [si], 0
        je      .df
        mov     dh, [det_row]
        mov     dl, 2
        mov     bl, [attr_dim]
        call    vputs
        jmp     .df

.dhdr:
        mov     dh, 19
        mov     dl, 2
        mov     bl, [attr_title]
        mov     si, s_hdr
        call    vputs

.df:
        call    hide_cursor
        ret

clr_scr:
        push    ax
        push    cx
        push    di
        push    es
        mov     es, [vseg]
        xor     di, di
        mov     cx, COLS*25
        mov     ah, [attr_norm]
        mov     al, ' '
        rep     stosw
        pop     es
        pop     di
        pop     cx
        pop     ax
        ret

dos_print:
        push    ax
        push    dx
        mov     dx, si
        mov     ah, 09h
        int     21h
        pop     dx
        pop     ax
        ret

; SI asciiz, DH=row DL=col BL=attr
vputs:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es
        mov     es, [vseg]
        push    bx
        mov     al, dh
        xor     ah, ah
        mov     cx, COLS
        mov     bl, dl
        xor     bh, bh
        mul     cx
        add     ax, bx
        shl     ax, 1
        mov     di, ax
        pop     bx
        mov     ah, bl
.vp:    lodsb
        cmp     al, 0
        je      .vpe
        mov     es:[di], al
        mov     es:[di+1], ah
        add     di, 2
        jmp     .vp
.vpe:   pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

cpy:
.c1:    lodsb
        cmp     al, 0
        je      .c2
        stosb
        jmp     .c1
.c2:    ret

;------------------------------------------------------------------------------
getkey:
        mov     ah, 00h
        int     16h
        cmp     al, 27
        je      .esc
        cmp     al, 13
        je      .ent
        cmp     al, 0
        je      .ex
        cmp     al, 'A'
        jb      .no
        cmp     al, 'Z'
        jbe     .L
        cmp     al, 'a'
        jb      .no
        cmp     al, 'z'
        ja      .no
.L:     mov     [jch], al
        mov     al, 9
        ret
.no:    xor     al, al
        ret
.ex:    cmp     ah, 48h
        je      .up
        cmp     ah, 50h
        je      .dn
        cmp     ah, 49h
        je      .pu
        cmp     ah, 51h
        je      .pd
        cmp     ah, 47h
        je      .hm
        cmp     ah, 4Fh
        je      .ed
        xor     al, al
        ret
.up:    mov     al, 1
        ret
.dn:    mov     al, 2
        ret
.ent:   mov     al, 3
        ret
; Maintenance exit (leaves the START.BAT loop) on either Shift+Esc or
; Ctrl+Alt+Esc.
;
; Shift+Esc is the one that works under DOSBox: desktop window managers grab
; Ctrl+Alt+Esc for themselves, so it never reaches DOS. Ctrl+Alt+Esc is kept
; because on real hardware there is no window manager to intercept it.
.esc:   push    ds
        mov     ax, 40h
        mov     ds, ax
        mov     al, [17h]             ; BIOS keyboard flags
        pop     ds
        test    al, 03h               ; either Shift
        jnz     .esc_quit
        test    al, 04h               ; Ctrl
        jz      .esc_norm
        test    al, 08h               ; Alt
        jz      .esc_norm
.esc_quit:
        mov     al, 10
        ret
.esc_norm:
        mov     al, 4
        ret
.pu:    mov     al, 5
        ret
.pd:    mov     al, 6
        ret
.hm:    mov     al, 7
        ret
.ed:    mov     al, 8
        ret

;------------------------------------------------------------------------------
; After EXEC returns (clean exit or ABORT): rebuild DS/ES, video, CWD, keyboard.
; Must NOT reset SP — caller return address is on the stack.
;------------------------------------------------------------------------------
reinit_after_game:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es

        sti
        mov     ax, cs
        mov     ds, ax
        mov     es, ax

        ; Freeze the TSR's counters the instant the child returns, so a later
        ; /T reading covers the game only and not the menu keys after it.
        mov     ax, 0AB04h
        int     2Fh

        ; Games often hook IRQs and never unhook if force-killed — restore ours
        call    restore_vectors

        ; The ABORT TSR may have adopted the game's INT 09h handler while it
        ; ran; that handler is gone now, so tell it to fall back to the
        ; original chain (INT 2Fh AB01h, ignored when the TSR is absent).
        mov     ax, 0AB01h
        int     2Fh

        call    shrink_mem

        mov     ah, 0Eh
        mov     dl, [sdrv]
        int     21h
        mov     ah, 3Bh
        mov     dx, scwd
        int     21h

        ; Reopen the index only once the launcher directory is current again,
        ; since lst_path may be relative.
        call    open_lst

        ; The entry table was handed to the child; rebuild it from the index.
        call    load_list
        jc      .relist_failed
        mov     ax, [n_ent]
        or      ax, ax
        jz      .relist_failed
        dec     ax
        cmp     [cur], ax               ; clamp in case the index shrank
        jbe     .relisted
        mov     [cur], ax
        mov     word [scr], 0
.relist_failed:
.relisted:

        call    kbd_recover
        call    silence_audio           ; stop SB/OPL/speaker left running after abort

        call    detect_video
        call    set_text_mode
        call    hide_cursor

        push    es
        mov     es, [vseg]
        xor     di, di
        mov     cx, COLS*25
        mov     ah, [attr_norm]
        mov     al, ' '
        rep     stosw
        pop     es

        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; Snapshot INT vectors (call once at startup, after ABORT is loaded)
save_vectors:
        push    ax
        push    bx
        push    es
        mov     ax, 3508h
        int     21h
        mov     [vec08], bx
        mov     [vec08+2], es
        mov     ax, 3509h
        int     21h
        mov     [vec09], bx
        mov     [vec09+2], es
        mov     ax, 3510h
        int     21h
        mov     [vec10], bx
        mov     [vec10+2], es
        mov     ax, 3516h
        int     21h
        mov     [vec16], bx
        mov     [vec16+2], es
        mov     ax, 351Ch
        int     21h
        mov     [vec1C], bx
        mov     [vec1C+2], es
        mov     ax, 3528h
        int     21h
        mov     [vec28], bx
        mov     [vec28+2], es
        pop     es
        pop     bx
        pop     ax
        ret

; Restore pre-game vectors (undo game hooks after normal exit or ABORT)
restore_vectors:
        push    ax
        push    dx
        push    ds
        mov     ax, cs
        mov     ds, ax

        lds     dx, [vec08]
        mov     ax, 2508h
        int     21h
        mov     ax, cs
        mov     ds, ax

        lds     dx, [vec09]
        mov     ax, 2509h
        int     21h
        mov     ax, cs
        mov     ds, ax

        lds     dx, [vec10]
        mov     ax, 2510h
        int     21h
        mov     ax, cs
        mov     ds, ax

        lds     dx, [vec16]
        mov     ax, 2516h
        int     21h
        mov     ax, cs
        mov     ds, ax

        lds     dx, [vec1C]
        mov     ax, 251Ch
        int     21h
        mov     ax, cs
        mov     ds, ax

        lds     dx, [vec28]
        mov     ax, 2528h
        int     21h
        mov     ax, cs
        mov     ds, ax

        pop     ds
        pop     dx
        pop     ax
        ret

; Clear stuck modifiers / drain BIOS key buffer (after ABORT or rude games)
kbd_recover:
        push    ax
        push    ds
        push    cx

        mov     al, 20h
        out     20h, al

        in      al, 61h
        mov     ah, al
        or      al, 80h
        out     61h, al
        mov     al, ah
        out     61h, al

        mov     ax, 40h
        mov     ds, ax
        and     byte [17h], 0F0h        ; clear shift/ctrl/alt
        mov     byte [18h], 0
        mov     ax, [1Ah]
        mov     [1Ch], ax               ; empty key buffer

        push    cs
        pop     ds

        mov     cx, 32
.kd:    mov     ah, 01h
        int     16h
        jz      .kdone
        mov     ah, 00h
        int     16h
        loop    .kd
.kdone:
        pop     cx
        pop     ds
        pop     ax
        ret

hide_cursor:
        push    ax
        push    cx
        mov     ah, 01h
        mov     cx, 2000h
        int     10h
        pop     cx
        pop     ax
        ret

;------------------------------------------------------------------------------
; Silence all common DOS audio after force-exit / return from game.
; Airlift = DIGPAK digital DMA + MIDPAK FM; DOSBox OPL is on 220h and 388h.
;------------------------------------------------------------------------------
silence_audio:
        push    ax
        push    bx
        push    cx
        push    dx

        ; 1) PC speaker off
        in      al, 61h
        and     al, 0FCh
        out     61h, al

        ; 2) Stop ISA DMA feeding the DAC (ch1=SB 8-bit, ch5=SB16 16-bit)
        mov     al, 05h                 ; set mask, channel 1
        out     0Ah, al
        mov     al, 05h                 ; set mask, channel 1 of 2nd 8237 (=DMA5)
        out     0D4h, al

        ; 3) Full SB quiet @ 220h (and 240h)
        mov     dx, 220h
        call    sb_kill
        mov     dx, 240h
        call    sb_kill

        ; 4) OPL/OPL3: both classic 388h and SB-mapped FM at 220h
        mov     dx, 388h                ; AdLib bank0 index
        mov     bx, 389h                ; data
        call    opl_wipe
        mov     dx, 38Ah                ; OPL3 bank1 index
        mov     bx, 38Bh
        call    opl_wipe
        mov     dx, 220h                ; SB FM bank0 (DOSBox dual map)
        mov     bx, 221h
        call    opl_wipe
        mov     dx, 222h                ; SB FM bank1
        mov     bx, 223h
        call    opl_wipe
        mov     dx, 228h                ; some SB Pro dual-OPL layout
        mov     bx, 229h
        call    opl_wipe

        ; 5) Unmask DMA again so next game can use the card
        mov     al, 01h                 ; clear mask, channel 1
        out     0Ah, al
        mov     al, 01h
        out     0D4h, al

        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; DX=index port, BX=data port — write 0 to regs 00h-FFh
opl_wipe:
        push    ax
        push    cx
        push    dx
        xor     cx, cx                  ; reg 0..255
.ow1:   push    dx
        mov     al, cl
        out     dx, al
        mov     ah, 8
.owd1:  in      al, dx
        dec     ah
        jnz     .owd1
        mov     dx, bx
        xor     al, al
        out     dx, al
        mov     ah, 40
.owd2:  in      al, dx
        dec     ah
        jnz     .owd2
        pop     dx
        inc     cl
        jnz     .ow1
        ; Explicit key-off B0-B8 (and bank already wiped)
        mov     cl, 0B0h
.owk:   mov     al, cl
        out     dx, al
        mov     ah, 8
.owd3:  in      al, dx
        dec     ah
        jnz     .owd3
        push    dx
        mov     dx, bx
        xor     al, al
        out     dx, al
        pop     dx
        inc     cl
        cmp     cl, 0B9h
        jb      .owk
        pop     dx
        pop     cx
        pop     ax
        ret

; DX = SB base. Halt DMA, mute mixer, reset DSP, speaker off.
sb_kill:
        push    ax
        push    cx
        push    dx

        ; --- mixer mute / reset (base+4 index, base+5 data) ---
        push    dx
        mov     ax, dx
        add     ax, 4
        mov     dx, ax                  ; mixer index
        ; reset mixer (reg 00 any write)
        xor     al, al
        out     dx, al
        inc     dx
        out     dx, al
        dec     dx
        ; master L/R = 0 (SB16: 30h/31h; also 22h Pro master)
        mov     al, 30h
        out     dx, al
        inc     dx
        xor     al, al
        out     dx, al
        dec     dx
        mov     al, 31h
        out     dx, al
        inc     dx
        xor     al, al
        out     dx, al
        dec     dx
        mov     al, 22h
        out     dx, al
        inc     dx
        xor     al, al
        out     dx, al
        dec     dx
        ; voice/PCM 32h/33h
        mov     al, 32h
        out     dx, al
        inc     dx
        xor     al, al
        out     dx, al
        dec     dx
        mov     al, 33h
        out     dx, al
        inc     dx
        xor     al, al
        out     dx, al
        dec     dx
        ; MIDI/FM 34h/35h
        mov     al, 34h
        out     dx, al
        inc     dx
        xor     al, al
        out     dx, al
        dec     dx
        mov     al, 35h
        out     dx, al
        inc     dx
        xor     al, al
        out     dx, al
        pop     dx

        ; --- DSP write port base+0Ch ---
        push    dx
        add     dx, 0Ch
        mov     al, 0D0h                ; halt 8-bit DMA
        call    sb_dsp_wr
        mov     al, 0D5h                ; halt 16-bit DMA
        call    sb_dsp_wr
        mov     al, 0DAh                ; exit 8-bit auto-init
        call    sb_dsp_wr
        mov     al, 0D9h                ; exit 16-bit auto-init
        call    sb_dsp_wr
        mov     al, 0D3h                ; speaker off
        call    sb_dsp_wr
        pop     dx

        ; --- DSP reset base+6 ---
        push    dx
        add     dx, 6
        mov     al, 1
        out     dx, al
        mov     cx, 2000
.sbr1:  in      al, dx
        loop    .sbr1
        xor     al, al
        out     dx, al
        mov     cx, 2000
.sbr2:  in      al, dx
        loop    .sbr2
        pop     dx

        ; drain data available
        push    dx
        add     dx, 0Eh
        mov     cx, 100
.sbrd:  in      al, dx
        loop    .sbrd
        pop     dx

        pop     dx
        pop     cx
        pop     ax
        ret

; AL=command, DX=DSP write port (base+0Ch). Timeout if no card.
sb_dsp_wr:
        push    ax
        push    cx
        mov     cx, 2000
.sw:    in      al, dx
        test    al, 80h
        jz      .sw0
        loop    .sw
        pop     cx
        pop     ax
        ret
.sw0:   pop     cx
        pop     ax
        out     dx, al
        ret

;------------------------------------------------------------------------------
; Shrink our MCB so child programs have free conventional memory.
;------------------------------------------------------------------------------
; Give the entry table back to the game. It is 11.5KB of the ~20KB we occupy
; and is untouched while a child runs; load_list rebuilds it afterwards.
; Memory-hungry games (Commander Keen reports "Out of memory! Try Unloading
; TSRs!") need every kilobyte of conventional RAM we can return.
shrink_for_exec:
        push    ax
        push    bx
        push    cx
        push    es
        mov     ax, cs
        mov     es, ax
        mov     bx, resident_min
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

shrink_mem:
        push    ax
        push    bx
        push    cx
        push    es
        mov     ax, cs
        mov     es, ax
        mov     bx, end_prog
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
; LAUNCH — CD to game dir, EXEC child. Preserve SP across EXEC for RET.
;------------------------------------------------------------------------------
launch:
        mov     ax, cs
        mov     ds, ax
        mov     es, ax

        call    shrink_mem

        mov     ah, 19h
        int     21h
        mov     [sdrv], al

        mov     ah, 47h
        xor     dl, dl
        mov     si, scwd
        int     21h

        ; AH=47h returns path without leading '\'. Convert to absolute
        ; so we can always restore the launcher directory reliably.
        mov     si, scwd
        cmp     byte [si], 0
        je      .cwd_root
        mov     di, si
.cwd_find_end:
        cmp     byte [di], 0
        je      .cwd_shift
        inc     di
        jmp     .cwd_find_end
.cwd_shift:
        mov     bx, di
.cwd_shift_loop:
        mov     al, [bx]
        mov     [bx+1], al
        cmp     bx, si
        je      .cwd_pref
        dec     bx
        jmp     .cwd_shift_loop
.cwd_pref:
        mov     byte [si], '\'
        jmp     .cwd_done
.cwd_root:
        mov     byte [si], '\'
        mov     byte [si+1], 0
.cwd_done:

        mov     bx, [cur]
        call    fetch_rec               ; r_dir / r_exe for this entry
        jc      .err_cd

        ; The index handle must not be inherited by the child.
        call    close_lst

        ; Hand the entry table back before the child loads.
        call    shrink_for_exec

        ; Zero the TSR's scancode counters so a later BROWSER.COM /T reading
        ; reflects only what happened while this game was running.
        mov     ax, 0AB03h
        int     2Fh

        mov     di, path                ; launcher-relative candidate
        mov     si, pfx
        call    cpy
        mov     si, r_dir
        call    cpy
        xor     al, al
        stosb

        ; Absolute candidate. With DGB.CFG the configured root is absolute from
        ; the drive root; without it games live under the launcher directory, so
        ; the launcher's own path has to be prefixed.
        mov     di, apath
        cmp     byte [cfg_found], 0
        jne     .ap_abs
        mov     si, scwd
        cmp     byte [si], 0
        je      .ap_abs
        cmp     byte [si+1], 0          ; scwd is just '\' — nothing to prefix
        je      .ap_abs
        call    cpy
.ap_abs:
        mov     si, pfx_abs
        call    cpy
        mov     si, r_dir
        call    cpy
        xor     al, al
        stosb

        ; With an explicit configured root the absolute form wins, so a
        ; same-named directory under the launcher cannot shadow it.
        cmp     byte [cfg_found], 0
        je      .cd_rel_first
        mov     ah, 3Bh
        mov     dx, apath
        int     21h
        jnc     .cd_ok
        mov     ah, 3Bh
        mov     dx, path
        int     21h
        jc      .err_cd
        jmp     .cd_ok
.cd_rel_first:
        mov     ah, 3Bh
        mov     dx, path
        int     21h
        jnc     .cd_ok
        mov     ah, 3Bh
        mov     dx, apath
        int     21h
        jc      .err_cd
.cd_ok:

        mov     si, r_exe
        mov     di, ename
        mov     cx, 13
.le:    lodsb
        stosb
        or      al, al
        jz      .le0
        loop    .le
        xor     al, al
        stosb
.le0:
        ; Absolute path to the executable, derived from where we actually
        ; landed, for the EXEC fallback and the error display.
        mov     ah, 47h
        xor     dl, dl
        mov     si, gcwd
        int     21h

        mov     di, afull
        mov     al, '\'
        stosb
        mov     si, gcwd
        call    cpy
        cmp     byte [di-1], '\'
        je      .af1
        mov     al, '\'
        stosb
.af1:
        mov     si, r_exe
        call    cpy
        xor     al, al
        stosb

        mov     di, fcb0
        mov     cx, 37
        xor     al, al
        rep     stosb
        mov     di, fcb1
        mov     cx, 37
        xor     al, al
        rep     stosb

        mov     byte [etail], 0
        mov     byte [etail+1], 13
        mov     word [epb], 0
        mov     word [epb+2], etail
        mov     word [epb+4], cs
        mov     word [epb+6], fcb0
        mov     word [epb+8], cs
        mov     word [epb+10], fcb1
        mov     word [epb+12], cs

        ; ES:BX = EPB, DS:DX = name. Keep this stack for DOS parent return.
        mov     ax, cs
        mov     ds, ax
        mov     es, ax

        mov     ax, 4B00h
        mov     dx, ename
        mov     bx, epb
        int     21h
        jnc     .ok_exec

        mov     ax, 4B00h
        mov     dx, afull
        mov     bx, epb
        int     21h
        jnc     .ok_exec

        mov     [exec_err], al
        jmp     .err_exec

.ok_exec:
        mov     ax, cs
        mov     ds, ax
        mov     es, ax
        ret

.err_exec:
        mov     ax, cs
        mov     ds, ax
        mov     es, ax
        call    set_text_mode
        mov     dh, 10
        mov     dl, 2
        mov     bl, [attr_err]
        mov     si, err_exec
        call    vputs
        mov     dh, 12
        mov     dl, 2
        mov     bl, [attr_dim]
        mov     si, ename
        call    vputs
        mov     di, outbuf
        mov     si, err_code
        call    cpy
        mov     al, [exec_err]
        call    hexbyte
        xor     al, al
        stosb
        mov     si, outbuf
        mov     dh, 13
        mov     dl, 2
        mov     bl, [attr_dim]
        call    vputs
        mov     dh, 14
        mov     dl, 2
        mov     bl, [attr_dim]
        mov     si, afull
        call    vputs
        mov     ah, 00h
        int     16h
        ret

.err_cd:
        mov     ax, cs
        mov     ds, ax
        mov     es, ax
        call    set_text_mode
        mov     dh, 12
        mov     dl, 2
        mov     bl, [attr_err]
        mov     si, err_cd
        call    vputs
        mov     dh, 13
        mov     dl, 2
        mov     bl, [attr_dim]
        mov     si, apath
        call    vputs
        mov     ah, 00h
        int     16h
        ret

; AL -> two hex digits at DI
hexbyte:
        push    ax
        mov     ah, al
        mov     cl, 4
        shr     al, cl
        call    .hx
        mov     al, ah
        and     al, 0Fh
        call    .hx
        pop     ax
        ret
.hx:    and     al, 0Fh
        add     al, '0'
        cmp     al, '9'
        jbe     .hx1
        add     al, 7
.hx1:   stosb
        ret

;------------------------------------------------------------------------------
; Self-test / diagnostic mode
;
;   BROWSER.COM /T
;
; Runs the real init_paths and load_list, then dumps resolved paths and the
; parsed index to stdout and exits. Because it drives the shipped code paths in
; the shipped binary, it is both the automated test hook (tools/test-browser.sh)
; and a way to diagnose path problems on target hardware:
;
;   C:\DGB> BROWSER.COM /T > TEST.TXT
;------------------------------------------------------------------------------

; Set [selftest_f] if the PSP command tail carries /T or -T.
check_selftest:
        push    ax
        push    cx
        push    si
        mov     byte [selftest_f], 0
        xor     cx, cx
        mov     cl, [80h]               ; PSP command tail length
        or      cl, cl
        jz      .cs_done
        mov     si, 81h
.cs1:   mov     al, [si]
        cmp     al, '/'
        je      .cs_sw
        cmp     al, '-'
        jne     .cs_next
.cs_sw: cmp     cx, 1
        jbe     .cs_done
        mov     al, [si+1]
        or      al, 20h
        cmp     al, 't'
        je      .cs_t
        cmp     al, 'x'
        jne     .cs_next
        mov     byte [selftest_f], 2    ; /X = launch the first game, then report
        jmp     .cs_done
.cs_t:
        mov     byte [selftest_f], 1
        jmp     .cs_done
.cs_next:
        inc     si
        dec     cx
        jnz     .cs1
.cs_done:
        pop     si
        pop     cx
        pop     ax
        ret

; SI = asciiz string -> stdout
sout:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        mov     dx, si
        xor     cx, cx
.so1:   cmp     byte [si], 0
        je      .so2
        inc     si
        inc     cx
        jmp     .so1
.so2:   or      cx, cx
        jz      .so3
        mov     ah, 40h
        mov     bx, 1
        int     21h
.so3:   pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

soutnl:
        push    si
        mov     si, s_crlf
        call    sout
        pop     si
        ret

; AX = unsigned value -> decimal digits at DI (DI advanced, no terminator)
putdec:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
.pd1:   xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jnz     .pd1
.pd2:   pop     ax
        add     al, '0'
        stosb
        dec     cx
        jnz     .pd2
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

selftest:
        mov     si, st_hdr
        call    sout
        call    soutnl

        call    detect_abort
        call    init_paths

        mov     si, st_abort
        call    sout
        mov     al, [abort_res]
        add     al, '0'
        mov     [st_ch], al
        mov     si, st_ch
        call    sout
        call    soutnl

        ; What has the TSR's keyboard handler actually seen? Zero scancodes
        ; after playing a game means it is not being called at all.
        cmp     byte [abort_res], 0
        je      .no_kbd
        mov     ax, 0AB02h
        int     2Fh                     ; BX=count CL=last CH=flags DX=grabs
        push    di                      ; SI=armed|pending<<8  DI=indos blocks
        push    si
        push    dx
        push    cx
        mov     di, outbuf
        mov     si, st_kbd
        call    cpy
        mov     ax, bx
        call    putdec
        mov     si, st_kbdlast
        call    cpy
        pop     cx
        push    cx
        mov     al, cl
        call    hexbyte
        mov     si, st_kbdflags
        call    cpy
        pop     cx
        mov     al, ch
        call    hexbyte
        mov     si, st_kbdgrab
        call    cpy
        pop     ax
        call    putdec
        mov     si, st_kbdarm
        call    cpy
        pop     ax
        push    ax
        xor     ah, ah
        call    putdec
        pop     ax
        mov     si, st_kbdpend
        call    cpy
        mov     al, ah
        xor     ah, ah
        call    putdec
        mov     si, st_kbdblk
        call    cpy
        pop     ax
        call    putdec
        xor     al, al
        stosb
        mov     si, outbuf
        call    sout
        call    soutnl
.no_kbd:

        mov     si, st_cfg
        call    sout
        mov     al, [cfg_found]
        add     al, '0'
        mov     [st_ch], al
        mov     si, st_ch
        call    sout
        call    soutnl

        mov     si, st_pfx
        call    sout
        mov     si, pfx
        call    sout
        call    soutnl

        mov     si, st_pfxa
        call    sout
        mov     si, pfx_abs
        call    sout
        call    soutnl

        call    load_list
        jnc     .sl_ok
        mov     si, st_lstfail
        call    sout
        call    soutnl
        ret

.sl_ok:
        mov     si, st_nent
        call    sout
        mov     di, outbuf
        mov     ax, [n_ent]
        call    putdec
        xor     al, al
        stosb
        mov     si, outbuf
        call    sout
        call    soutnl

        xor     bx, bx
.se1:   cmp     bx, [n_ent]
        jae     .se_done
        mov     di, outbuf
        mov     al, 'E'
        stosb
        mov     ax, bx
        call    putdec
        mov     al, ' '
        stosb
        mov     al, 'T'
        stosb
        push    bx
        mov     ax, bx
        mov     cx, ENT_SIZE
        mul     cx
        mov     si, entries
        add     si, ax
        push    si
        mov     al, [si]
        add     al, '0'
        stosb
        mov     al, ' '
        stosb
        mov     al, 'O'
        stosb
        pop     si
        push    si
        mov     ax, [si+OFF_OFS]
        call    putdec
        mov     al, ' '
        stosb
        pop     si
        add     si, OFF_TITLE
        call    cpy
        pop     bx
        xor     al, al
        stosb
        mov     si, outbuf
        call    sout
        call    soutnl
        inc     bx
        jmp     .se1
.se_done:
        ; Prove the on-demand path: re-read each game record from disk.
        xor     bx, bx
.sr1:   cmp     bx, [n_ent]
        jae     .sr_done
        push    bx
        call    fetch_rec
        pop     bx
        jc      .sr_next
        mov     di, outbuf
        mov     al, 'R'
        stosb
        mov     ax, bx
        call    putdec
        mov     si, st_fdir
        call    cpy
        mov     si, r_dir
        call    cpy
        mov     si, st_fexe
        call    cpy
        mov     si, r_exe
        call    cpy
        mov     si, st_fyear
        call    cpy
        mov     si, r_year
        call    cpy
        mov     si, st_fpub
        call    cpy
        mov     si, r_pub
        call    cpy
        mov     si, st_fnote
        call    cpy
        mov     si, r_note
        call    cpy
        xor     al, al
        stosb
        mov     si, outbuf
        call    sout
        call    soutnl
.sr_next:
        inc     bx
        jmp     .sr1
.sr_done:
        ret

;------------------------------------------------------------------------------
; /X — drive the real launch path for the first game and report afterwards.
; Covers directory resolution, EXEC, and reopening the index once the child has
; returned (the R line below only prints if the handle came back).
;------------------------------------------------------------------------------
selftest_exec:
        call    detect_video
        call    init_paths
        call    load_list
        jnc     .sx_ok
        mov     si, st_lstfail
        call    sout
        call    soutnl
        ret
.sx_ok:
        cmp     word [n_ent], 0
        je      .sx_none

        call    save_vectors
        call    first_game
        mov     [cur], ax
        mov     bx, ax
        call    is_hdr
        jc      .sx_none

        call    launch
        call    reinit_after_game
        call    set_text_mode

        mov     si, st_xdone
        call    sout
        call    soutnl

        ; Re-read the record after the child returned. This only succeeds if
        ; the index handle was reopened.
        mov     bx, [cur]
        call    fetch_rec
        jc      .sx_noreopen
        mov     di, outbuf
        mov     si, st_xrec
        call    cpy
        mov     si, r_dir
        call    cpy
        mov     si, st_fexe
        call    cpy
        mov     si, r_exe
        call    cpy
        xor     al, al
        stosb
        mov     si, outbuf
        call    sout
        call    soutnl
        ret

.sx_noreopen:
        mov     si, st_xnoreopen
        call    sout
        call    soutnl
        ret

.sx_none:
        mov     si, st_xnone
        call    sout
        call    soutnl
        ret

;------------------------------------------------------------------------------
; Data
;------------------------------------------------------------------------------
        align   2
stack_bytes     times 1024 dw 0         ; 2KB stack (EXEC is stack-heavy)
stack_top:

fname           db 'GAMES.LST',0
fname2          db 'C:\GAMES.LST',0
cfg_name        db 'DGB.CFG',0
games_key       db 'GAMES_ROOT=',0
pfx_def         db 'GAMES\',0
pfx_abs_def     db '\GAMES\',0
pfx             times 64 db 0
pfx_abs         times 96 db 0
root_slash      db '\',0
cfg_found       db 0
abort_res       db 0                    ; ABORT.COM TSR present
selftest_f      db 0
fh              dw 0FFFFh
lst_path        dw 0                    ; which of fname/fname2 resolved
cur_ofs         dw 0                    ; parse cursor into GAMES.LST
line_ofs        dw 0                    ; offset of the line being parsed
line_len        dw 0                    ; bytes consumed by that line
n_ent           dw 0
cur             dw 0
scr             dw 0
jch             db 0
sdrv            db 0
exec_err        db 0
vseg            dw 0B800h
attr_norm       db 1Fh
attr_title      db 1Eh
attr_dim        db 17h
attr_hdr        db 1Eh
attr_sel        db 70h
attr_abort      db 1Ch
attr_err        db 4Fh
row_idx         dw 0
ent_ptr         dw 0
det_row         db 0
save_ss         dw 0
save_sp         dw 0
vec08           dd 0
vec09           dd 0
vec10           dd 0
vec16           dd 0
vec1C           dd 0
vec28           dd 0
scwd            times 64 db 0
gcwd            times 68 db 0           ; CWD after CHDIR into the game folder
path            times 96 db 0
apath           times 128 db 0
afull           times 160 db 0
ename           times 14 db 0
etail           db 0, 13
outbuf          times 90 db 0
fcb0            times 37 db 0
fcb1            times 37 db 0
epb             times 14 db 0
linebuf         times MAXLINE+2 db 0
cfg_buf         times 256 db 0
root_val        times 64 db 0

; Scratch for the one record fetch_rec has re-read from GAMES.LST.
r_dir           times DLEN+1 db 0
r_exe           times ELEN+1 db 0
r_title         times TLEN+1 db 0
r_year          times YLEN+1 db 0
r_genre         times GLEN+1 db 0
r_pub           times PLEN+1 db 0
r_note          times NLEN+1 db 0

s_title         db 'DOS Game Browser',0
s_keys          db 'Arrows move  Enter=Play',0   ; Shift+Esc is deliberately not shown
s_abort         db 'F12 or CTRL+ALT+BKSP exits game',0
s_noabort       db 'ABORT.COM not loaded - no force exit',0
s_rule          db '------------------------------------------------------------------------------',0
s_hdr           db '(category header)',0
msg_noload      db 'ERROR: GAMES.LST not found in current directory.',13,10,'$'
msg_empty       db 'ERROR: GAMES.LST contains no games.',13,10,'$'
err_cd          db 'ERROR: cannot open game folder:',0
err_exec        db 'ERROR: cannot run game:',0
err_code        db 'DOS error code: ',0

s_crlf          db 13,10,0
st_hdr          db 'DGB SELFTEST',0
st_cfg          db 'CFG=',0
st_pfx          db 'PFX=',0
st_pfxa         db 'PFXABS=',0
st_nent         db 'NENT=',0
st_lstfail      db 'LST=FAIL',0
st_abort        db 'ABORT=',0
st_kbd          db 'KBD scancodes=',0
st_kbdlast      db ' last=',0
st_kbdflags     db ' ctrlalt=',0
st_kbdgrab      db ' grabs=',0
st_kbdarm       db ' armed=',0
st_kbdpend      db ' pend=',0
st_kbdblk       db ' busydos=',0
st_fdir         db ' DIR=',0
st_fexe         db ' EXE=',0
st_fyear        db ' YEAR=',0
st_fpub         db ' PUB=',0
st_fnote        db ' NOTE=',0
st_xdone        db 'XDONE',0
st_xrec         db 'XREC DIR=',0
st_xnoreopen    db 'XREOPEN=FAIL',0
st_xnone        db 'XNONE',0
st_ch           db 0,0

; Everything below here is idle while a child runs and is handed back to it.
; Keep the entry table last so the block can simply be truncated.
resident_min:
entries         times MAX_ENT*ENT_SIZE db 0

        align   16
end_prog:
