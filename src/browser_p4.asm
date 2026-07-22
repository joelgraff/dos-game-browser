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
        mov     al, '\\'
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
