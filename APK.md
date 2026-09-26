# Getting the APK onto an Android phone

Plain directions, in order. Commands are written for **PowerShell**
(the blue terminal) — paste one line at a time, exactly as written.

---

## THE ONE RULE

> **Always BUILD before you INSTALL.**
> A plain install with no fresh build **uninstalls the app first, then
> fails** — you lose the app *and* its saved settings.

Debug is the working shape. The release build compiles but MapLibre
crashes under R8 (the map never attaches), so **do not use release
until that fix ships.**

---

## WHAT YOU NEED ONCE

- The Flutter SDK: `C:\Users\Brett\flutter`
- The Android platform tools: `C:\Users\Brett\AppData\Local\Android\Sdk\platform-tools`
- Your phone switched on, **USB debugging** turned on
  (Settings → Developer options → USB debugging), and plugged in
  with a **data** cable (a charge-only cable will not work).

---

## PART 1 — BUILD THE APK

```
cd C:\projects\meshtech-app; & "C:\Users\Brett\flutter\bin\flutter.bat" build apk --debug
```

The finished file appears at:

```
C:\projects\meshtech-app\build\app\outputs\flutter-apk\app-debug.apk
```

Wait for the line `✓ Built build\app\outputs\flutter-apk\app-debug.apk`.
If it says `No supported devices connected`, your phone is not seen —
go to Troubleshooting below, then build again.

---

## PART 2 — PUT IT ON A PHONE OVER USB

**Step 1. Find the phone's id** (do this once per session):

```
& "C:\Users\Brett\AppData\Local\Android\Sdk\platform-tools\adb.exe" devices
```

You get a list. The long code on the left is the device id — for
Brett's Pixel it is `66020DLDV008SB`. The word `device` must appear
next to it (`unauthorized` = look at Troubleshooting).

**Step 2. Install the freshly built APK (keeps your saved settings):**

```
& "C:\Users\Brett\AppData\Local\Android\Sdk\platform-tools\adb.exe" install -r "C:\projects\meshtech-app\build\app\outputs\flutter-apk\app-debug.apk"
```

`-r` means *upgrade in place* — the old app is replaced and its saved
settings survive. You get `Success`.

**Alternative — the Flutter way (wipes saved settings):**

```
& "C:\Users\Brett\flutter\bin\flutter.bat" install --debug -d 66020DLDV008SB
```

Use this only right after a build. It uninstalls first, so the saved
address/password/map size are lost and must be typed again.

**Step 3. Check what is installed:**

```
& "C:\Users\Brett\AppData\Local\Android\Sdk\platform-tools\adb.exe" shell dumpsys package com.meshtech.meshtech_app | findstr versionName
```

`versionName=00.000.0NN` tells you the truth about what the phone is
running — the version in `pubspec.yaml` is raised in the same push,
so the chip and this line must agree.

---

## PART 3 — PUT IT ON ANY PHONE WITHOUT A CABLE

1. Build it (Part 1).
2. Get `app-debug.apk` onto the phone by **one** of:
   - plug the phone in and drag the file into its **Download** folder;
   - upload it to **Google Drive** and download it on the phone;
   - **email** it to yourself and open the attachment on the phone.
3. On the phone open **Files → Downloads → tap `app-debug.apk` →
   Install**.
4. Android asks once to allow installs from that app
   ("Allow from this source") — allow it, then Install again.
5. If an older copy is already installed and it refuses, uninstall the
   old one first (you lose its saved settings), then install.

---

## TROUBLESHOOTING

| What you see | What it means / what to do |
|---|---|
| `No supported devices connected` | Phone not seen. Check the cable is a data cable, USB debugging is on, then re-run `adb devices`. |
| `adb devices` shows `unauthorized` | Look at the phone — tap **Allow / Allow USB debugging**, then run the install again. |
| `adb devices` shows nothing at all | Unplug, plug in again; if still empty: `& "...platform-tools\adb.exe" kill-server` then `devices` again. |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` (signature clash) | The installed copy was signed differently. Uninstall once — `& "...platform-tools\adb.exe" uninstall com.meshtech.meshtech_app` — then install (saved settings are lost). |
| `INSTALL_FAILED_VERSION_DOWNGRADE` | You are putting an older build on a newer one. Same fix: uninstall once, then install. |
| Install says `Success` but the app is the old version | The APK was stale — always build first, then install. |
| App opens with blank address / password / BLE chip | Normal after a fresh install — the fields were wiped. Retype them and reselect the BLE chip. |
| Map screen is blank / crashes on the **release** build | Known: MapLibre under R8. Use the **debug** build until the fix ships. |
| `&&` is not a valid statement separator | You are in PowerShell — it does not accept `&&`. Use `;` on one line, or run the command in Git Bash. |

---

## QUICK DAILY ROUTINE (two lines)

```
cd C:\projects\meshtech-app; & "C:\Users\Brett\flutter\bin\flutter.bat" build apk --debug
```

```
& "C:\Users\Brett\AppData\Local\Android\Sdk\platform-tools\adb.exe" install -r "C:\projects\meshtech-app\build\app\outputs\flutter-apk\app-debug.apk"
```
