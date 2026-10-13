# Alty helper: Windows installers

The Alty helper is a small Windows program for businesses that use Alty. It runs in the background on a
computer at the business and connects that computer to Alty, so that Alty can work with devices there, such
as a receipt printer or a fiscal register. This repository holds its installers and an automatic test of
them; the helper's source code is not here.

## Download

- The latest installer, always at the same link:
  https://github.com/gevkhanyan/alty-helper-releases/releases/latest/download/AltyHelperSetup.exe
- Each release, under [Releases](https://github.com/gevkhanyan/alty-helper-releases/releases), has
  `AltyHelperSetup.exe`, the same file under its version's name (for example `AltyHelperSetup-0.1.0.exe`),
  and `SHA256SUMS.txt`.

## Check the file before you run it

`SHA256SUMS.txt` lists the SHA-256 fingerprint of each installer. Compute the fingerprint of the file you
downloaded and compare the two.

In PowerShell:

```powershell
Get-FileHash .\AltyHelperSetup.exe -Algorithm SHA256
```

In Command Prompt:

```bat
certutil -hashfile AltyHelperSetup.exe SHA256
```

They must be the same, character for character (capital or small letters do not matter). If they differ,
do not run the file.

## Not code-signed yet

The installer and the program are not signed with a code-signing certificate yet. When you run a downloaded
installer, Windows may show "Windows protected your PC". Check the SHA-256 as above, then choose
"More info" and "Run anyway". Once Alty has a certificate, the files will be signed and this warning will
go away.

## What it installs

For the signed-in Windows user only, without administrator rights:

- the program, in `%LOCALAPPDATA%\Programs\Alty Helper`;
- its data (its pairing and its log), in `%LOCALAPPDATA%\Alty Helper`;
- a Start menu shortcut, "Alty Helper", which opens the helper's own page at `http://127.0.0.1:47100`;
- an entry that starts it whenever this user signs in to Windows.

After the install, type the code that Alty's Office shows into the helper's page. To remove the helper,
open Settings, then Apps, then Alty Helper, and choose Uninstall: this removes the program and its data.

## The automatic test on Windows

[`.github/workflows/windows-smoke.yml`](.github/workflows/windows-smoke.yml) runs
[`smoke.ps1`](smoke.ps1) on clean Windows Server 2022 and Windows Server 2025 computers that GitHub lends
for the test and then throws away. It runs when a release is published, and on request: Actions, then
"Windows smoke test", then "Run workflow", with a release tag or `latest`. A release published before
the test existed has to be tested on request.

It downloads the release's installer from the public links above, without any password or token, and
checks its SHA-256 against `SHA256SUMS.txt`. Then it checks that:

1. The silent install puts the program in the user's own folder and adds the start-at-sign-in entry and
   the Start menu shortcut. It asks for no administrator rights (its manifest says `asInvoker`) and writes
   nothing for the whole computer (no machine-wide registry entry, nothing in Program Files).
2. The helper starts: one background process and the worker it looks after. Its page answers at
   `http://127.0.0.1:47100` and says it is not paired yet.
3. It reaches Alty's server over HTTPS. The page sends a deliberately wrong code, `OOOO-0000`, which
   Alty can never give out (its codes never use the letter O or the digit 0), and the server answers
   that the code is invalid. Nothing is paired and nothing changes on the server.
4. When its worker is ended, as Task Manager would end it, the helper starts it again within seconds.
5. Started twice more, as from the Start menu, it still runs only once.
6. Installing again over the running helper stops it first, brings it back, and keeps its data.
7. Its log has the start details, no code or secret, and no warning or error but the two the test causes
   on purpose (the wrong code and the ended worker).
8. Uninstalling removes everything: the program, its data, the start entry and the shortcut.

The run also runs [`pcinfo.ps1`](pcinfo.ps1) in Windows PowerShell, as a person at a business pastes it:
a read-only list of the computer's facts (Windows, security, network, printers, devices) written to one
text file on the Desktop, for Alty's support. It changes nothing and sends nothing.

Each check prints PASS or FAIL with what it saw. The run's summary shows the results as a table, and the
run keeps the evidence for 30 days: the helper's log, its status answers, the list of its processes and
the full report.

It cannot check:

- how the installer's pages look on screen;
- the warning Windows shows for an unsigned file downloaded with a browser;
- an install and a run by a Windows user without administrator rights (the test computer's user is an
  administrator);
- the first start from the installer's last page (its "open" box), or a double-click on the Start menu
  shortcut itself (the test runs the shortcut's command);
- pairing with a real code;
- the start at a real sign-in.
