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

MAX_ENT         equ     64
FILE_MAX        equ     8192
TLEN            equ     32
YLEN            equ     4
GLEN            equ     12
PLEN            equ     16
NLEN            equ     32
DLEN            equ     32
ELEN            equ     12

; type:1 title:33 year:5 genre:13 pub:17 note:33 dir:33 exe:13 = 148
ENT_SIZE        equ     148
OFF_TYPE        equ     0
OFF_TITLE       equ     1
OFF_YEAR        equ     34
OFF_GENRE       equ     39
OFF_PUB         equ     52
OFF_NOTE        equ     69
OFF_DIR         equ     102
OFF_EXE         equ     135

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

        call    shrink_mem

        call    detect_video
        call    set_text_mode

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
; LOAD GAMES.LST — bulk read then parse
;------------------------------------------------------------------------------
load_list:
        mov     ax, 3D00h
        mov     dx, fname
        int     21h
        jnc     .ok
        mov     ax, 3D00h
        mov     dx, fname2
        int     21h
        jnc     .ok
        stc
        ret
.ok:    mov     [fh], ax
        mov     ah, 3Fh
        mov     bx, [fh]
        mov     cx, FILE_MAX
        mov     dx, filebuf
        int     21h
        jc      .fail_rd
        mov     [file_len], ax
        mov     ah, 3Eh
        mov     bx, [fh]
        int     21h
        mov     bx, [file_len]
        mov     si, filebuf
        add     si, bx
        mov     byte [si], 0
        mov     word [n_ent], 0
        mov     si, filebuf
.loop:
        call    next_line
        jc      .done
        mov     di, [lineptr]
        cmp     byte [di], 0
        je      .loop
        cmp     byte [di], '#'
        je      .loop
        mov     al, [di]
        or      al, 20h
        cmp     al, 'h'
        je      .H
        cmp     al, 'g'
        je      .G
        jmp     .loop
.H:     cmp     byte [di+1], '|'
        jne     .loop
        ; DI = line "H|Section" — must preserve across spacer insert
        push    si                      ; file scan position
        push    di                      ; line pointer
        ; blank spacer between previous category and this header
        mov     ax, [n_ent]
        or      ax, ax
        jz      .Hadd
        cmp     ax, MAX_ENT
        jae     .Hfail
        call    ent_addr_ax
        mov     byte [di], 2            ; type 2 = blank spacer
        inc     word [n_ent]
.Hadd:  mov     ax, [n_ent]
        cmp     ax, MAX_ENT
        jae     .Hfail
        pop     si                      ; SI = "H|Section"
        call    ent_addr_ax
        mov     byte [di], 1
        add     si, 2
        push    di
        add     di, OFF_TITLE
        mov     cx, TLEN
        call    store_str
        pop     di
        inc     word [n_ent]
        pop     si                      ; restore file scan
        jmp     .loop
.Hfail: pop     di
        pop     si
        jmp     .done
.G:     cmp     byte [di+1], '|'
        jne     .loop
        mov     ax, [n_ent]
        cmp     ax, MAX_ENT
        jae     .done
        push    si
        mov     si, di
        call    ent_addr_ax
        mov     byte [di], 0
        push    di
        add     si, 2
        mov     bx, di
        add     bx, OFF_DIR
        mov     di, bx
        mov     cx, DLEN
        call    store_pipe
        pop     bx
        push    bx
        mov     di, bx
        add     di, OFF_EXE
        mov     cx, ELEN
        call    store_pipe
        pop     bx
        push    bx
        mov     di, bx
        add     di, OFF_TITLE
        mov     cx, TLEN
        call    store_pipe
        pop     bx
        push    bx
        mov     di, bx
        add     di, OFF_YEAR
        mov     cx, YLEN
        call    store_pipe
        pop     bx
        push    bx
        mov     di, bx
        add     di, OFF_GENRE
        mov     cx, GLEN
        call    store_pipe
        pop     bx
        push    bx
        mov     di, bx
        add     di, OFF_PUB
        mov     cx, PLEN
        call    store_pipe
        pop     bx
        mov     di, bx
        add     di, OFF_NOTE
        mov     cx, NLEN
        call    store_str
        inc     word [n_ent]
        pop     si
        jmp     .loop
.done:
        clc
        ret
.fail_rd:
        mov     ah, 3Eh
        mov     bx, [fh]
        int     21h
        stc
        ret

next_line:
        mov     [lineptr], si
        cmp     byte [si], 0
        jne     .nl1
        stc
        ret
.nl1:   mov     al, [si]
        cmp     al, 0
        je      .nl_eof
        cmp     al, 13
        je      .nl_cr
        cmp     al, 10
        je      .nl_lf
        inc     si
        jmp     .nl1
.nl_cr: mov     byte [si], 0
        inc     si
        cmp     byte [si], 10
        jne     .nl_ok
        inc     si
        jmp     .nl_ok
.nl_lf: mov     byte [si], 0
        inc     si
.nl_ok: clc
        ret
.nl_eof:
        cmp     si, [lineptr]
        je      .nl_empty
        clc
        ret
.nl_empty:
        stc
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
.sp2:   xor     al, al
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
        mov     dh, 1
        mov     dl, 38
        mov     bl, [attr_abort]
        mov     si, s_abort
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

        mov     ax, bx
        mov     cx, ENT_SIZE
        mul     cx
        mov     si, entries
        add     si, ax
        mov     [ent_ptr], si

        mov     byte [det_row], 19

        ; Title (year)
        mov     di, outbuf
        mov     si, [ent_ptr]
        add     si, OFF_TITLE
        call    cpy
        mov     al, ' '
        stosb
        mov     al, '('
        stosb
        mov     si, [ent_ptr]
        add     si, OFF_YEAR
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
        mov     si, [ent_ptr]
        add     si, OFF_PUB
        cmp     byte [si], 0
        je      .dnote
        mov     dh, [det_row]
        mov     dl, 2
        mov     bl, [attr_norm]
        call    vputs
        inc     byte [det_row]

.dnote:
        ; description / note below title and author
        mov     si, [ent_ptr]
        add     si, OFF_NOTE
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
.esc:   mov     al, 4
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

        ; Games often hook IRQs and never unhook if force-killed — restore ours
        call    restore_vectors

        call    shrink_mem

        mov     ah, 0Eh
        mov     dl, [sdrv]
        int     21h
        mov     ah, 3Bh
        mov     dx, root_slash
        int     21h

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

        mov     ax, [cur]
        mov     cx, ENT_SIZE
        mul     cx
        mov     si, entries
        add     si, ax
        mov     [ent_ptr], si

        mov     di, path
        mov     si, pfx
        call    cpy
        mov     si, [ent_ptr]
        add     si, OFF_DIR
        call    cpy
        xor     al, al
        stosb

        mov     ah, 3Bh
        mov     dx, path
        int     21h
        jc      .err_cd

        mov     si, [ent_ptr]
        add     si, OFF_EXE
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
        mov     di, fullpath
        mov     si, pfx
        call    cpy
        mov     si, [ent_ptr]
        add     si, OFF_DIR
        call    cpy
        mov     al, '\'
        stosb
        mov     si, [ent_ptr]
        add     si, OFF_EXE
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

        mov     ax, cs
        mov     ds, ax
        mov     es, ax
        mov     ah, 3Bh
        mov     dx, root_slash
        int     21h
        mov     ah, 3Bh
        mov     dx, path
        int     21h

        mov     ax, 4B00h
        mov     dx, ename
        mov     bx, epb
        int     21h
        jnc     .ok_exec

        mov     ah, 3Bh
        mov     dx, root_slash
        int     21h
        mov     ax, 4B00h
        mov     dx, fullpath
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
        mov     si, fullpath
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
        mov     si, path
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
; Data
;------------------------------------------------------------------------------
        align   2
stack_bytes     times 1024 dw 0         ; 2KB stack (EXEC is stack-heavy)
stack_top:

fname           db 'GAMES.LST',0
fname2          db 'C:\GAMES.LST',0
pfx             db 'GAMES\',0
root_slash      db '\',0
fh              dw 0
file_len        dw 0
lineptr         dw 0
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
path            times 80 db 0
fullpath        times 96 db 0
ename           times 14 db 0
etail           db 0, 13
outbuf          times 90 db 0
fcb0            times 37 db 0
fcb1            times 37 db 0
epb             times 14 db 0
filebuf         times FILE_MAX+2 db 0

s_title         db 'DOS Game Browser',0
s_keys          db 'Arrows move  Enter=Play',0
s_abort         db 'CTRL+ALT+BACKSPACE exits game',0
s_rule          db '------------------------------------------------------------------------------',0
s_hdr           db '(category header)',0
msg_noload      db 'ERROR: GAMES.LST not found in current directory.',13,10,'$'
msg_empty       db 'ERROR: GAMES.LST contains no games.',13,10,'$'
err_cd          db 'ERROR: cannot open game folder:',0
err_exec        db 'ERROR: cannot run game:',0
err_code        db 'DOS error code: ',0

entries         times MAX_ENT*ENT_SIZE db 0

        align   16
end_prog:
