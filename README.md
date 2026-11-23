# kuroneko_windows_media

Windows installer USB drives for [Kuroneko](https://github.com/cocoa-xu/kuroneko)'s
virtual disk. Kuroneko's optical drive already starts a Windows installer's
ISO, with a BIOS or UEFI; this maker adds, for the same ISO, a USB drive
that UEFI starts, Secure Boot on or off: for a computer that will not start
from an optical drive, or a Windows Setup that should find its files on a
USB drive.

The drive is an MBR with one FAT32 partition holding the ISO's files, as
Microsoft lays out its own installer drives. An `install.wim` larger than a
FAT32 file can be (4 GiB) is split into `install.swm`, `install2.swm` and so
on, as `Dism /Split-Image` does, which Windows Setup installs from. Nothing
on the drive but the ISO's own files: UEFI starts Microsoft's signed boot
manager from it. A BIOS skips the drive; the ISO's optical drive is the way
for a BIOS.

## Installation

Kuroneko does not carry this library: a firmware that wants Windows
installer drives adds it to Kuroneko's dependencies and makers,

```elixir
{:kuroneko_windows_media, github: "cocoa-xu/kuroneko_windows_media", tag: "v0.1.0"}
```

```elixir
config :kuroneko, disk_makers: [Kuroneko.WindowsMedia]
```

or loads it into a running Kuroneko, from IEx over SSH for instance, its
compiled modules copied to the device:

```elixir
:code.add_patha(~c"/data/plugins/kuroneko_windows_media/ebin")
Kuroneko.VirtualDisk.register_maker(Kuroneko.WindowsMedia)
```

Then **Disk…** offers *USB drive: Windows installer, UEFI* for an ISO with
UDF and a UEFI boot entry; making the drive checks that the ISO is a
Windows installer. Making it takes as much room on the device as the ISO's
files, and goes away when the drive is ejected.

It needs the Kuroneko release after v0.1.2, whose makers get Kuroneko's
FAT32 formatter, on its Nerves system v0.1.3 or later, which has UDF in
the kernel and `losetup`. It runs as root, mounting the ISO and the
drive's partition through loop devices.

## License

GPL-3.0-or-later, apart from Kuroneko, which is Apache-2.0: a firmware with
this library carries the GPL's terms for it.
