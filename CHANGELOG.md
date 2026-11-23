# Changelog

## Unreleased

First version:

* A maker for Kuroneko's virtual disk (`Kuroneko.WindowsMedia`): a Windows
  installer's ISO as a USB drive that UEFI starts, Secure Boot on or off,
  one FAT32 partition holding the ISO's files
* An `install.wim` too large for FAT32 split into `install.swm` parts, as
  `Dism /Split-Image` does (`Kuroneko.WindowsMedia.WIM`); checked against
  wimlib with Windows 10 22H2's 5.2 GB WIM
