@ECHO OFF
REM DOS Game Browser - kiosk entrypoint
REM Run from the launcher directory, for example C:\DGB\
REM
REM ABORT.COM is a small TSR. With it loaded, F12 (or Ctrl+Alt+Backspace)
REM force-exits a game that has stopped responding. Add /W after ABORT.COM
REM only if a game takes the keyboard interrupt away; see docs/DIAGNOSTICS.md
IF EXIST UTILS\ABORT.COM UTILS\ABORT.COM
:LOOP
BROWSER.COM
IF ERRORLEVEL 42 GOTO DONE
IF ERRORLEVEL 1 GOTO FAIL
REM Esc returns here and the browser restarts, so the machine stays on the
REM menu. Shift+Esc exits with 42 and falls through to DONE.
GOTO LOOP
:FAIL
ECHO.
ECHO Browser exited with an error. Check that GAMES.LST exists and that
ECHO the game paths in it are correct.  Run SCAN to rebuild it.
:DONE
