MoneyTracker — personal desktop app

Windows: extract the entire ZIP, then run money_tracker.exe. Keep its data and
DLL folders beside it. If Windows reports a missing VCRUNTIME/MSVCP DLL, install
Microsoft's current Visual C++ x64 Redistributable:
https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist

Linux: extract the entire archive and run ./money_tracker. The CI build targets
Ubuntu 22.04 or newer. You need GTK 3, libsecret and an unlocked Secret Service
keyring (GNOME Keyring or KDE Wallet). Distribution packages:
  Debian/Ubuntu: libgtk-3-0 libsecret-1-0 gnome-keyring
  Arch/Manjaro: gtk3 libsecret; GNOME Keyring or KDE Wallet
Other architectures and older Linux distributions require a local build.
The local Arch build is for this machine; prefer the CI archive for Ubuntu.

First launch opens setup. Every person creates their own Enable Banking account,
production application and key, then links their own accounts in its control
panel. Follow the on-screen instructions. Never share your PEM/private data.
The app has no shared API key and never downloads transactions automatically.

Moving from the old Python version: close the old service and choose its
.private folder on the setup screen. The app copies and verifies the data,
including undo history and import audits; the old installation stays unchanged.

Bank authorization uses https://localhost:8443/callback. A browser may warn about
its locally generated certificate. You can instead copy the final localhost URL
into the authorization dialog. Keep MoneyTracker open while authorizing.

Your private data is outside this application bundle, in the current user's
application-support directory. Keys and sessions are encrypted with a key in
the system credential store. Keep your original Enable Banking PEM as a backup.
Saved payments still work when bank consent expires; renew it from Preferences.
