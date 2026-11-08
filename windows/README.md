# Windows portable controller and account shortcuts

Place the `.ps1` and `.cmd` files beside `wrapper-manager-qemu.exe`. The Windows
launcher artifact includes these scripts. Add the manager guest assets and a
Windows x86_64 QEMU distribution in this layout:

```text
wrapper-manager-qemu.exe
backend.ps1
account-login.ps1
Start Wrapper.cmd
Stop Wrapper.cmd
Wrapper Status.cmd
Switch JP Account.cmd
Switch Secondary Account.cmd
guest/
  vmlinuz-lite-qemu
  wrapper-manager-initramfs.cpio.gz
  qemu/bin/                   # QEMU and its matching DLLs/firmware
data/data.img                # existing image or created on first launch
```

The controller exposes the shared HTTP endpoint at `127.0.0.1:12340` and keeps
its disk, process record and logs in this portable directory. Configure GUI or
CLI clients to use that endpoint. It does not install or stop WSL distributions.

`Start Wrapper.cmd` starts the backend and waits for account restoration.
Closing a client does not stop this separately managed backend. Finish or cancel
downloads before running `Stop Wrapper.cmd`. Only this controller's verified
launcher process and its descendants are stopped; account data stays on disk.

The controller prefers WHPX. An exited hardware launch or 20 seconds without an
HTTP response triggers a TCG fallback. Waiting for a responding manager to restore
accounts does not trigger fallback. Progress is printed approximately every five
seconds. Use `backend.ps1 -Action Start -Acceleration tcg` to request TCG directly.

The native launcher opens its own log files when `WRAPPER_MANAGER_LOG_PREFIX` is
set, and QEMU does not inherit terminal input. This avoids retaining PowerShell
redirection pipes or depending on the startup console after the controller exits.

## Account selection

Run `Switch JP Account.cmd` or `Switch Secondary Account.cmd` to configure two
independent local profiles. Each first use prompts for the account and password;
Apple may also require a verification code. Credentials are saved only after a
successful login, using Windows DPAPI through `Export-Clixml`. The `accounts/`
directory is restricted to the current user, SYSTEM and administrators. The
encrypted passwords belong to this Windows user/machine and are not portable
credentials. Do not commit the account files or the data image.

Later runs select an existing session without submitting its password. Switching
does not log out other accounts. Requests only use the selected account; an
unavailable selected account does not silently fall back to a different account.
Selection persists across backend restarts. `Wrapper Status.cmd` shows the local
profile label and region. To replace one profile's stored credentials, run its
`.cmd` shortcut with `-Reenter`.

Switch after downloads have finished. Clients may cache region displays or catalog
results; reopen a client if its region display needs refreshing.

## Source build

Build the Windows launcher into this directory with Go:

```powershell
go build -o windows/wrapper-manager-qemu.exe ./cmd/wrapper-manager-qemu
```

Build the guest on Linux with `guest/build.sh`. It now pairs the kernel and modules
from a single upstream QEMU artifact. Copy the emitted kernel and initramfs into
`windows/guest/`, add QEMU under `windows/guest/qemu/bin/`, then run the shortcuts.

Run the synthetic login/selection and DPAPI checks without a real account:

```powershell
powershell.exe -NoProfile -File windows/tests/test-account-login.ps1
```
