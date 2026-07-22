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

