defmodule Kuroneko.WindowsMedia.LayoutTest do
  use ExUnit.Case, async: true

  alias Kuroneko.WindowsMedia.Layout

  @mib 1024 * 1024
  @gib 1024 * @mib

  @tag :tmp_dir
  test "a tree's directories and regular files, parents first", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "efi/boot"))
    File.mkdir_p!(Path.join(dir, "sources"))
    File.write!(Path.join(dir, "efi/boot/bootx64.efi"), "efi")
    File.write!(Path.join(dir, "setup.exe"), "setup")
    File.write!(Path.join(dir, "sources/boot.wim"), "wim")
    File.ln_s!("setup.exe", Path.join(dir, "autorun.exe"))

    assert Layout.entries(dir) ==
             {:ok,
              [
                {:dir, "efi"},
                {:dir, "efi/boot"},
                {:file, "efi/boot/bootx64.efi", 3},
                {:file, "setup.exe", 5},
                {:dir, "sources"},
                {:file, "sources/boot.wim", 3}
              ]}
  end

  test "WIMs too large for FAT32 split, the rest as it is" do
    layout =
      Layout.new([
        {:dir, "sources"},
        {:file, "sources/boot.wim", 3},
        {:file, "sources/install.WIM", 4 * @gib},
        {:file, "sources/winre.wim", 4 * @gib - 1}
      ])

    assert layout.entries == [
             {:dir, "sources"},
             {:file, "sources/boot.wim", 3},
             {:split, "sources/install.WIM", 4 * @gib},
             {:file, "sources/winre.wim", 4 * @gib - 1}
           ]

    assert layout.bytes == 8 * @gib + 2

    # Room for the files and directories in clusters, the FATs, and to spare.
    assert layout.start == @mib
    assert layout.size > 8 * @gib + 128 * @mib
    assert rem(layout.size, @mib) == 0
  end

  test "an MBR of one active FAT32 partition from 1 MiB, its code asking for the next device" do
    mbr = Layout.mbr(%Layout{entries: [], size: 2 * @gib, bytes: 0})

    assert <<0xCD, 0x18, _code::binary-size(438), _signature::binary-size(4), 0::16, 0x80,
             _chs::binary-size(3), 0x0C, _end_chs::binary-size(3), 2048::little-32,
             4_192_256::little-32, 0::size(48 * 8), 0x55, 0xAA>> = mbr
  end
end
