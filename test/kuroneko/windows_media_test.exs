defmodule Kuroneko.WindowsMediaTest do
  use ExUnit.Case, async: true

  alias Kuroneko.WindowsMedia
  alias Kuroneko.WindowsMedia.Drive

  @moduletag :tmp_dir

  test "a USB drive for an ISO with UDF and a UEFI boot entry" do
    windows = %{path: "win.iso", kind: :image, format: %{udf: "1.02", boot: [:bios, :uefi]}}

    assert WindowsMedia.offers(windows) == [
             %{mode: "uefi", label: "USB drive: Windows installer, UEFI"}
           ]

    assert WindowsMedia.offers(put_in(windows.format.boot, [:bios])) == []
    assert WindowsMedia.offers(put_in(windows.format.udf, nil)) == []
    assert WindowsMedia.offers(%{path: "x", kind: :folder, format: nil}) == []
    assert WindowsMedia.id() == "windows-media"
    assert WindowsMedia.make(windows, "bios", %{}) == {:error, {:unknown_mode, "bios"}}
  end

  test "an MBR of one active FAT32 partition from 1 MiB, its code asking for the next device" do
    mbr = Drive.mbr(4_194_304)
    assert byte_size(mbr) == 512

    assert <<0xCD, 0x18, _code::binary-size(438), _signature::binary-size(4), 0::16, 0x80,
             _chs::binary-size(3), 0x0C, _end_chs::binary-size(3), 2048::little-32,
             4_192_256::little-32, 0::size(48 * 8), 0x55, 0xAA>> = mbr
  end

  test "the drive's files: as they are, but a WIM too large for FAT32", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "efi/boot"))
    File.mkdir_p!(Path.join(dir, "sources"))
    File.write!(Path.join(dir, "efi/boot/bootx64.efi"), "efi")
    File.write!(Path.join(dir, "setup.exe"), "exe")

    # A sparse WIM over 4 GiB, and one under.
    big = Path.join(dir, "sources/install.wim")
    {:ok, file} = File.open(big, [:write, :raw])
    :ok = :file.pwrite(file, 5 * 1024 * 1024 * 1024, <<0>>)
    File.close(file)
    File.write!(Path.join(dir, "sources/boot.wim"), "wim")

    assert {:ok, entries} = Drive.entries(dir)

    assert entries == [
             {"efi", :dir},
             {"efi/boot", :dir},
             {"efi/boot/bootx64.efi", 3},
             {"setup.exe", 3},
             {"sources", :dir},
             {"sources/boot.wim", 3},
             {"sources/install.wim", 5 * 1024 * 1024 * 1024 + 1}
           ]

    plan = Drive.plan(dir, entries)
    assert plan.split == ["sources/install.wim"]
    refute Enum.any?(plan.copy, &(elem(&1, 0) == "sources/install.wim"))

    # Room for the split WIM, the files and directories in clusters, and to spare.
    size = Drive.drive_size(plan)
    assert size > 5 * 1024 * 1024 * 1024 + 128 * 1024 * 1024
    assert rem(size, 1024 * 1024) == 0
  end
end
