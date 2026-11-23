# Changelog

## Unreleased

* `Kuroneko.WindowsMedia.WIM.split/3` takes the parts' size, name and
  progress as options: `:max_bytes`, `:name` (the WIM's own name by
  default) and `:progress`
* An ISO that does not mount leaves no directory behind
* `Kuroneko.WindowsMedia.make/3` raises for a mode it did not offer,
  rather than giving an error
* The maker takes Kuroneko's FAT32 formatter from its context,
  `:format_fat`, rather than calling a Kuroneko module, and its image goes
  in `as: :disk`: it needs the Kuroneko release after v0.1.2
* `Kuroneko.WindowsMedia.Drive.make/3` takes the formatter as
  `:format_fat`

## v0.1.0 (2026-11-23)

First version:

* A maker for Kuroneko's virtual disk (`Kuroneko.WindowsMedia`): a Windows
  installer's ISO as a USB drive that UEFI starts, Secure Boot on or off,
  one FAT32 partition holding the ISO's files
* An `install.wim` too large for FAT32 split into `install.swm` parts, as
  `Dism /Split-Image` does (`Kuroneko.WindowsMedia.WIM`); checked against
  wimlib with Windows 10 22H2's 5.2 GB WIM
* Made on a NanoKVM-Go from Windows 10 22H2's ISO, loaded at run time: the
  drive's files match the ISO's
