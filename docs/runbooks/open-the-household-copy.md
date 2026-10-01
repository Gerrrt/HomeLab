# Runbook: Open the household copy

**Target:** the household drive (a WD Elements, 5 TB) and **your own
computer**: Windows, a Mac or Linux
**Time:** twenty minutes the first time; ten minutes once a year after that
**You will need:** the drive and its cable, your computer, and somewhere to
keep a small file and a sheet of paper that are not the drive

This page is for the person who keeps the household drive. You do not need to
know anything about the computers it came from. A copy of this page is on the
drive as `HOW-TO-OPEN.txt`, so you can follow it without the internet.

Do every step yourself, on your own computer, signed in as you. Nobody else
should be there to help. The point is to show that you can open it alone,
because the day you need it, you may be alone.

## Why

The drive holds the household's photographs and documents. They are locked,
so a lost or stolen drive shows nobody anything. **The key is yours.** You
make it in step 1, on your own computer, and it never leaves you. Only its
public half is sent back: it can lock things and cannot open them.
[ADR-0073](../adr/0073-carry-the-household-copy-on-a-drive-the-holder-keeps.md)
records why it is done this way.

**Keep the key and the drive apart.** Someone who has both has everything. Keep
the key file on your computer or in your password manager, and keep a paper
copy somewhere else in your home. Never put the key on the drive.

## Plug the drive in

The drive uses the cable that came with it. It has a small, flat plug at the
drive end, and the cable stays with the drive. The drive shows up as
`HOUSEHOLD`. You will see these on it:

```text
HOW-TO-OPEN.txt              this page
tools\                       the program that opens it, for each kind of computer
household\immich-library\    the photographs
household\paperless-documents\  the documents
PROOF\proof.txt.age          a short code, to show you opened it
```

## 1. Make your key (once, the first time)

**Windows.** Open `tools` on the drive and copy `age-v1.3.2-windows-amd64.zip`
to your Documents folder. Use `age-v1.3.2-windows-arm64.zip` instead if your
computer has an ARM processor (Settings, System, About). Right-click the copy,
choose *Extract All*, and extract it to `C:\age`. Then open **Command Prompt**
(search the Start menu for `cmd`). Use Command Prompt, not PowerShell: some
versions of PowerShell damage the files this page decrypts. Type:

```bat
C:\age\age\age-keygen.exe -o "%USERPROFILE%\household-key.txt"
```

**Mac.** Open `tools` on the drive and double-click
`age-v1.3.2-darwin-arm64.tar.gz`, or `age-v1.3.2-darwin-amd64.tar.gz` on an
older Intel Mac. This makes a folder called `age`. Move that folder to your
home folder. Open **Terminal** and type:

```bash
xattr -dr com.apple.quarantine ~/age
~/age/age-keygen -o ~/household-key.txt
```

**Linux.** Extract `tools/age-v1.3.2-linux-amd64.tar.gz` (or `-arm64`) to your
home directory, then:

```bash
~/age/age-keygen -o ~/household-key.txt
```

The command prints one line that starts `Public key: age1`. **Send that line,
and nothing else, to the person who set this up.** Text or email is fine,
because it can only lock and never open. Then:

- Print `household-key.txt`, or copy it out by hand. Keep the paper in your
  home, away from the drive.
- Keep the file itself where you keep important things, such as your
  password manager. Do not delete it.

The drive cannot open with your key until it has been written again with your
public key. They will tell you when that is done, and bring the drive back.

## 2. Open the proof

This is what shows the copy really is yours to open. In the same window, with
the drive plugged in (on Windows it will be a letter such as `E:`):

**Windows:**

```bat
C:\age\age\age.exe -d -i "%USERPROFILE%\household-key.txt" E:\PROOF\proof.txt.age
```

**Mac or Linux:** first say where the drive is, once per window. On a Mac it
is `/Volumes/HOUSEHOLD`. On Linux it is usually `/media/<your user
name>/HOUSEHOLD`; `ls /media/$USER` shows it.

On a Mac:

```bash
D=/Volumes/HOUSEHOLD
```

On Linux:

```bash
D=/media/$USER/HOUSEHOLD
```

Then:

```bash
~/age/age -d -i ~/household-key.txt "$D/PROOF/proof.txt.age"
```

It prints a twelve-digit code. **Phone the person who set this up and read it
to them.** That is the whole proof, and it counts only if you did it yourself.

If it says `no identity matched any of the recipients`, the drive has not been
written for your key yet. Tell them, and stop here.

## 3. Open the documents

Make a folder for what you open. On Windows, `C:\Restored`; on a Mac or Linux,
`~/Restored`. Then, replacing `<STAMP>` with the one folder name you see
under `household\paperless-documents\`:

**Windows:**

```bat
mkdir C:\Restored
C:\age\age\age.exe -d -i "%USERPROFILE%\household-key.txt" -o C:\Restored\documents.tar.gz E:\household\paperless-documents\<STAMP>\paperless-documents.tar.gz.age
tar -xzf C:\Restored\documents.tar.gz -C C:\Restored
```

**Mac or Linux**, with `D` set as in step 2:

```bash
mkdir -p ~/Restored
~/age/age -d -i ~/household-key.txt "$D"/household/paperless-documents/*/paperless-documents.tar.gz.age | tar -xzf - -C ~/Restored
```

Open `Restored` and open one document. They are the original files, with
their original names. `manifest.json` beside them is the list Paperless-ngx
reads to import them again, and you can ignore it.

## 4. Open a few photographs

The photographs are one large file and can take an hour to unpack. For the
yearly check, you only need to see that they start coming out. Do the same as
step 3, with `household\immich-library\<STAMP>\immich-library.tar.gz.age`,
into a folder of its own, `C:\Restored\photos` or `~/Restored/photos`:

**Windows:**

```bat
mkdir C:\Restored\photos
C:\age\age\age.exe -d -i "%USERPROFILE%\household-key.txt" -o C:\Restored\photos.tar.gz E:\household\immich-library\<STAMP>\immich-library.tar.gz.age
tar -xzf C:\Restored\photos.tar.gz -C C:\Restored\photos
```

**Mac or Linux**, with `D` set as in step 2:

```bash
mkdir -p ~/Restored/photos
~/age/age -d -i ~/household-key.txt "$D"/household/immich-library/*/immich-library.tar.gz.age | tar -xzf - -C ~/Restored/photos
```

The photographs are under `photos/library` and `photos/upload`, in folders by
person and year. Once you have seen a few, you can stop it with Ctrl+C and
delete `Restored`. For the yearly check that is enough. On the day you need
them, let it finish.

## When it is done

- Unplug the drive, put it back where you keep it, and keep the cable with
  it.
- Delete the `Restored` folder unless you need what is in it. It is not
  locked.
- Expect the person who set this up to borrow the drive about every three
  months, to bring it up to date. They will not need your key to do that.

## If something goes wrong

- **`no identity matched any of the recipients`.** This file was not written
  for your key. Either the drive has not been updated since you sent your
  public key, or you are using a different key file. Do not make a new key.
  Find the one you made in step 1, or the paper copy.
- **Windows: "tar is not recognized".** Your Windows is older than Windows 10
  (1803). Open the `.tar.gz` file with 7-Zip instead.
- **Mac: "cannot be opened because the developer cannot be verified".** Run
  the `xattr` line in step 1 again.
- **You lost the key and the paper.** Nothing on the drive can be opened with
  a new key. Tell the person who set this up. They hold a second key for
  exactly this, and the drive can be written again for a new one of yours.
