; BROWSER.COM — split into browser_p1..p4 for MCP upload; assembles identically to monolithic source
; Build: nasm -f bin -o booth/BROWSER.COM src/browser.asm
; (nasm resolves %include relative to the including file)
%include "browser_p1.asm"
%include "browser_p2.asm"
%include "browser_p3.asm"
%include "browser_p4.asm"
