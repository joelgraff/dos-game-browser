@ECHO OFF
REM DOS Game Browser kiosk entrypoint (real hardware / CF media)
REM Run from the booth root (C:\ or wherever this tree is installed).
CD \
IF EXIST UTILS\ABORT.COM UTILS\ABORT.COM
:LOOP
BROWSER.COM
GOTO LOOP
